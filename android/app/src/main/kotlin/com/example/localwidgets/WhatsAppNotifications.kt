package com.example.localwidgets

import android.app.Notification
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private const val WHATSAPP_PACKAGE = "com.whatsapp"
private const val WHATSAPP_BUSINESS_PACKAGE = "com.whatsapp.w4b"
private const val WHATSAPP_PREFS = "still_whatsapp"
private const val NOTIFICATIONS_KEY = "notifications"
private const val NOTIFICATION_LOG_TAG = "StillNotifications"

internal object WhatsAppNotificationStore {
    private const val MAX_SAVED_NOTIFICATIONS = 500

    fun isWhatsAppPackage(packageName: String): Boolean {
        return packageName == WHATSAPP_PACKAGE || packageName == WHATSAPP_BUSINESS_PACKAGE
    }

    @Synchronized
    fun mergeActive(context: Context, activeNotifications: Array<StatusBarNotification>) {
        val saved = read(context).associateByTo(linkedMapOf()) { it.key }
        activeNotifications
            .asSequence()
            .filter { isWhatsAppPackage(it.packageName) }
            .filter { it.notification.flags and Notification.FLAG_GROUP_SUMMARY == 0 }
            .flatMap { parse(it).asSequence() }
            .forEach { item -> saved[item.key] = item }
        Log.d(NOTIFICATION_LOG_TAG, "Merged active notifications; saved=${saved.size}")
        save(context, saved.values)
    }

    @Synchronized
    fun upsert(context: Context, notification: StatusBarNotification) {
        if (notification.notification.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        val parsed = parse(notification)
        if (parsed.isEmpty()) return
        val saved = read(context).associateByTo(linkedMapOf()) { it.key }
        parsed.forEach { item -> saved[item.key] = item }
        Log.d(
            NOTIFICATION_LOG_TAG,
            "Captured ${parsed.size} message(s) from ${notification.packageName}; saved=${saved.size}",
        )
        save(context, saved.values)
    }

    @Synchronized
    fun onRemoved(context: Context, notification: StatusBarNotification, reason: Int) {
        if (!wasReadOrOpened(reason)) {
            // Swiping or clearing the notification shade must not erase the widget history.
            return
        }
        val saved = read(context).toMutableList()
        val removed = saved.removeAll { it.notificationKey == notification.key }
        if (!removed) {
            val sender = notification.notification.extras
                .getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim()
            if (!sender.isNullOrEmpty()) {
                saved.removeAll { it.packageName == notification.packageName && it.sender == sender }
            }
        }
        save(context, saved)
    }

    private fun wasReadOrOpened(reason: Int): Boolean {
        return reason == NotificationListenerService.REASON_CLICK ||
            reason == NotificationListenerService.REASON_APP_CANCEL ||
            reason == NotificationListenerService.REASON_APP_CANCEL_ALL
    }

    private fun read(context: Context): List<WhatsAppNotification> {
        val raw = context.getSharedPreferences(WHATSAPP_PREFS, Context.MODE_PRIVATE)
            .getString(NOTIFICATIONS_KEY, "[]") ?: "[]"
        val json = try {
            JSONArray(raw)
        } catch (_: Exception) {
            JSONArray()
        }
        return (0 until json.length()).mapNotNull { index ->
            val item = json.optJSONObject(index) ?: return@mapNotNull null
            val sender = item.optString("sender", "WhatsApp")
            val packageName = item.optString("package", WHATSAPP_PACKAGE)
            WhatsAppNotification(
                key = item.optString("key").ifEmpty { "$packageName:$sender" },
                notificationKey = item.optString("notification_key")
                    .ifEmpty { item.optString("key", "$packageName:$sender") },
                sender = sender,
                message = item.optString("message", "Message preview hidden"),
                timestamp = item.optLong("timestamp"),
                packageName = packageName,
            )
        }
    }

    private fun save(context: Context, notifications: Collection<WhatsAppNotification>) {
        val sorted = notifications.sortedByDescending { it.timestamp }
            .take(MAX_SAVED_NOTIFICATIONS)

        val json = JSONArray()
        sorted.forEach { item ->
            json.put(JSONObject().apply {
                put("key", item.key)
                put("notification_key", item.notificationKey)
                put("sender", item.sender)
                put("message", item.message)
                put("timestamp", item.timestamp)
                put("package", item.packageName)
            })
        }
        context.getSharedPreferences(WHATSAPP_PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(NOTIFICATIONS_KEY, json.toString())
            .apply()
        WhatsAppWidgetProvider.updateAll(context)
    }

    private fun parse(sbn: StatusBarNotification): List<WhatsAppNotification> {
        val extras = sbn.notification.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)
            ?.toString()
            ?.trim()
            .orEmpty()
        val conversation = extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)
            ?.toString()
            ?.trim()
            .orEmpty()
        val messages = extras.getParcelableArray(Notification.EXTRA_MESSAGES)
            ?.mapNotNull { it as? Bundle }
            .orEmpty()
            .mapNotNull { bundle ->
                val text = bundle.getCharSequence("text")?.toString()?.trim().orEmpty()
                if (text.isEmpty()) return@mapNotNull null
                val messageSender = when (val rawSender = bundle.get("sender_person") ?: bundle.get("sender")) {
                    is CharSequence -> rawSender.toString().trim()
                    null -> ""
                    else -> try {
                        rawSender.javaClass.getMethod("getName").invoke(rawSender)
                            ?.toString()?.trim().orEmpty()
                    } catch (_: Exception) {
                        ""
                    }
                }
                val sender = conversation.ifEmpty { title }.ifEmpty { messageSender }.ifEmpty { "WhatsApp" }
                val body = if (conversation.isNotEmpty() && messageSender.isNotEmpty() && messageSender != sender) {
                    "$messageSender: $text"
                } else {
                    text
                }
                val timestamp = bundle.getLong("time", 0L)
                    .takeIf { it > 0L }
                    ?: sbn.notification.`when`.takeIf { it > 0L }
                    ?: sbn.postTime
                WhatsAppNotification(
                    key = "${sbn.key}|$timestamp|${body.hashCode()}",
                    notificationKey = sbn.key,
                    sender = sender,
                    message = body,
                    timestamp = timestamp,
                    packageName = sbn.packageName,
                )
            }
        if (messages.isNotEmpty()) return messages

        val message = sequenceOf(
            extras.getCharSequence(Notification.EXTRA_TEXT),
            extras.getCharSequence(Notification.EXTRA_BIG_TEXT),
        ).mapNotNull { it?.toString()?.trim() }
            .firstOrNull { it.isNotEmpty() }
            .orEmpty()
        if (title.isEmpty() && message.isEmpty()) return emptyList()
        val timestamp = sbn.notification.`when`.takeIf { it > 0L } ?: sbn.postTime
        return listOf(WhatsAppNotification(
            key = "${sbn.key}|$timestamp|${message.hashCode()}",
            notificationKey = sbn.key,
            sender = conversation.ifEmpty { title }.ifEmpty { "WhatsApp" },
            message = message.ifEmpty { "Message preview hidden" },
            timestamp = timestamp,
            packageName = sbn.packageName,
        ))
    }
}

private data class WhatsAppNotification(
    val key: String,
    val notificationKey: String,
    val sender: String,
    val message: String,
    val timestamp: Long,
    val packageName: String,
)

class WhatsAppWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        ids.forEach { update(context, manager, it) }
    }

    companion object {
        fun updateAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, WhatsAppWidgetProvider::class.java))
            ids.forEach { update(context, manager, it) }
            manager.notifyAppWidgetViewDataChanged(ids, R.id.whatsapp_list)
        }

        private fun update(context: Context, manager: AppWidgetManager, widgetId: Int) {
            val prefs = context.getSharedPreferences(WHATSAPP_PREFS, Context.MODE_PRIVATE)
            val items = try {
                JSONArray(prefs.getString(NOTIFICATIONS_KEY, "[]") ?: "[]")
            } catch (_: Exception) {
                JSONArray()
            }
            val view = RemoteViews(context.packageName, R.layout.whatsapp_widget)
            val count = items.length()
            view.setTextViewText(
                R.id.whatsapp_count,
                if (count == 1) "1 notification" else "$count notifications",
            )
            val serviceIntent = Intent(context, WhatsAppWidgetService::class.java).apply {
                putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)
                data = Uri.parse(toUri(Intent.URI_INTENT_SCHEME))
            }
            view.setRemoteAdapter(R.id.whatsapp_list, serviceIntent)
            view.setEmptyView(R.id.whatsapp_list, R.id.whatsapp_empty)

            val preferredPackage = items.optJSONObject(0)?.optString("package")
                ?.takeIf { isInstalled(context, it) }
                ?: listOf(WHATSAPP_PACKAGE, WHATSAPP_BUSINESS_PACKAGE)
                    .firstOrNull { isInstalled(context, it) }
            val launch = preferredPackage?.let(context.packageManager::getLaunchIntentForPackage)
                ?: context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?: Intent(context, MainActivity::class.java)
            launch.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
            val pending = PendingIntent.getActivity(context, 3501, launch, flags)
            view.setOnClickPendingIntent(R.id.whatsapp_open, pending)
            view.setPendingIntentTemplate(R.id.whatsapp_list, pending)
            manager.updateAppWidget(widgetId, view)
        }

        @Suppress("DEPRECATION")
        private fun isInstalled(context: Context, packageName: String): Boolean {
            return try {
                context.packageManager.getPackageInfo(packageName, 0)
                true
            } catch (_: Exception) {
                false
            }
        }

    }
}

class WhatsAppWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory {
        return WhatsAppWidgetFactory(applicationContext)
    }
}

private class WhatsAppWidgetFactory(private val context: Context) : RemoteViewsService.RemoteViewsFactory {
    private var items = JSONArray()

    override fun onCreate() = Unit

    override fun onDataSetChanged() {
        val raw = context.getSharedPreferences(WHATSAPP_PREFS, Context.MODE_PRIVATE)
            .getString(NOTIFICATIONS_KEY, "[]") ?: "[]"
        items = try {
            JSONArray(raw)
        } catch (_: Exception) {
            JSONArray()
        }
    }

    override fun onDestroy() {
        items = JSONArray()
    }

    override fun getCount(): Int = items.length()

    override fun getViewAt(position: Int): RemoteViews? {
        val item = items.optJSONObject(position) ?: return null
        val sender = item.optString("sender", "WhatsApp")
        return RemoteViews(context.packageName, R.layout.whatsapp_widget_row).apply {
            setTextViewText(
                R.id.whatsapp_initial,
                sender.trim().firstOrNull()?.uppercaseChar()?.toString() ?: "W",
            )
            setTextViewText(R.id.whatsapp_sender, sender)
            setTextViewText(R.id.whatsapp_message, item.optString("message", ""))
            setTextViewText(R.id.whatsapp_time, formatTime(item.optLong("timestamp")))
            setOnClickFillInIntent(R.id.whatsapp_row, Intent())
        }
    }

    override fun getLoadingView(): RemoteViews? = null

    override fun getViewTypeCount(): Int = 1

    override fun getItemId(position: Int): Long {
        return items.optJSONObject(position)?.optString("key")?.hashCode()?.toLong()
            ?: position.toLong()
    }

    override fun hasStableIds(): Boolean = true

    private fun formatTime(timestamp: Long): String {
        if (timestamp <= 0L) return ""
        return SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(timestamp))
    }
}
