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
import android.view.View
import android.widget.RemoteViews
import java.io.File
import java.io.FileOutputStream
import java.util.Locale

private const val SPOTIFY_PACKAGE = "com.spotify.music"
private const val SPOTIFY_PREFS = "still_spotify"
private const val ALBUM_ART_FILE = "spotify_album_art.png"

class SpotifyMediaListener : NotificationListenerService() {
    private var controller: MediaController? = null
    private val ticker = Handler(Looper.getMainLooper())
    private val tick = object : Runnable {
        override fun run() {
            if (controller?.playbackState?.state != PlaybackState.STATE_PLAYING) return
            SpotifyWidgetProvider.updateProgressAll(this@SpotifyMediaListener)
            ticker.postDelayed(this, 1_000L)
        }
    }

    private val callback = object : MediaController.Callback() {
        override fun onMetadataChanged(metadata: MediaMetadata?) = publish(metadata)
        override fun onPlaybackStateChanged(state: PlaybackState?) = publish()
        override fun onSessionDestroyed() = connectToSpotify()
    }

    override fun onListenerConnected() = connectToSpotify()

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (sbn.packageName == SPOTIFY_PACKAGE) connectToSpotify()
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        if (sbn.packageName == SPOTIFY_PACKAGE) connectToSpotify()
    }

    private fun connectToSpotify() {
        val manager = getSystemService(MEDIA_SESSION_SERVICE) as MediaSessionManager
        val next = try {
            manager.getActiveSessions(ComponentName(this, SpotifyMediaListener::class.java))
                .firstOrNull { it.packageName == SPOTIFY_PACKAGE }
        } catch (_: SecurityException) {
            null
        }

        if (controller?.sessionToken != next?.sessionToken) {
            controller?.unregisterCallback(callback)
            controller = next
            controller?.registerCallback(callback)
        }
        publish()
    }

    private fun publish(metadataOverride: MediaMetadata? = null) {
        val metadata = metadataOverride ?: controller?.metadata
        val state = controller?.playbackState
        if (metadata == null) {
            getSharedPreferences(SPOTIFY_PREFS, MODE_PRIVATE).edit()
                .putBoolean("playing", false)
                .putBoolean("connected", controller != null)
                .apply()
            SpotifyWidgetProvider.updateAll(this)
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
        if (art != null) saveAlbumArt(art)
        SpotifyWidgetProvider.updateAll(this)
        ticker.removeCallbacks(tick)
        if (playing) ticker.postDelayed(tick, 1_000L)
    }

    private fun saveAlbumArt(bitmap: Bitmap) {
        try {
            val maxSide = 384
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

    override fun onDestroy() {
        ticker.removeCallbacks(tick)
        controller?.unregisterCallback(callback)
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
                view.setProgressBar(
                    R.id.spotify_progress,
                    duration.coerceAtMost(Int.MAX_VALUE.toLong()).toInt().coerceAtLeast(1),
                    position.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
                    false,
                )
                view.setTextViewText(
                    R.id.spotify_time,
                    "${formatTime(position)}  /  ${formatTime(duration)}",
                )
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
            view.setProgressBar(
                R.id.spotify_progress,
                duration.coerceAtMost(Int.MAX_VALUE.toLong()).toInt().coerceAtLeast(1),
                position.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
                false,
            )
            view.setTextViewText(
                R.id.spotify_time,
                "${formatTime(position)}  /  ${formatTime(duration)}",
            )

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

        private fun formatTime(milliseconds: Long): String {
            val seconds = (milliseconds.coerceAtLeast(0L) / 1000L)
            return String.format(Locale.US, "%d:%02d", seconds / 60, seconds % 60)
        }
    }
}
