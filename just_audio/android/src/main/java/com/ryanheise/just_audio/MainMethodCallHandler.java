package com.ryanheise.just_audio;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import androidx.annotation.NonNull;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;
import java.util.HashMap;
import java.util.List;
import java.util.ArrayList;
import java.util.Map;
import java.util.concurrent.Callable;
import java.util.concurrent.Executor;
import java.util.concurrent.Executors;

public class MainMethodCallHandler implements MethodCallHandler {

    private final Context applicationContext;
    private final BinaryMessenger messenger;

    private final Map<String, AudioPlayer> players = new HashMap<>();
    private final Executor streamCacheExecutor = Executors.newSingleThreadExecutor();
    private final Handler mainHandler = new Handler(Looper.getMainLooper());

    public MainMethodCallHandler(Context applicationContext,
            BinaryMessenger messenger) {
        this.applicationContext = applicationContext;
        this.messenger = messenger;
    }

    @Override
    public void onMethodCall(MethodCall call, @NonNull Result result) {
        switch (call.method) {
        case "init": {
            String id = call.argument("id");
            if (players.containsKey(id)) {
                result.error("Platform player " + id + " already exists", null, null);
                break;
            }
            List<Object> rawAudioEffects = call.argument("androidAudioEffects");
            players.put(
                id,
                new AudioPlayer(
                    applicationContext,
                    messenger,
                    id,
                    call.argument("audioLoadConfiguration"),
                    rawAudioEffects,
                    call.argument("androidAudioOffloadPreferences"),
                    call.argument("androidOffloadSchedulingEnabled"),
		    call.argument("useLazyPreparation")
                )
            );
            result.success(null);
            break;
        }
        case "disposePlayer": {
            String id = call.argument("id");
            AudioPlayer player = players.get(id);
            if (player != null) {
                player.dispose();
                players.remove(id);
            }
            result.success(new HashMap<String, Object>());
            break;
        }
        case "disposeAllPlayers": {
            dispose();
            result.success(new HashMap<String, Object>());
            break;
        }
        case "streamCacheConfigure": {
            long maxBytes = ((Number) call.argument("maxBytes")).longValue();
            StreamCache.configure(applicationContext, maxBytes);
            result.success(null);
            break;
        }
        case "streamCacheSize":
            runStreamCacheTask(result, StreamCache::size);
            break;
        case "streamCacheUrls":
            runStreamCacheTask(result, StreamCache::urls);
            break;
        case "streamCacheClear": {
            List<String> keep = call.argument("keep");
            boolean includeInUse = Boolean.TRUE.equals(call.argument("includeInUse"));
            runStreamCacheTask(result, () -> {
                StreamCache.clear(keep, includeInUse);
                return null;
            });
            break;
        }
        case "streamCacheRemove": {
            String url = call.argument("url");
            runStreamCacheTask(result, () -> {
                StreamCache.remove(url);
                return null;
            });
            break;
        }
        default:
            result.notImplemented();
            break;
        }
    }

    /** Cache calls block on disk and on SimpleCache initialization. */
    private void runStreamCacheTask(Result result, Callable<Object> task) {
        streamCacheExecutor.execute(() -> {
            try {
                Object value = task.call();
                mainHandler.post(() -> result.success(value));
            } catch (Exception e) {
                mainHandler.post(() -> result.error("streamCache", e.getMessage(), null));
            }
        });
    }

    void dispose() {
        for (AudioPlayer player : new ArrayList<AudioPlayer>(players.values())) {
            player.dispose();
        }
        players.clear();
    }
}
