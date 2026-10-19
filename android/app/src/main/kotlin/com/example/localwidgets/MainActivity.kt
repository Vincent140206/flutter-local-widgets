package com.example.localwidgets

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.os.Build
import android.provider.Settings
import android.service.notification.NotificationListenerService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val SPOTIFY_CHANNEL = "com.example.localwidgets/spotify"
        private const val WHATSAPP_CHANNEL = "com.example.localwidgets/whatsapp"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SPOTIFY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasNotificationAccess" -> result.success(hasNotificationAccess())
                    "refreshNotificationListener" -> {
                        refreshNotificationListener()
                        result.success(null)
                    }
                    "openNotificationAccess" -> {
                        startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                        result.success(null)
                    }
                    "requestPinWidget" -> result.success(requestSpotifyWidgetPin())
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WHATSAPP_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasNotificationAccess" -> result.success(hasNotificationAccess())
                    "refreshNotificationListener" -> {
                        refreshNotificationListener()
                        result.success(null)
                    }
                    "openNotificationAccess" -> {
                        startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                        result.success(null)
                    }
                    "requestPinWidget" -> result.success(
                        requestWidgetPin(WhatsAppWidgetProvider::class.java),
                    )
                    else -> result.notImplemented()
                }
            }
    }

    private fun refreshNotificationListener() {
        if (!hasNotificationAccess() || Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return
        NotificationListenerService.requestRebind(
            ComponentName(this, SpotifyMediaListener::class.java),
        )
    }

    private fun hasNotificationAccess(): Boolean {
        val enabled = Settings.Secure.getString(
            contentResolver,
            "enabled_notification_listeners",
        ) ?: return false
        return enabled.split(":").any {
            ComponentName.unflattenFromString(it)?.packageName == packageName
        }
    }

    private fun requestSpotifyWidgetPin(): Boolean {
        return requestWidgetPin(SpotifyWidgetProvider::class.java)
    }

    private fun requestWidgetPin(provider: Class<*>): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val manager = getSystemService(AppWidgetManager::class.java)
        if (!manager.isRequestPinAppWidgetSupported) return false
        return manager.requestPinAppWidget(
            ComponentName(this, provider),
            null,
            null,
        )
    }
}
