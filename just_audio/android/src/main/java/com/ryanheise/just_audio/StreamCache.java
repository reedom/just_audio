package com.ryanheise.just_audio;

import android.content.Context;
import android.net.Uri;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.media3.common.C;
import androidx.media3.database.StandaloneDatabaseProvider;
import androidx.media3.datasource.DataSource;
import androidx.media3.datasource.DataSpec;
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
import java.util.ArrayList;
import java.util.Collection;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.NavigableSet;

/**
 * Disk cache for progressive streams.
 *
 * Only what the player actually reads is stored, so a listener who leaves an
 * episode after a minute has not paid for the rest of the file.
 */
final class StreamCache {
    private static final String DIRECTORY = "stream_audio_cache";
    private static final String VALIDATOR_KEY = "just_audio.validator";

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
    static synchronized DataSource.Factory wrap(HttpDataSource.Factory upstream) {
        final SimpleCache c = cache;
        final EpisodeLruEvictor e = evictor;
        if (c == null || e == null) return upstream;
        return new CacheDataSource.Factory()
                .setCache(c)
                .setCacheKeyFactory(spec -> {
                    String key = spec.key != null ? spec.key : spec.uri.toString();
                    e.markInUse(key);
                    return key;
                })
                .setUpstreamDataSourceFactory(() -> new ValidatingDataSource(upstream.createDataSource(), c))
                // A broken cache must degrade to streaming, not to a playback failure.
                .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR);
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

    /**
     * Rejects bytes that do not belong to the file already cached under the URL.
     *
     * Hosts with dynamic ad insertion can serve a different file per request.
     * CacheDataSource keys on the URL alone and would splice the two together,
     * which is audible corruption.
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
            String validator = validatorOf(upstream.getResponseHeaders());
            if (validator == null) return length;
            String key = spec.key != null ? spec.key : spec.uri.toString();
            String known = cache.getContentMetadata(key).get(VALIDATOR_KEY, (String) null);
            if (known != null && !known.equals(validator)) {
                upstream.close();
                cache.removeResource(key);
                // ExoPlayer retries the load, which now starts from an empty entry.
                throw new IOException("Stream changed on the server: " + key);
            }
            if (known == null) {
                ContentMetadataMutations mutations = new ContentMetadataMutations();
                ContentMetadataMutations.setContentLength(mutations, totalOf(upstream.getResponseHeaders(), length));
                mutations.set(VALIDATOR_KEY, validator);
                cache.applyContentMetadataMutations(key, mutations);
            }
            return length;
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
        if (modified != null) return "modified:" + modified;
        long total = totalOf(headers, C.LENGTH_UNSET);
        return total == C.LENGTH_UNSET ? null : "length:" + total;
    }

    private static long totalOf(Map<String, List<String>> headers, long fallback) {
        String range = header(headers, "content-range");
        if (range != null) {
            int slash = range.lastIndexOf('/');
            if (0 <= slash) {
                try {
                    return Long.parseLong(range.substring(slash + 1).trim());
                } catch (NumberFormatException ignored) {
                    // "bytes 0-1/*" has no total; fall through.
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
        @Nullable private volatile String keyInUse;

        EpisodeLruEvictor(long maxBytes) {
            this.maxBytes = maxBytes;
        }

        void setMaxBytes(long maxBytes) {
            this.maxBytes = maxBytes;
        }

        void markInUse(String key) {
            keyInUse = key;
        }

        boolean isInUse(String key) {
            return key.equals(keyInUse);
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
            lastUseByKey.put(span.key, span.lastTouchTimestamp);
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
                if (key.equals(writingKey) || key.equals(keyInUse)) continue;
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
