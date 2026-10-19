package com.example.localwidgets

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapRegionDecoder
import android.graphics.Rect
import android.os.Build
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider
import org.json.JSONArray
import java.util.Calendar
import java.util.TimeZone
import kotlin.math.max
import kotlin.math.roundToInt
import kotlin.math.sqrt

private const val MIDNIGHT_TICK = "com.example.localwidgets.MIDNIGHT_TICK"

private fun dayNumber(): Int {
    val local = Calendar.getInstance()
    val utc = Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply {
        clear()
        set(local.get(Calendar.YEAR), local.get(Calendar.MONTH), local.get(Calendar.DAY_OF_MONTH))
    }
    val epoch = Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply {
        clear()
        set(2020, Calendar.JANUARY, 1)
    }
    return ((utc.timeInMillis - epoch.timeInMillis) / 86_400_000L).toInt()
}

internal fun getLaunchPendingIntent(context: Context): PendingIntent {
    return try {
        HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java)
    } catch (_: Throwable) {
        val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: Intent(context, MainActivity::class.java)
        intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
        PendingIntent.getActivity(context, 0, intent, flags)
    }
}

internal fun widgetTargetPixels(
    context: Context,
    manager: AppWidgetManager,
    widgetId: Int,
): Pair<Int, Int> {
    val options = manager.getAppWidgetOptions(widgetId)
    val density = context.resources.displayMetrics.density
    val widthDp = max(
        options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 240),
        options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH, 240),
    )
    val heightDp = max(
        options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 180),
        options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 180),
    )
    var width = (widthDp * density * 1.2f).roundToInt().coerceIn(600, 1800)
    var height = (heightDp * density * 1.2f).roundToInt().coerceIn(600, 1800)

    // Keep the RemoteViews bitmap around 8 MB or less. This is sharp enough
    // for high-density widgets while staying well below camera-image memory.
    val pixelBudget = 2_000_000.0
    val pixels = width.toDouble() * height.toDouble()
    if (pixels > pixelBudget) {
        val scale = sqrt(pixelBudget / pixels)
        width = (width * scale).roundToInt()
        height = (height * scale).roundToInt()
    }
    return Pair(width, height)
}

internal fun decodeWidgetBitmap(
    path: String,
    targetWidth: Int,
    targetHeight: Int,
): Bitmap? {
    if (path.isBlank()) return null
    val decoder = try {
        BitmapRegionDecoder.newInstance(path, false)
    } catch (_: Exception) {
        null
    } ?: return null
    return try {
        val sourceWidth = decoder.width
        val sourceHeight = decoder.height
        val sourceAspect = sourceWidth.toDouble() / sourceHeight
        val targetAspect = targetWidth.toDouble() / targetHeight
        val crop = if (sourceAspect > targetAspect) {
            val cropWidth = (sourceHeight * targetAspect).roundToInt()
            val left = (sourceWidth - cropWidth) / 2
            Rect(left, 0, left + cropWidth, sourceHeight)
        } else {
            val cropHeight = (sourceWidth / targetAspect).roundToInt()
            val top = (sourceHeight - cropHeight) / 2
            Rect(0, top, sourceWidth, top + cropHeight)
        }

        var sampleSize = 1
        while (crop.width() / (sampleSize * 2) >= targetWidth &&
            crop.height() / (sampleSize * 2) >= targetHeight) {
            sampleSize *= 2
        }

        val sampledWidth = crop.width().toFloat() / sampleSize
        val sampledHeight = crop.height().toFloat() / sampleSize
        val finalScale = max(
            targetWidth / sampledWidth,
            targetHeight / sampledHeight,
        ).coerceAtMost(1f)
        decoder.decodeRegion(crop, BitmapFactory.Options().apply {
            inSampleSize = sampleSize
            inPreferredConfig = Bitmap.Config.ARGB_8888
            if (finalScale < 0.99f) {
                inScaled = true
                inDensity = 1000
                inTargetDensity = (1000 * finalScale).roundToInt()
            }
        })
    } catch (_: Exception) {
        null
    } finally {
        decoder.recycle()
    }
}

private object CuratedVerseSource {
    private var cached: JSONArray? = null

    @Synchronized
    fun all(context: Context): JSONArray {
        if (cached == null) {
            cached = try {
                val json = context.assets.open("curated_widget.json")
                    .bufferedReader(Charsets.UTF_8).use { it.readText() }
                JSONArray(json)
            } catch (_: Exception) {
                JSONArray()
            }
        }
        return cached!!
    }

    fun todaysVerse(context: Context): Pair<String, String> {
        val verses = all(context)
        if (verses.length() == 0) {
            return Pair("Open Still to initialize your library.", "Still")
        }
        val verse = verses.optJSONObject(Math.floorMod(dayNumber(), verses.length()))
        return Pair(
            verse?.optString("text") ?: "",
            verse?.optString("reference") ?: "",
        )
    }
}

class PhotoWidgetProvider : HomeWidgetProvider() {
    companion object {
        private const val ROTATION_INTERVAL_MS = 15000L
        private const val ALARM_REQUEST_CODE = 1001
    }

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray, data: SharedPreferences) {
        val paths = try {
            JSONArray(data.getString("photo_paths", "[]") ?: "[]")
        } catch (_: Exception) { JSONArray() }
        val rotate = data.getBoolean("rotate_photos", true)
        val launchIntent = getLaunchPendingIntent(context)

        for (id in ids) {
            val view = RemoteViews(context.packageName, R.layout.photo_widget)
            view.setOnClickPendingIntent(R.id.photo_widget_container, launchIntent)
            view.setOnClickPendingIntent(R.id.photo_image, launchIntent)

            val path = when {
                paths.length() == 0 -> data.getString("photo_path", "") ?: ""
                rotate -> {
                    val rawIndex = ((System.currentTimeMillis() / ROTATION_INTERVAL_MS) % paths.length()).toInt()
                    val safeIndex = (rawIndex + paths.length()) % paths.length()
                    paths.optString(safeIndex)
                }
                else -> paths.optString(0)
            }
            val target = widgetTargetPixels(context, manager, id)
            val bitmap = decodeWidgetBitmap(path, target.first, target.second)
            if (bitmap != null) {
                view.setImageViewBitmap(R.id.photo_image, bitmap)
            } else {
                view.setImageViewResource(R.id.photo_image, R.drawable.widget_placeholder)
            }
            manager.updateAppWidget(id, view)
        }

        if (rotate && paths.length() > 1 && ids.isNotEmpty()) {
            scheduleNextUpdate(context)
        } else {
            cancelScheduledUpdates(context)
        }
    }

    override fun onDisabled(context: Context) {
        super.onDisabled(context)
        cancelScheduledUpdates(context)
    }

    private fun scheduleNextUpdate(context: Context) {
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
        val intent = Intent(context, PhotoWidgetProvider::class.java).apply {
            action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
            val ids = AppWidgetManager.getInstance(context).getAppWidgetIds(
                ComponentName(context, PhotoWidgetProvider::class.java)
            )
            putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
        val pendingIntent = PendingIntent.getBroadcast(context, ALARM_REQUEST_CODE, intent, flags)
        val triggerAtMillis = System.currentTimeMillis() + ROTATION_INTERVAL_MS
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC, triggerAtMillis, pendingIntent)
            } else {
                alarmManager.setExact(AlarmManager.RTC, triggerAtMillis, pendingIntent)
            }
        } catch (_: SecurityException) {
            alarmManager.set(AlarmManager.RTC, triggerAtMillis, pendingIntent)
        }
    }

    private fun cancelScheduledUpdates(context: Context) {
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
        val intent = Intent(context, PhotoWidgetProvider::class.java).apply {
            action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
        }
        val flags = PendingIntent.FLAG_NO_CREATE or (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
        val pendingIntent = PendingIntent.getBroadcast(context, ALARM_REQUEST_CODE, intent, flags)
        if (pendingIntent != null) {
            alarmManager.cancel(pendingIntent)
            pendingIntent.cancel()
        }
    }
}

class VerseWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray, data: SharedPreferences) {
        val launchIntent = getLaunchPendingIntent(context)
        val mode = data.getString("verse_mode", "daily")
        val verse = if (mode == "pinned" && !data.getString("verse_text", "").isNullOrBlank()) {
            Pair(
                data.getString("verse_text", "") ?: "",
                data.getString("verse_reference", "") ?: "",
            )
        } else {
            CuratedVerseSource.todaysVerse(context)
        }
        for (id in ids) {
            val view = RemoteViews(context.packageName, R.layout.verse_widget)
            view.setOnClickPendingIntent(R.id.verse_widget_container, launchIntent)
            view.setOnClickPendingIntent(R.id.verse_text, launchIntent)
            view.setTextViewText(R.id.verse_text, verse.first)
            view.setTextViewText(R.id.verse_reference, verse.second)
            manager.updateAppWidget(id, view)
        }
        scheduleDailyUpdate(context)
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action == MIDNIGHT_TICK ||
            intent.action == Intent.ACTION_TIME_CHANGED ||
            intent.action == Intent.ACTION_TIMEZONE_CHANGED ||
            intent.action == Intent.ACTION_BOOT_COMPLETED) {
            val manager = AppWidgetManager.getInstance(context)
            val verseIds = manager.getAppWidgetIds(ComponentName(context, VerseWidgetProvider::class.java))
            if (verseIds.isNotEmpty()) {
                val update = Intent(context, VerseWidgetProvider::class.java).apply {
                    action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
                    putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, verseIds)
                }
                context.sendBroadcast(update)
            }
            scheduleDailyUpdate(context)
        }
    }

    private fun scheduleDailyUpdate(context: Context) {
        val nextDay = Calendar.getInstance().apply {
            add(Calendar.DAY_OF_YEAR, 1)
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 5)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
        val pending = PendingIntent.getBroadcast(
            context,
            7001,
            Intent(context, VerseWidgetProvider::class.java).apply { action = MIDNIGHT_TICK },
            flags,
        )
        val alarms = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager ?: return
        alarms.setWindow(
            AlarmManager.RTC_WAKEUP,
            nextDay.timeInMillis,
            30 * 60 * 1000L,
            pending,
        )
    }
}

class WatchlistWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray, data: SharedPreferences) {
        val launchIntent = getLaunchPendingIntent(context)
        val items = try {
            JSONArray(data.getString("watchlist_json", "[]") ?: "[]")
        } catch (_: Exception) { JSONArray() }
        val lines = (0 until minOf(items.length(), 4)).map { index ->
            val item = items.optJSONObject(index)
            val check = if (item?.optBoolean("watched") == true) "✓" else "○"
            "$check  ${item?.optString("title") ?: ""}"
        }
        for (id in ids) {
            val view = RemoteViews(context.packageName, R.layout.watchlist_widget)
            view.setOnClickPendingIntent(R.id.watchlist_widget_container, launchIntent)
            view.setOnClickPendingIntent(R.id.watch_items, launchIntent)
            view.setTextViewText(R.id.watch_items,
                if (lines.isEmpty()) "Your watchlist is empty" else lines.joinToString("\n"))
            manager.updateAppWidget(id, view)
        }
    }
}
