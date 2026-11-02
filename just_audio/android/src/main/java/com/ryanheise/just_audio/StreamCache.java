package com.ryanheise.just_audio;

import android.content.Context;
import android.net.Uri;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.media3.common.C;
import androidx.media3.database.StandaloneDatabaseProvider;
import androidx.media3.datasource.DataSource;
import androidx.media3.datasource.DataSpec;
import androidx.media3.datasource.DefaultHttpDataSource;
import androidx.media3.datasource.HttpDataSource;
import androidx.media3.datasource.TransferListener;
import androidx.media3.datasource.cache.Cache;
import androidx.media3.datasource.cache.CacheDataSource;
import androidx.media3.datasource.cache.CacheEvictor;
import androidx.media3.datasource.cache.CacheSpan;
import androidx.media3.datasource.cache.ContentMetadataMutations;
import androidx.media3.datasource.cache.SimpleCache;
import java.io.File;
import java.io.IOException;
import java.text.ParseException;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Collections;
import java.util.Date;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.NavigableSet;
import java.util.Set;
import java.util.TimeZone;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Disk cache for progressive streams.
 *
 * Only what the player actually reads is stored, so a listener who leaves an
 * episode after a minute has not paid for the rest of the file.
 */
final class StreamCache {
    private static final String DIRECTORY = "stream_audio_cache";
    private static final String VALIDATOR_KEY = "just_audio.validator";
    private static final int PROBE_TIMEOUT_MS = 3000;
    private static final long RESPONSE_TIME_TOLERANCE_MS = 5000;

    /**
     * Streams whose identity changed between requests within one run. Their
     * server gives no stable file to cache, so they stream directly, which is
     * what they did before this cache existed.
     */
    private static final Set<String> uncacheable = ConcurrentHashMap.newKeySet();

    @Nullable private static SimpleCache cache;
    @Nullable private static EpisodeLruEvictor evictor;

    private StreamCache() {}

    /** The first call fixes the cache: SimpleCache allows one instance per directory per process. */
    static synchronized void configure(Context context, long maxBytes) {
        if (cache != null) {
            evictor.setMaxBytes(maxBytes);
            return;
        }
        Context app = context.getApplicationContext();
        evictor = new EpisodeLruEvictor(maxBytes);
        cache = new SimpleCache(
                new File(app.getCacheDir(), DIRECTORY),
                evictor,
                new StandaloneDatabaseProvider(app));
    }

    /** Returns [upstream] unchanged until [configure] has been called. */
    static synchronized DataSource.Factory wrap(HttpDataSource.Factory upstream, String userAgent, @Nullable Map<String, String> headers) {
        final SimpleCache c = cache;
        final EpisodeLruEvictor e = evictor;
        if (c == null || e == null) return upstream;
        final CacheDataSource.Factory cached = new CacheDataSource.Factory()
                .setCache(c)
                .setUpstreamDataSourceFactory(() -> new ValidatingDataSource(upstream.createDataSource(), c))
                // A broken cache must degrade to streaming, not to a playback failure.
                .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR);
        // The player already holds what it read: the check must not delay a
        // fully cached episode for a whole connect timeout on a dead network.
        final HttpDataSource.Factory probes = new DefaultHttpDataSource.Factory()
                .setUserAgent(userAgent)
                .setAllowCrossProtocolRedirects(true)
                .setConnectTimeoutMs(PROBE_TIMEOUT_MS)
                .setReadTimeoutMs(PROBE_TIMEOUT_MS);
        if (headers != null && !headers.isEmpty()) probes.setDefaultRequestProperties(headers);
        // One factory per load, so the server is asked once per load.
        final AtomicBoolean probed = new AtomicBoolean(false);
        return () -> new LoadDataSource(cached.createDataSource(), upstream.createDataSource(), probes, c, e, probed);
    }

    static synchronized long size() {
        return cache == null ? 0 : cache.getCacheSpace();
    }

    static synchronized List<String> urls() {
        return cache == null ? new ArrayList<>() : new ArrayList<>(cache.getKeys());
    }

    /**
     * Removes everything except [keep] and, unless [includeInUse], the stream
     * being played. The caller knows when the player has stopped; this class
     * only sees the last stream opened.
     */
    static synchronized void clear(Collection<String> keep, boolean includeInUse) {
        if (cache == null) return;
        for (String key : new ArrayList<>(cache.getKeys())) {
            if (keep.contains(key) || (!includeInUse && evictor.isInUse(key))) continue;
            cache.removeResource(key);
        }
    }

    static synchronized void remove(String url) {
        if (cache == null || evictor.isInUse(url)) return;
        cache.removeResource(url);
    }

    private static String keyOf(DataSpec spec) {
        return spec.key != null ? spec.key : spec.uri.toString();
    }

    /** What the cache stores must be audio, or it would be replayed forever. */
    private static boolean isNotAudio(Map<String, List<String>> headers) {
        String type = header(headers, "content-type");
        return type != null && type.toLowerCase(Locale.ROOT).startsWith("text/");
    }

    /**
     * The player's entry point for one load: compares the stored identity with
     * the server before any stored byte reaches the player, and routes streams
     * that cannot be cached around the cache.
     *
     * The comparison has to come first. ExoPlayer resumes a failed load at the
     * same byte position with the same seek table, so finding a replaced file
     * only when playback reaches the first uncached range would splice two
     * files for the listener even though the store itself stays consistent.
     */
    private static final class LoadDataSource implements DataSource {
        private final DataSource cached;
        private final HttpDataSource direct;
        private final HttpDataSource.Factory probes;
        private final Cache cache;
        private final EpisodeLruEvictor evictor;
        private final AtomicBoolean probed;
        @Nullable private DataSource current;
        @Nullable private String openKey;

        LoadDataSource(DataSource cached, HttpDataSource direct, HttpDataSource.Factory probes, Cache cache, EpisodeLruEvictor evictor, AtomicBoolean probed) {
            this.cached = cached;
            this.direct = direct;
            this.probes = probes;
            this.cache = cache;
            this.evictor = evictor;
            this.probed = probed;
        }

        @Override
        public long open(@NonNull DataSpec spec) throws IOException {
            String key = keyOf(spec);
            if (!uncacheable.contains(key) && probed.compareAndSet(false, true)) probe(spec, key);
            current = uncacheable.contains(key) ? direct : cached;
            openKey = key;
            evictor.acquire(key);
            return current.open(spec);
        }

        /** Best-effort: offline, a stored entry is still the best available copy. */
        private void probe(DataSpec spec, String key) {
            try {
                if (cache.getCachedSpans(key).isEmpty()) return;
                String known = cache.getContentMetadata(key).get(VALIDATOR_KEY, (String) null);
                HttpDataSource probe = probes.createDataSource();
                try {
                    probe.open(new DataSpec.Builder().setUri(spec.uri).setPosition(0).setLength(2).build());
                    Map<String, List<String>> headers = probe.getResponseHeaders();
                    String validator = validatorOf(headers);
                    if (isNotAudio(headers)) return;
                    if (known != null && !known.equals(validator)) cache.removeResource(key);
                } finally {
                    probe.close();
                }
            } catch (IOException | RuntimeException ignored) {
                // Includes a cache that failed to initialize; the read path copes.
            }
        }

        @Override
        public int read(@NonNull byte[] buffer, int offset, int length) throws IOException {
            return current.read(buffer, offset, length);
        }

        @Override
        public void addTransferListener(@NonNull TransferListener listener) {
            cached.addTransferListener(listener);
            direct.addTransferListener(listener);
        }

        @Nullable
        @Override
        public Uri getUri() {
            return current == null ? null : current.getUri();
        }

        @NonNull
        @Override
        public Map<String, List<String>> getResponseHeaders() {
            return current == null ? Collections.emptyMap() : current.getResponseHeaders();
        }

        @Override
        public void close() throws IOException {
            String key = openKey;
            openKey = null;
            if (key != null) evictor.release(key);
            DataSource source = current;
            current = null;
            if (source != null) source.close();
        }
    }

    /**
     * Upstream of the cache: keeps bytes of a different file out of an entry.
     *
     * Hosts with dynamic ad insertion can serve a different file per request.
     * CacheDataSource keys on the URL alone and would store the two as one.
     */
    private static final class ValidatingDataSource implements DataSource {
        private final HttpDataSource upstream;
        private final Cache cache;

        ValidatingDataSource(HttpDataSource upstream, Cache cache) {
            this.upstream = upstream;
            this.cache = cache;
        }

        @Override
        public long open(@NonNull DataSpec spec) throws IOException {
            long length = upstream.open(spec);
            Map<String, List<String>> headers = upstream.getResponseHeaders();
            if (isNotAudio(headers)) {
                upstream.close();
                // A captive portal's page: it says nothing about the stored file.
                throw new IOException("Not audio: " + spec.uri);
            }
            String validator = validatorOf(headers);
            String key = keyOf(spec);
            if (validator == null) {
                bypass(key);
                upstream.close();
                throw new IOException("Stream has no identity: " + key);
            }
            try {
                String known = cache.getContentMetadata(key).get(VALIDATOR_KEY, (String) null);
                if (known != null && !known.equals(validator)) {
                    // The load's probe already matched, so this server's identity
                    // is not stable. ExoPlayer's retry goes around the cache.
                    bypass(key);
                    upstream.close();
                    throw new IOException("Stream identity is not stable: " + key);
                }
                if (known == null) {
                    ContentMetadataMutations mutations = new ContentMetadataMutations();
                    long total = totalOf(headers, length);
                    if (total != C.LENGTH_UNSET) ContentMetadataMutations.setContentLength(mutations, total);
                    mutations.set(VALIDATOR_KEY, validator);
                    cache.applyContentMetadataMutations(key, mutations);
                }
            } catch (Cache.CacheException e) {
                // Includes failed initialization. The audio itself is fine.
                bypass(key);
            }
            return length;
        }

        private void bypass(String key) {
            uncacheable.add(key);
            try {
                cache.removeResource(key);
            } catch (RuntimeException ignored) {
                // A cache that failed to initialize holds nothing to remove.
            }
        }

        @Override
        public int read(@NonNull byte[] buffer, int offset, int length) throws IOException {
            return upstream.read(buffer, offset, length);
        }

        @Override
        public void addTransferListener(@NonNull TransferListener listener) {
            upstream.addTransferListener(listener);
        }

        @Nullable
        @Override
        public Uri getUri() {
            return upstream.getUri();
        }

        @NonNull
        @Override
        public Map<String, List<String>> getResponseHeaders() {
            return upstream.getResponseHeaders();
        }

        @Override
        public void close() throws HttpDataSource.HttpDataSourceException {
            upstream.close();
        }
    }

    /** The strongest identity the response offers, or null when it offers none. */
    @Nullable
    static String validatorOf(Map<String, List<String>> headers) {
        String etag = header(headers, "etag");
        // A weak ETag only promises equivalent content, not identical bytes.
        if (etag != null && !etag.startsWith("W/")) return "etag:" + etag;
        String modified = header(headers, "last-modified");
        if (modified != null && !isResponseTime(modified, header(headers, "date"))) return "modified:" + modified;
        long total = totalOf(headers, C.LENGTH_UNSET);
        return total == C.LENGTH_UNSET ? null : "length:" + total;
    }

    /**
     * Some ad-serving CDNs (Triton) send the time of the response as
     * Last-Modified, so it differs on every request for the very same bytes.
     */
    private static boolean isResponseTime(String modified, @Nullable String date) {
        if (date == null) return false;
        SimpleDateFormat format = new SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss zzz", Locale.US);
        format.setTimeZone(TimeZone.getTimeZone("GMT"));
        try {
            Date modifiedAt = format.parse(modified);
            Date respondedAt = format.parse(date);
            return modifiedAt != null && respondedAt != null
                    && respondedAt.getTime() - modifiedAt.getTime() < RESPONSE_TIME_TOLERANCE_MS;
        } catch (ParseException e) {
            return false;
        }
    }

    private static long totalOf(Map<String, List<String>> headers, long fallback) {
        String range = header(headers, "content-range");
        if (range != null) {
            int slash = range.lastIndexOf('/');
            if (0 <= slash) {
                try {
                    return Long.parseLong(range.substring(slash + 1).trim());
                } catch (NumberFormatException e) {
                    // "bytes 0-1/*": Content-Length is this part's, not the file's.
                    return C.LENGTH_UNSET;
                }
            }
        }
        String length = header(headers, "content-length");
        if (length == null) return fallback;
        try {
            return Long.parseLong(length.trim());
        } catch (NumberFormatException e) {
            return fallback;
        }
    }

    @Nullable
    private static String header(Map<String, List<String>> headers, String name) {
        for (Map.Entry<String, List<String>> entry : headers.entrySet()) {
            // The HTTP stack's status line entry has a null key.
            if (entry.getKey() == null || !entry.getKey().equalsIgnoreCase(name)) continue;
            List<String> values = entry.getValue();
            return values.isEmpty() ? null : values.get(0);
        }
        return null;
    }

    /**
     * Evicts whole episodes, least recently used first.
     *
     * Media3's LeastRecentlyUsedCacheEvictor works per span, which would leave
     * every episode full of holes and defeat resuming any of them.
     */
    private static final class EpisodeLruEvictor implements CacheEvictor {
        private final Map<String, Long> bytesByKey = new HashMap<>();
        private final Map<String, Long> lastUseByKey = new HashMap<>();
        private long maxBytes;
        private long totalBytes;
        /** Keys with a source open, counted because a retry can overlap a close. */
        private final Map<String, Integer> openCounts = new ConcurrentHashMap<>();

        EpisodeLruEvictor(long maxBytes) {
            this.maxBytes = maxBytes;
        }

        void setMaxBytes(long maxBytes) {
            this.maxBytes = maxBytes;
        }

        void acquire(String key) {
            openCounts.merge(key, 1, Integer::sum);
        }

        void release(String key) {
            openCounts.computeIfPresent(key, (k, count) -> count <= 1 ? null : count - 1);
        }

        boolean isInUse(String key) {
            return openCounts.containsKey(key);
        }

        @Override
        public boolean requiresCacheSpanTouches() {
            return true;
        }

        @Override
        public void onCacheInitialized() {}

        @Override
        public void onStartFile(@NonNull Cache cache, @NonNull String key, long position, long length) {
            if (length != C.LENGTH_UNSET) evict(cache, key, length);
        }

        @Override
        public void onSpanAdded(@NonNull Cache cache, CacheSpan span) {
            totalBytes += span.length;
            bytesByKey.merge(span.key, span.length, Long::sum);
            // Spans load in no particular order at startup, so keep the newest.
            lastUseByKey.merge(span.key, span.lastTouchTimestamp, Math::max);
            evict(cache, span.key, 0);
        }

        @Override
        public void onSpanRemoved(@NonNull Cache cache, CacheSpan span) {
            totalBytes -= span.length;
            long remaining = bytesByKey.merge(span.key, -span.length, Long::sum);
            if (remaining <= 0) {
                bytesByKey.remove(span.key);
                lastUseByKey.remove(span.key);
            }
        }

        @Override
        public void onSpanTouched(@NonNull Cache cache, @NonNull CacheSpan oldSpan, CacheSpan newSpan) {
            lastUseByKey.put(newSpan.key, newSpan.lastTouchTimestamp);
        }

        private void evict(Cache cache, String writingKey, long incoming) {
            while (maxBytes < totalBytes + incoming) {
                String victim = leastRecentlyUsed(writingKey);
                if (victim != null) {
                    cache.removeResource(victim);
                    continue;
                }
                // Only the current episode is left and it alone exceeds the
                // limit. The limit still holds, so give up its oldest bytes.
                if (!removeOldestSpan(cache, writingKey)) return;
            }
        }

        @Nullable
        private String leastRecentlyUsed(String writingKey) {
            String victim = null;
            long oldest = Long.MAX_VALUE;
            for (Map.Entry<String, Long> entry : lastUseByKey.entrySet()) {
                String key = entry.getKey();
                if (key.equals(writingKey) || isInUse(key)) continue;
                if (entry.getValue() < oldest) {
                    oldest = entry.getValue();
                    victim = key;
                }
            }
            return victim;
        }

        private boolean removeOldestSpan(Cache cache, String key) {
            NavigableSet<CacheSpan> spans = cache.getCachedSpans(key);
            CacheSpan oldest = null;
            for (CacheSpan span : spans) {
                if (oldest == null || span.lastTouchTimestamp < oldest.lastTouchTimestamp) oldest = span;
            }
            if (oldest == null) return false;
            cache.removeSpan(oldest);
            return true;
        }
    }
}
