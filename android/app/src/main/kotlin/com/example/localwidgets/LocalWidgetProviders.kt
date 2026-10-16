package com.example.localwidgets

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.graphics.BitmapFactory
import android.os.Build
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetProvider
import org.json.JSONArray

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
        for (id in ids) {
            val view = RemoteViews(context.packageName, R.layout.photo_widget)
            val path = when {
                paths.length() == 0 -> data.getString("photo_path", "") ?: ""
                rotate -> {
                    val rawIndex = ((System.currentTimeMillis() / ROTATION_INTERVAL_MS) % paths.length()).toInt()
                    val safeIndex = (rawIndex + paths.length()) % paths.length()
                    paths.optString(safeIndex)
                }
                else -> paths.optString(0)
            }
            val bitmap = BitmapFactory.decodeFile(path)
            if (bitmap != null) view.setImageViewBitmap(R.id.photo_image, bitmap)
            else view.setImageViewResource(R.id.photo_image, R.drawable.widget_placeholder)
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
        for (id in ids) {
            val view = RemoteViews(context.packageName, R.layout.verse_widget)
            view.setTextViewText(R.id.verse_text,
                data.getString("verse_text", "Be still, and know that I am God."))
            view.setTextViewText(R.id.verse_reference,
                data.getString("verse_reference", "Psalm 46:10"))
            manager.updateAppWidget(id, view)
        }
    }
}

class WatchlistWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray, data: SharedPreferences) {
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
            view.setTextViewText(R.id.watch_items,
                if (lines.isEmpty()) "Your watchlist is empty" else lines.joinToString("\n"))
            manager.updateAppWidget(id, view)
        }
    }
}
