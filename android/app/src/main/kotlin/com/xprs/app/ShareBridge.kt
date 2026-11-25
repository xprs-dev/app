package com.xprs.app

import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Share (drawer -> Share): what Dart cannot reach by itself.
 *
 *   apkInfo             -> where the installed APK lives, and whether it is
 *                          one file
 *   openHotspotSettings -> the system's own hotspot screen
 *
 * The HTTP server (the web portal) is Dart (ShareAppService). Engine-scoped,
 * attached by NativeBridgeRegistry, so it answers on the headless engine an
 * always-on phone boots into, not only while the Activity exists: the portal
 * comes back after a reboot with nobody opening the app.
 *
 * There is no app-made hotspot any more. Android's LocalOnlyHotspot was used
 * until 2026-11-25, when the OUKITEL C61 (Android 15) was measured reporting
 * "AndroidShare_3712, WPA2/WPA3" to the app while its radio beaconed the
 * system hotspot's own name and WPA2 key: the QR named a network that did
 * not exist. It also lived only as long as the Activity, which a portal left
 * on as a station outlives. The system hotspot is what the person can see,
 * name, and leave on.
 */
object ShareBridge {
    private const val CHANNEL = "com.xprs.app/share"
    private const val TAG = "ShareBridge"

    private var channel: MethodChannel? = null
    private var engine: FlutterEngine? = null

    @Synchronized
    fun attach(context: Context, flutterEngine: FlutterEngine) {
        if (engine === flutterEngine && channel != null) return
        val app = context.applicationContext
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .also { ch -> ch.setMethodCallHandler { call, result -> handle(app, call, result) } }
        engine = flutterEngine
    }

    @Synchronized
    fun dispose(flutterEngine: FlutterEngine) {
        if (engine !== flutterEngine) return
        channel?.setMethodCallHandler(null)
        channel = null
        engine = null
    }

    private fun handle(app: Context, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "apkInfo" -> result.success(apkInfo(app))
            "openHotspotSettings" -> result.success(openHotspotSettings(app))
            else -> result.notImplemented()
        }
    }

    private fun apkInfo(app: Context): Map<String, Any?> {
        val ai = app.applicationInfo
        return mapOf(
            "path" to ai.sourceDir,
            // A store bundle install is base.apk plus config splits; base.apk
            // alone does not install, so such a copy cannot be handed on.
            "splits" to (ai.splitSourceDirs?.size ?: 0),
            "size" to File(ai.sourceDir).length(),
            "abi" to (Build.SUPPORTED_ABIS.firstOrNull() ?: ""),
        )
    }

    /** The hotspot screen where there is one (a hidden but stable action),
     *  the network settings otherwise. */
    private fun openHotspotSettings(app: Context): Boolean {
        for (action in listOf("android.settings.TETHER_SETTINGS", Settings.ACTION_WIRELESS_SETTINGS)) {
            try {
                app.startActivity(Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return true
            } catch (e: Exception) {
                Log.w(TAG, "$action: ${e.message}")
            }
        }
        return false
    }
}
