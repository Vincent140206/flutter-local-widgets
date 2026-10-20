package com.example.localwidgets

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import android.view.View
import android.widget.RemoteViews
import java.io.File
import java.io.FileOutputStream
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

private const val SPOTIFY_PACKAGE = "com.spotify.music"
private const val SPOTIFY_PREFS = "still_spotify"
private const val ALBUM_ART_FILE = "spotify_album_art.png"

class SpotifyMediaListener : NotificationListenerService() {
    companion object {
        @Volatile
        private var listenerConnected = false
        @Volatile
        private var currentInstance: SpotifyMediaListener? = null
        private var lastRebindRequest = 0L
        private var lastManualRefresh = 0L

        @Synchronized
        fun ensureConnected(context: Context) {
            val now = SystemClock.elapsedRealtime()
            currentInstance?.let { service ->
                if (now - lastManualRefresh >= 5_000L) {
                    lastManualRefresh = now
                    service.ticker.post { service.reconcileNow() }
                }
                return
            }
            if (listenerConnected || Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return
            if (now - lastRebindRequest < 10_000L) return
            lastRebindRequest = now
            requestRebind(ComponentName(context, SpotifyMediaListener::class.java))
        }
    }

    private var controller: MediaController? = null
    private var sessionManager: MediaSessionManager? = null
    private var sessionsListenerRegistered = false
    private val artworkExecutor = Executors.newSingleThreadExecutor()
    private val notificationExecutor = Executors.newSingleThreadExecutor()
    private val widgetExecutor = Executors.newSingleThreadExecutor()
    private val progressUpdateQueued = AtomicBoolean(false)
    private var lastArtworkKey = ""
    private var lastFullWidgetState = ""
    private val ticker = Handler(Looper.getMainLooper())
    private val tick = object : Runnable {
        override fun run() {
            if (controller?.playbackState?.state != PlaybackState.STATE_PLAYING) return
            safelyUpdateSpotifyProgress()
            ticker.postDelayed(this, 1_000L)
        }
    }
    private val watchdog = object : Runnable {
        override fun run() {
            reconcileNow()
            ticker.postDelayed(this, 15_000L)
        }
    }

    private val callback = object : MediaController.Callback() {
        override fun onMetadataChanged(metadata: MediaMetadata?) = publish(metadata)
        override fun onPlaybackStateChanged(state: PlaybackState?) = publish()
        override fun onSessionDestroyed() {
            controller?.unregisterCallback(this)
            controller = null
            ticker.postDelayed({ connectToSpotify() }, 250L)
        }
    }

    private val sessionsChanged = MediaSessionManager.OnActiveSessionsChangedListener {
        connectToSpotify()
    }

    override fun onListenerConnected() {
        listenerConnected = true
        currentInstance = this
        Log.d("StillNotifications", "Notification listener connected")
        registerSessionsListener()
        reconcileNow()
        ticker.removeCallbacks(watchdog)
        ticker.postDelayed(watchdog, 15_000L)
    }

    override fun onListenerDisconnected() {
        listenerConnected = false
        if (currentInstance === this) currentInstance = null
        ticker.removeCallbacks(watchdog)
        Log.w("StillNotifications", "Notification listener disconnected; requesting rebind")
        unregisterSessionsListener()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            requestRebind(ComponentName(this, SpotifyMediaListener::class.java))
        }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (sbn.packageName == SPOTIFY_PACKAGE) connectToSpotify()
        if (WhatsAppNotificationStore.isWhatsAppPackage(sbn.packageName)) {
            Log.d("StillNotifications", "WhatsApp notification posted: ${sbn.key}")
            notificationExecutor.execute {
                try {
                    WhatsAppNotificationStore.upsert(this, sbn)
                } catch (error: Exception) {
                    Log.e("StillNotifications", "Unable to store WhatsApp notification", error)
                }
            }
        }
    }

    override fun onNotificationRemoved(
        sbn: StatusBarNotification,
        rankingMap: RankingMap,
        reason: Int,
    ) {
        if (sbn.packageName == SPOTIFY_PACKAGE) connectToSpotify()
        if (WhatsAppNotificationStore.isWhatsAppPackage(sbn.packageName)) {
            notificationExecutor.execute {
                try {
                    WhatsAppNotificationStore.onRemoved(this, sbn, reason)
                } catch (error: Exception) {
                    Log.e("StillNotifications", "Unable to remove WhatsApp notification", error)
                }
            }
        }
    }

    private fun reconcileNow() {
        if (!listenerConnected) return
        connectToSpotify()
        mergeActiveWhatsAppNotifications()
    }

    private fun mergeActiveWhatsAppNotifications() {
        val notifications = try {
            activeNotifications ?: emptyArray()
        } catch (_: SecurityException) {
            emptyArray()
        }
        notificationExecutor.execute {
            try {
                WhatsAppNotificationStore.mergeActive(this, notifications)
            } catch (error: Exception) {
                Log.e("StillNotifications", "Unable to reconcile WhatsApp notifications", error)
            }
        }
    }

    private fun connectToSpotify() {
        val manager = sessionManager
            ?: (getSystemService(MEDIA_SESSION_SERVICE) as MediaSessionManager).also {
                sessionManager = it
            }
        val next = try {
            manager.getActiveSessions(ComponentName(this, SpotifyMediaListener::class.java))
                .firstOrNull { it.packageName == SPOTIFY_PACKAGE }
        } catch (_: SecurityException) {
            null
        }

        if (controller?.sessionToken != next?.sessionToken) {
            controller?.unregisterCallback(callback)
            controller = next
            controller?.registerCallback(callback, ticker)
        }
        publish()
    }

    private fun registerSessionsListener() {
        if (sessionsListenerRegistered) return
        val manager = getSystemService(MEDIA_SESSION_SERVICE) as MediaSessionManager
        sessionManager = manager
        try {
            manager.addOnActiveSessionsChangedListener(
                sessionsChanged,
                ComponentName(this, SpotifyMediaListener::class.java),
                ticker,
            )
            sessionsListenerRegistered = true
        } catch (_: SecurityException) {
            sessionsListenerRegistered = false
        }
    }

    private fun unregisterSessionsListener() {
        if (!sessionsListenerRegistered) return
        sessionManager?.removeOnActiveSessionsChangedListener(sessionsChanged)
        sessionsListenerRegistered = false
    }

    private fun publish(metadataOverride: MediaMetadata? = null) {
        val metadata = metadataOverride ?: controller?.metadata
        val state = controller?.playbackState
        if (metadata == null) {
            val fullState = "empty|${controller != null}"
            getSharedPreferences(SPOTIFY_PREFS, MODE_PRIVATE).edit()
                .putBoolean("playing", false)
                .putBoolean("connected", controller != null)
                .apply()
            if (fullState != lastFullWidgetState) {
                lastFullWidgetState = fullState
                safelyUpdateSpotifyWidget()
            } else {
                safelyUpdateSpotifyProgress()
            }
            return
        }
        val title = metadata.getString(MediaMetadata.METADATA_KEY_TITLE).orEmpty()
        val artist = metadata.getString(MediaMetadata.METADATA_KEY_ARTIST)
            ?.takeIf { it.isNotBlank() }
            ?: metadata.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST).orEmpty()
        val album = metadata.getString(MediaMetadata.METADATA_KEY_ALBUM).orEmpty()
        val duration = metadata.getLong(MediaMetadata.METADATA_KEY_DURATION)
        val playing = state?.state == PlaybackState.STATE_PLAYING
        val elapsedSinceUpdate = if (playing) {
            (SystemClock.elapsedRealtime() - state.lastPositionUpdateTime).coerceAtLeast(0L)
        } else 0L
        val position = ((state?.position ?: 0L) +
            (elapsedSinceUpdate * (state?.playbackSpeed ?: 0f)).toLong())
            .coerceIn(0L, duration.coerceAtLeast(0L))

        getSharedPreferences(SPOTIFY_PREFS, MODE_PRIVATE).edit()
            .putString("title", title)
            .putString("artist", artist)
            .putString("album", album)
            .putLong("duration", duration)
            .putLong("position", position)
            .putLong("position_updated_at", SystemClock.elapsedRealtime())
            .putFloat("playback_speed", state?.playbackSpeed ?: 0f)
            .putBoolean("playing", playing)
            .putBoolean("connected", controller != null)
            .apply()

        val art = metadata.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART)
            ?: metadata.getBitmap(MediaMetadata.METADATA_KEY_ART)
        val fullState = "$title|$artist|$album|$duration|$playing"
        if (fullState != lastFullWidgetState) {
            lastFullWidgetState = fullState
            safelyUpdateSpotifyWidget()
        } else {
            safelyUpdateSpotifyProgress()
        }
        val artworkKey = "$title|$album"
        if (art != null && artworkKey != lastArtworkKey) {
            lastArtworkKey = artworkKey
            artworkExecutor.execute {
                saveAlbumArt(art)
                ticker.post {
                    safelyUpdateSpotifyWidget()
                }
            }
        }
        ticker.removeCallbacks(tick)
        if (playing) ticker.postDelayed(tick, 1_000L)
    }

    private fun saveAlbumArt(bitmap: Bitmap) {
        try {
            val maxSide = 256
            val scale = minOf(1f, maxSide.toFloat() / maxOf(bitmap.width, bitmap.height))
            val output = if (scale < 1f) {
                Bitmap.createScaledBitmap(
                    bitmap,
                    (bitmap.width * scale).toInt(),
                    (bitmap.height * scale).toInt(),
                    true,
                )
            } else bitmap
            FileOutputStream(File(filesDir, ALBUM_ART_FILE)).use {
                output.compress(Bitmap.CompressFormat.PNG, 100, it)
            }
            if (output !== bitmap) output.recycle()
        } catch (_: Exception) {
            // Metadata remains useful even if artwork cannot be cached.
        }
    }

    private fun safelyUpdateSpotifyWidget() {
        if (widgetExecutor.isShutdown) return
        widgetExecutor.execute {
            try {
                SpotifyWidgetProvider.updateAll(this)
                StillIslandService.notifyDataChanged(this)
            } catch (error: RuntimeException) {
                Log.e("StillNotifications", "Unable to refresh Spotify widget", error)
            }
        }
    }

    private fun safelyUpdateSpotifyProgress() {
        if (widgetExecutor.isShutdown) return
        if (!progressUpdateQueued.compareAndSet(false, true)) return
        widgetExecutor.execute {
            try {
                SpotifyWidgetProvider.updateProgressAll(this)
            } catch (error: RuntimeException) {
                Log.e("StillNotifications", "Unable to refresh Spotify progress", error)
            } finally {
                progressUpdateQueued.set(false)
            }
        }
    }

    override fun onDestroy() {
        listenerConnected = false
        if (currentInstance === this) currentInstance = null
        ticker.removeCallbacks(watchdog)
        ticker.removeCallbacks(tick)
        controller?.unregisterCallback(callback)
        unregisterSessionsListener()
        artworkExecutor.shutdownNow()
        notificationExecutor.shutdownNow()
        widgetExecutor.shutdownNow()
        super.onDestroy()
    }
}

class SpotifyWidgetProvider : AppWidgetProvider() {
    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        when (intent.action) {
            ACTION_PREVIOUS -> controlSpotify(context) { skipToPrevious() }
            ACTION_PLAY_PAUSE -> toggleSpotify(context)
            ACTION_NEXT -> controlSpotify(context) { skipToNext() }
        }
    }

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        ids.forEach { update(context, manager, it) }
    }

    companion object {
        private const val ACTION_PREVIOUS = "com.example.localwidgets.spotify.PREVIOUS"
        private const val ACTION_PLAY_PAUSE = "com.example.localwidgets.spotify.PLAY_PAUSE"
        private const val ACTION_NEXT = "com.example.localwidgets.spotify.NEXT"

        fun updateAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, SpotifyWidgetProvider::class.java))
            ids.forEach { update(context, manager, it) }
        }

        fun updateProgressAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, SpotifyWidgetProvider::class.java))
            if (ids.isEmpty()) return
            val prefs = context.getSharedPreferences(SPOTIFY_PREFS, Context.MODE_PRIVATE)
            val duration = prefs.getLong("duration", 0L)
            val playing = prefs.getBoolean("playing", false)
            val position = livePosition(prefs, duration, playing)
            ids.forEach { id ->
                val view = RemoteViews(context.packageName, R.layout.spotify_widget)
                setPlaybackProgress(view, duration, position, playing)
                view.setImageViewResource(
                    R.id.spotify_play_pause,
                    if (playing) R.drawable.spotify_pause else R.drawable.spotify_play,
                )
                manager.partiallyUpdateAppWidget(id, view)
            }
        }

        private fun update(context: Context, manager: AppWidgetManager, id: Int) {
            val prefs = context.getSharedPreferences(SPOTIFY_PREFS, Context.MODE_PRIVATE)
            val title = prefs.getString("title", "").orEmpty()
            val artist = prefs.getString("artist", "").orEmpty()
            val album = prefs.getString("album", "").orEmpty()
            val duration = prefs.getLong("duration", 0L)
            val playing = prefs.getBoolean("playing", false)
            val position = livePosition(prefs, duration, playing)
            val connected = prefs.getBoolean("connected", false)
            val view = RemoteViews(context.packageName, R.layout.spotify_widget)

            val launch = context.packageManager.getLaunchIntentForPackage(SPOTIFY_PACKAGE)
                ?: context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?: Intent(context, MainActivity::class.java)
            launch.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            val pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
            val pending = PendingIntent.getActivity(context, 2401, launch, pendingFlags)
            view.setOnClickPendingIntent(R.id.spotify_widget_container, pending)
            view.setOnClickPendingIntent(
                R.id.spotify_previous,
                controlPendingIntent(context, ACTION_PREVIOUS, 2402),
            )
            view.setOnClickPendingIntent(
                R.id.spotify_play_pause,
                controlPendingIntent(context, ACTION_PLAY_PAUSE, 2403),
            )
            view.setOnClickPendingIntent(
                R.id.spotify_next,
                controlPendingIntent(context, ACTION_NEXT, 2404),
            )
            view.setImageViewResource(
                R.id.spotify_play_pause,
                if (playing) R.drawable.spotify_pause else R.drawable.spotify_play,
            )

            val hasTrack = title.isNotBlank()
            view.setTextViewText(R.id.spotify_title, if (hasTrack) title else "Nothing playing")
            view.setTextViewText(
                R.id.spotify_artist,
                when {
                    artist.isNotBlank() && album.isNotBlank() -> "$artist · $album"
                    artist.isNotBlank() -> artist
                    connected -> "Open Spotify and play something"
                    else -> "Waiting for Spotify"
                },
            )
            view.setTextViewText(
                R.id.spotify_status,
                when {
                    playing -> "SPOTIFY  •  PLAYING"
                    hasTrack -> "SPOTIFY  •  PAUSED"
                    else -> "SPOTIFY  •  READY"
                },
            )
            view.setViewVisibility(R.id.spotify_progress_group, if (hasTrack) View.VISIBLE else View.INVISIBLE)
            setPlaybackProgress(view, duration, position, playing)

            val artFile = File(context.filesDir, ALBUM_ART_FILE)
            val art = if (artFile.exists()) BitmapFactory.decodeFile(artFile.path) else null
            if (art != null && hasTrack) {
                view.setImageViewBitmap(R.id.spotify_art, roundedArtwork(art))
            } else {
                view.setImageViewResource(R.id.spotify_art, R.drawable.spotify_art_placeholder)
            }
            manager.updateAppWidget(id, view)
        }

        private fun controlPendingIntent(context: Context, action: String, requestCode: Int): PendingIntent {
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
            return PendingIntent.getBroadcast(
                context,
                requestCode,
                Intent(context, SpotifyWidgetProvider::class.java).apply { this.action = action },
                flags,
            )
        }

        private fun activeSpotifyController(context: Context): MediaController? {
            val manager = context.getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
            return try {
                manager.getActiveSessions(ComponentName(context, SpotifyMediaListener::class.java))
                    .firstOrNull { it.packageName == SPOTIFY_PACKAGE }
            } catch (_: SecurityException) {
                null
            }
        }

        private fun controlSpotify(
            context: Context,
            action: MediaController.TransportControls.() -> Unit,
        ) {
            activeSpotifyController(context)?.transportControls?.action()
        }

        private fun toggleSpotify(context: Context) {
            val controller = activeSpotifyController(context) ?: return
            if (controller.playbackState?.state == PlaybackState.STATE_PLAYING) {
                controller.transportControls.pause()
            } else {
                controller.transportControls.play()
            }
        }

        private fun roundedArtwork(source: Bitmap): Bitmap {
            val size = minOf(source.width, source.height)
            val output = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            val shader = BitmapShader(source, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP).apply {
                setLocalMatrix(Matrix().apply {
                    setTranslate(
                        -((source.width - size) / 2f),
                        -((source.height - size) / 2f),
                    )
                })
            }
            Canvas(output).drawRoundRect(
                RectF(0f, 0f, size.toFloat(), size.toFloat()),
                size * 0.14f,
                size * 0.14f,
                Paint(Paint.ANTI_ALIAS_FLAG).apply { this.shader = shader },
            )
            return output
        }

        private fun livePosition(
            prefs: android.content.SharedPreferences,
            duration: Long,
            playing: Boolean,
        ): Long {
            val basePosition = prefs.getLong("position", 0L)
            val updatedAt = prefs.getLong("position_updated_at", SystemClock.elapsedRealtime())
            val speed = prefs.getFloat("playback_speed", 0f)
            val liveOffset = if (playing) {
                ((SystemClock.elapsedRealtime() - updatedAt).coerceAtLeast(0L) * speed).toLong()
            } else 0L
            return (basePosition + liveOffset).coerceIn(0L, duration.coerceAtLeast(0L))
        }

        private fun setPlaybackProgress(
            view: RemoteViews,
            duration: Long,
            position: Long,
            playing: Boolean,
        ) {
            view.setProgressBar(
                R.id.spotify_progress,
                duration.coerceAtMost(Int.MAX_VALUE.toLong()).toInt().coerceAtLeast(1),
                position.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
                false,
            )
            // Chronometer advances inside the launcher process, so elapsed time stays
            // realtime without waiting for another RemoteViews Binder transaction.
            view.setChronometer(
                R.id.spotify_time,
                SystemClock.elapsedRealtime() - position,
                "%s  /  ${formatTime(duration)}",
                playing,
            )
        }

        private fun formatTime(milliseconds: Long): String {
            val seconds = (milliseconds.coerceAtLeast(0L) / 1000L)
            return String.format(Locale.US, "%d:%02d", seconds / 60, seconds % 60)
        }
    }
}
