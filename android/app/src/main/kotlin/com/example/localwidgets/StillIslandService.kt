package com.example.localwidgets

import android.animation.ValueAnimator
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.BitmapFactory
import android.graphics.PixelFormat
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.view.WindowInsets
import android.view.animation.DecelerateInterpolator
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.ProgressBar
import android.widget.TextView
import androidx.core.app.NotificationCompat
import org.json.JSONArray
import java.io.File

class StillIslandService : Service() {
    companion object {
        const val ACTION_REFRESH = "com.example.localwidgets.island.REFRESH"
        const val ACTION_STOP = "com.example.localwidgets.island.STOP"
        const val PREFS = "still_island"
        const val ENABLED_KEY = "enabled"

        private const val CHANNEL_ID = "still_island"
        private const val NOTIFICATION_ID = 4701

        fun notifyDataChanged(context: Context) {
            context.sendBroadcast(Intent(ACTION_REFRESH).setPackage(context.packageName))
        }
    }

    private lateinit var windowManager: WindowManager
    private lateinit var root: View
    private lateinit var params: WindowManager.LayoutParams
    private lateinit var compact: View
    private lateinit var expanded: View
    private lateinit var messageCard: View
    private lateinit var compactTitle: TextView
    private lateinit var compactMeta: TextView
    private lateinit var spectrum: SpectrumVisualizerView
    private lateinit var title: TextView
    private lateinit var subtitle: TextView
    private lateinit var artwork: ImageView
    private lateinit var progress: ProgressBar
    private lateinit var playPause: ImageButton
    private lateinit var sender: TextView
    private lateinit var message: TextView
    private lateinit var messageCount: TextView

    private val handler = Handler(Looper.getMainLooper())
    private var isExpanded = false
    private var attached = false
    private var contentVisible = false
    private var animator: ValueAnimator? = null
    private var lastArtworkModified = Long.MIN_VALUE
    private var lastArtworkKey = ""
    private var compactY = 0
    private var expandedY = 0
    private var spotifyController: MediaController? = null
    private var lastSessionCheck = 0L
    private var lastPublishedWidgetState = ""
    private var lastWidgetProgressUpdate = 0L

    private val spotifyCallback = object : MediaController.Callback() {
        override fun onMetadataChanged(metadata: MediaMetadata?) {
            lastPublishedWidgetState = ""
            updateContent()
        }

        override fun onPlaybackStateChanged(state: PlaybackState?) {
            lastPublishedWidgetState = ""
            updateContent()
        }
        override fun onSessionDestroyed() {
            spotifyController?.unregisterCallback(this)
            spotifyController = null
            handler.postDelayed({
                connectSpotifyController()
                updateContent()
            }, 250L)
        }
    }

    private val ticker = object : Runnable {
        override fun run() {
            updateContent()
            handler.postDelayed(this, if (contentVisible) 1_000L else 5_000L)
        }
    }

    private val refreshReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) = updateContent()
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, serviceNotification())
        registerRefreshReceiver()
        if (Settings.canDrawOverlays(this)) attachIsland() else stopSelf()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            getSharedPreferences(PREFS, MODE_PRIVATE).edit().putBoolean(ENABLED_KEY, false).apply()
            stopSelf()
            return START_NOT_STICKY
        }
        if (!Settings.canDrawOverlays(this)) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (!attached) attachIsland()
        updateContent()
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun attachIsland() {
        if (attached) return
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        root = LayoutInflater.from(this).inflate(R.layout.still_island, null)
        compact = root.findViewById(R.id.island_compact)
        expanded = root.findViewById(R.id.island_expanded)
        messageCard = root.findViewById(R.id.island_message)
        compactTitle = root.findViewById(R.id.island_compact_title)
        compactMeta = root.findViewById(R.id.island_compact_meta)
        spectrum = root.findViewById(R.id.island_spectrum)
        title = root.findViewById(R.id.island_title)
        subtitle = root.findViewById(R.id.island_subtitle)
        artwork = root.findViewById(R.id.island_art)
        progress = root.findViewById(R.id.island_progress)
        playPause = root.findViewById(R.id.island_play_pause)
        sender = root.findViewById(R.id.island_sender)
        message = root.findViewById(R.id.island_message_text)
        messageCount = root.findViewById(R.id.island_message_count)

        params = WindowManager.LayoutParams(
            dp(190),
            dp(46),
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            } else {
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_PHONE
            },
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                setFitInsetsTypes(0)
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
            calculateVerticalAnchors()
            y = compactY
        }

        root.elevation = dp(18).toFloat()
        root.alpha = 0f
        root.scaleX = 0.84f
        root.scaleY = 0.84f
        root.visibility = View.INVISIBLE
        params.flags = params.flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        setupInteractions()
        windowManager.addView(root, params)
        attached = true
        connectSpotifyController()
        updateContent()
        handler.post(ticker)
    }

    private fun setupInteractions() {
        var downY = 0f
        root.isClickable = true
        root.contentDescription = "Open Still Island interactive widget"
        root.setOnClickListener {
            if (!isExpanded) {
                root.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                expand()
            }
        }
        root.setOnTouchListener { view, event ->
            if (isExpanded) return@setOnTouchListener false
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downY = event.rawY
                    view.animate().scaleX(0.97f).scaleY(0.97f).setDuration(90L).start()
                    true
                }
                MotionEvent.ACTION_UP -> {
                    view.animate().scaleX(1f).scaleY(1f).setDuration(140L).start()
                    if (event.rawY - downY >= -dp(18)) view.performClick()
                    true
                }
                MotionEvent.ACTION_CANCEL -> {
                    view.animate().scaleX(1f).scaleY(1f).setDuration(140L).start()
                    true
                }
                else -> true
            }
        }
        root.findViewById<View>(R.id.island_close).setOnClickListener { collapse() }
        var headerDownY = 0f
        root.findViewById<View>(R.id.island_header).setOnTouchListener { view, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    headerDownY = event.rawY
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (event.rawY - headerDownY < -dp(18)) {
                        view.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                        collapse()
                    } else {
                        openPackage("com.spotify.music")
                    }
                    true
                }
                else -> true
            }
        }
        messageCard.setOnClickListener { openWhatsApp() }
        root.findViewById<View>(R.id.island_previous).setOnClickListener {
            spotifyAction("com.example.localwidgets.spotify.PREVIOUS")
        }
        playPause.setOnClickListener {
            spotifyAction("com.example.localwidgets.spotify.PLAY_PAUSE")
        }
        root.findViewById<View>(R.id.island_next).setOnClickListener {
            spotifyAction("com.example.localwidgets.spotify.NEXT")
        }
    }

    private fun spotifyAction(action: String) {
        connectSpotifyController()
        val controls = spotifyController?.transportControls
        when (action) {
            "com.example.localwidgets.spotify.PREVIOUS" -> controls?.skipToPrevious()
            "com.example.localwidgets.spotify.PLAY_PAUSE" -> {
                if (spotifyController?.playbackState?.state == PlaybackState.STATE_PLAYING) {
                    controls?.pause()
                } else {
                    controls?.play()
                }
            }
            "com.example.localwidgets.spotify.NEXT" -> controls?.skipToNext()
        }
        if (controls == null) {
            sendBroadcast(Intent(this, SpotifyWidgetProvider::class.java).apply { this.action = action })
        }
        handler.postDelayed({ updateContent() }, 250L)
    }

    private fun expand() {
        if (isExpanded) return
        isExpanded = true
        updateContent()
        expanded.visibility = View.VISIBLE
        expanded.alpha = 0f
        expanded.scaleX = 0.96f
        expanded.scaleY = 0.96f
        animateIsland(
            fromWidth = params.width,
            toWidth = expandedWidth(),
            fromHeight = params.height,
            toHeight = expandedHeight(),
            fromY = params.y,
            toY = expandedY,
            expanding = true,
        )
    }

    private fun collapse() {
        if (!isExpanded) return
        isExpanded = false
        compact.visibility = View.VISIBLE
        animateIsland(
            fromWidth = params.width,
            toWidth = dp(190),
            fromHeight = params.height,
            toHeight = dp(46),
            fromY = params.y,
            toY = compactY,
            expanding = false,
        )
    }

    private fun animateIsland(
        fromWidth: Int,
        toWidth: Int,
        fromHeight: Int,
        toHeight: Int,
        fromY: Int,
        toY: Int,
        expanding: Boolean,
    ) {
        animator?.cancel()
        animator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 320L
            interpolator = DecelerateInterpolator(1.7f)
            addUpdateListener { value ->
                val fraction = value.animatedValue as Float
                params.width = lerp(fromWidth, toWidth, fraction)
                params.height = lerp(fromHeight, toHeight, fraction)
                params.y = lerp(fromY, toY, fraction)
                if (attached) windowManager.updateViewLayout(root, params)
                compact.alpha = if (expanding) 1f - fraction else fraction
                expanded.alpha = if (expanding) fraction else 1f - fraction
                expanded.scaleX = 0.96f + (if (expanding) fraction else 1f - fraction) * 0.04f
                expanded.scaleY = expanded.scaleX
                if (fraction == 1f) {
                    if (expanding) compact.visibility = View.GONE else expanded.visibility = View.GONE
                }
            }
            start()
        }
    }

    private fun updateContent() {
        if (!attached) return
        SpotifyMediaListener.ensureConnected(this)
        if (spotifyController == null || SystemClock.elapsedRealtime() - lastSessionCheck > 5_000L) {
            connectSpotifyController()
        }
        val spotify = getSharedPreferences("still_spotify", MODE_PRIVATE)
        val metadata = spotifyController?.metadata
        val state = spotifyController?.playbackState
        val trackTitle = metadata?.getString(MediaMetadata.METADATA_KEY_TITLE)
            ?.takeIf { it.isNotBlank() }
            ?: spotify.getString("title", "").orEmpty()
        val artist = metadata?.getString(MediaMetadata.METADATA_KEY_ARTIST)
            ?.takeIf { it.isNotBlank() }
            ?: metadata?.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST)
                ?.takeIf { it.isNotBlank() }
            ?: spotify.getString("artist", "").orEmpty()
        val album = metadata?.getString(MediaMetadata.METADATA_KEY_ALBUM)
            ?.takeIf { it.isNotBlank() }
            ?: spotify.getString("album", "").orEmpty()
        // Only a live MediaSession can make the Island visible. A persisted
        // preference may be stale after Spotify or the listener is killed.
        val playing = state?.state == PlaybackState.STATE_PLAYING
        val duration = metadata?.getLong(MediaMetadata.METADATA_KEY_DURATION)
            ?.takeIf { it > 0L }
            ?: spotify.getLong("duration", 0L)
        val basePosition = state?.position ?: spotify.getLong("position", 0L)
        val updatedAt = state?.lastPositionUpdateTime
            ?: spotify.getLong("position_updated_at", SystemClock.elapsedRealtime())
        val speed = state?.playbackSpeed ?: spotify.getFloat("playback_speed", 0f)
        val position = (basePosition + if (playing) {
            ((SystemClock.elapsedRealtime() - updatedAt).coerceAtLeast(0L) * speed).toLong()
        } else 0L).coerceIn(0L, duration.coerceAtLeast(0L))
        syncSpotifyWidget(
            trackTitle = trackTitle,
            artist = artist,
            album = album,
            duration = duration,
            position = position,
            speed = speed,
            playing = playing,
        )

        val notifications = readWhatsApp()
        val latest = notifications.optJSONObject(0)
        val count = notifications.length()
        setIslandContentVisible(playing || count > 0)
        spectrum.visibility = if (playing) View.VISIBLE else View.GONE
        compactMeta.visibility = if (playing) View.GONE else View.VISIBLE
        spectrum.setPlaying(playing && contentVisible)
        if (!contentVisible) return
        compactTitle.text = when {
            playing && trackTitle.isNotEmpty() -> trackTitle
            latest != null -> latest.optString("sender", "WhatsApp")
            else -> "Still"
        }
        compactMeta.text = when {
            playing -> "PLAYING"
            count > 0 -> "$count NEW"
            else -> "READY"
        }
        title.text = trackTitle.ifEmpty { "Nothing playing" }
        subtitle.text = when {
            artist.isNotEmpty() && album.isNotEmpty() -> "$artist · $album"
            artist.isNotEmpty() -> artist
            else -> "Waiting for Spotify"
        }
        playPause.setImageResource(if (playing) R.drawable.spotify_pause else R.drawable.spotify_play)
        progress.progress = if (duration > 0L) ((position * 1000L) / duration).toInt() else 0

        val liveArtwork = metadata?.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART)
            ?: metadata?.getBitmap(MediaMetadata.METADATA_KEY_ART)
        val artworkKey = "$trackTitle|$album"
        val art = File(filesDir, "spotify_album_art.png")
        if (liveArtwork != null) {
            if (artworkKey != lastArtworkKey) {
                artwork.setImageBitmap(liveArtwork)
                lastArtworkKey = artworkKey
                lastArtworkModified = art.lastModified()
            }
        } else if (art.exists() && trackTitle.isNotEmpty()) {
            if (artworkKey != lastArtworkKey || art.lastModified() != lastArtworkModified) {
                artwork.setImageBitmap(BitmapFactory.decodeFile(art.path))
                lastArtworkModified = art.lastModified()
                lastArtworkKey = artworkKey
            }
        } else if (lastArtworkKey.isNotEmpty()) {
            artwork.setImageResource(R.drawable.spotify_art_placeholder)
            lastArtworkModified = Long.MIN_VALUE
            lastArtworkKey = ""
        }

        if (latest == null) {
            messageCard.visibility = View.GONE
        } else {
            messageCard.visibility = View.VISIBLE
            sender.text = latest.optString("sender", "WhatsApp")
            message.text = latest.optString("message", "")
            messageCount.text = count.toString()
        }
        if (isExpanded && params.height != expandedHeight() && animator?.isRunning != true) {
            params.height = expandedHeight()
            windowManager.updateViewLayout(root, params)
        }
    }

    private fun setIslandContentVisible(visible: Boolean) {
        if (visible == contentVisible) return
        contentVisible = visible
        root.animate().cancel()
        if (visible) {
            params.flags = params.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE.inv()
            windowManager.updateViewLayout(root, params)
            root.visibility = View.VISIBLE
            root.alpha = 0f
            root.scaleX = 0.84f
            root.scaleY = 0.84f
            root.translationY = -dp(5).toFloat()
            root.animate()
                .alpha(1f)
                .scaleX(1f)
                .scaleY(1f)
                .translationY(0f)
                .setDuration(260L)
                .setInterpolator(DecelerateInterpolator(1.8f))
                .start()
        } else {
            animator?.cancel()
            isExpanded = false
            compact.visibility = View.VISIBLE
            compact.alpha = 1f
            expanded.visibility = View.GONE
            params.width = dp(190)
            params.height = dp(46)
            params.y = compactY
            params.flags = params.flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
            windowManager.updateViewLayout(root, params)
            spectrum.setPlaying(false)
            root.animate()
                .alpha(0f)
                .scaleX(0.84f)
                .scaleY(0.84f)
                .translationY(-dp(5).toFloat())
                .setDuration(190L)
                .withEndAction { if (!contentVisible) root.visibility = View.INVISIBLE }
                .start()
        }
    }

    private fun readWhatsApp(): JSONArray {
        val raw = getSharedPreferences("still_whatsapp", MODE_PRIVATE)
            .getString("notifications", "[]") ?: "[]"
        return try {
            JSONArray(raw)
        } catch (_: Exception) {
            JSONArray()
        }
    }

    private fun syncSpotifyWidget(
        trackTitle: String,
        artist: String,
        album: String,
        duration: Long,
        position: Long,
        speed: Float,
        playing: Boolean,
    ) {
        val now = SystemClock.elapsedRealtime()
        val stateKey = "$trackTitle|$artist|$album|$duration|$playing"
        if (stateKey != lastPublishedWidgetState) {
            lastPublishedWidgetState = stateKey
            getSharedPreferences("still_spotify", MODE_PRIVATE).edit()
                .putString("title", trackTitle)
                .putString("artist", artist)
                .putString("album", album)
                .putLong("duration", duration)
                .putLong("position", position)
                .putLong("position_updated_at", now)
                .putFloat("playback_speed", speed)
                .putBoolean("playing", playing)
                .putBoolean("connected", spotifyController != null)
                .apply()
            SpotifyWidgetProvider.updateAll(this)
            lastWidgetProgressUpdate = now
        } else if (playing && now - lastWidgetProgressUpdate >= 5_000L) {
            SpotifyWidgetProvider.updateProgressAll(this)
            lastWidgetProgressUpdate = now
        }
    }

    private fun openWhatsApp() {
        if (!openPackage("com.whatsapp")) openPackage("com.whatsapp.w4b")
    }

    private fun openPackage(packageName: String): Boolean {
        val launch = packageManager.getLaunchIntentForPackage(packageName) ?: return false
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        startActivity(launch)
        collapse()
        return true
    }

    private fun connectSpotifyController() {
        lastSessionCheck = SystemClock.elapsedRealtime()
        val manager = getSystemService(MEDIA_SESSION_SERVICE) as MediaSessionManager
        val next = try {
            manager.getActiveSessions(ComponentName(this, SpotifyMediaListener::class.java))
                .firstOrNull { it.packageName == "com.spotify.music" }
        } catch (_: SecurityException) {
            null
        }
        if (spotifyController?.sessionToken == next?.sessionToken) return
        spotifyController?.unregisterCallback(spotifyCallback)
        spotifyController = next
        spotifyController?.registerCallback(spotifyCallback, handler)
    }

    private fun calculateVerticalAnchors() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val metrics = windowManager.currentWindowMetrics
            val insets = metrics.windowInsets
            val statusBottom = insets.getInsetsIgnoringVisibility(WindowInsets.Type.statusBars()).top
            val screenCenter = metrics.bounds.centerX()
            val camera = insets.displayCutout?.boundingRects
                ?.minByOrNull { rect -> kotlin.math.abs(rect.centerX() - screenCenter) }
            val cameraBottom = camera?.bottom ?: statusBottom
            compactY = if (camera != null) {
                // Center the pill on the punch-hole; the window is allowed to draw
                // inside the cutout area by layoutInDisplayCutoutMode above.
                (camera.centerY() - dp(23)).coerceAtLeast(0)
            } else {
                0
            }
            expandedY = maxOf(statusBottom, cameraBottom) + dp(5)
            return
        }
        val statusId = resources.getIdentifier("status_bar_height", "dimen", "android")
        val statusBottom = if (statusId > 0) resources.getDimensionPixelSize(statusId) else dp(24)
        compactY = 0
        expandedY = statusBottom + dp(5)
    }

    private fun expandedWidth(): Int {
        val screenWidth = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            windowManager.currentWindowMetrics.bounds.width()
        } else {
            @Suppress("DEPRECATION")
            resources.displayMetrics.widthPixels
        }
        return minOf(dp(352), screenWidth - dp(24))
    }

    private fun expandedHeight(): Int = dp(if (messageCard.visibility == View.VISIBLE) 202 else 146)

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    private fun lerp(start: Int, end: Int, fraction: Float): Int {
        return start + ((end - start) * fraction).toInt()
    }

    private fun registerRefreshReceiver() {
        val filter = IntentFilter(ACTION_REFRESH)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(refreshReceiver, filter, RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(refreshReceiver, filter)
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Still Island",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Keeps the interactive Still Island visible"
                setShowBadge(false)
            },
        )
    }

    private fun serviceNotification(): android.app.Notification {
        val openApp = PendingIntent.getActivity(
            this,
            4701,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this,
            4702,
            Intent(this, StillIslandService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Still Island is active")
            .setContentText("Spotify and WhatsApp updates are shown around the camera")
            .setContentIntent(openApp)
            .setOngoing(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .addAction(0, "Turn off", stop)
            .build()
    }

    override fun onDestroy() {
        animator?.cancel()
        if (::root.isInitialized) root.animate().cancel()
        if (::spectrum.isInitialized) spectrum.setPlaying(false)
        handler.removeCallbacksAndMessages(null)
        spotifyController?.unregisterCallback(spotifyCallback)
        spotifyController = null
        try {
            unregisterReceiver(refreshReceiver)
        } catch (_: Exception) {
            // Receiver may not have finished registering if service startup failed.
        }
        if (attached) {
            windowManager.removeView(root)
            attached = false
        }
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
}
