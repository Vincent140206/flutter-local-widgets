package com.example.localwidgets

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val SPOTIFY_CHANNEL = "com.example.localwidgets/spotify"
        private const val WHATSAPP_CHANNEL = "com.example.localwidgets/whatsapp"
        private const val ISLAND_CHANNEL = "com.example.localwidgets/island"
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ISLAND_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasOverlayPermission" -> result.success(Settings.canDrawOverlays(this))
                    "openOverlayPermission" -> {
                        startActivity(
                            Intent(
                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                Uri.parse("package:$packageName"),
                            ),
                        )
                        result.success(null)
                    }
                    "isEnabled" -> result.success(isIslandEnabled())
                    "setEnabled" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        result.success(setIslandEnabled(enabled))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onResume() {
        super.onResume()
        if (isIslandEnabled() && Settings.canDrawOverlays(this)) startIslandService()
    }

    private fun isIslandEnabled(): Boolean {
        return getSharedPreferences(StillIslandService.PREFS, MODE_PRIVATE)
            .getBoolean(StillIslandService.ENABLED_KEY, false)
    }

    private fun setIslandEnabled(enabled: Boolean): Boolean {
        if (enabled && !Settings.canDrawOverlays(this)) return false
        getSharedPreferences(StillIslandService.PREFS, MODE_PRIVATE)
            .edit()
            .putBoolean(StillIslandService.ENABLED_KEY, enabled)
            .apply()
        if (enabled) startIslandService() else stopService(Intent(this, StillIslandService::class.java))
        return enabled
    }

    private fun startIslandService() {
        val intent = Intent(this, StillIslandService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun refreshNotificationListener() {
        if (!hasNotificationAccess()) return
        SpotifyMediaListener.ensureConnected(this)
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
