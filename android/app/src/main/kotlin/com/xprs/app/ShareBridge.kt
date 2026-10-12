package com.xprs.app

import android.content.Context
import android.net.wifi.SoftApConfiguration
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * "Share app" (drawer -> Share app): what Dart cannot reach by itself.
 *
 *   apkInfo       -> where the installed APK lives, and whether it is one file
 *   startHotspot  -> a LocalOnlyHotspot (no internet, OS-chosen SSID and
 *                    passphrase) for a phone with no Wi-Fi in common with us
 *   stopHotspot   -> release it
 *
 * The HTTP server that hands out the APK is Dart (ShareAppService). UI engine
 * only: the hotspot exists while the Share app page is open, so this is owned
 * by MainActivity and closed in its onDestroy.
 */
class ShareBridge(context: Context, messenger: BinaryMessenger) {
    companion object {
        const val CHANNEL = "com.xprs.app/share"
        private const val TAG = "ShareBridge"
    }

    private val app = context.applicationContext
    private val channel = MethodChannel(messenger, CHANNEL)
    private val main = Handler(Looper.getMainLooper())
    private var reservation: WifiManager.LocalOnlyHotspotReservation? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "apkInfo" -> result.success(apkInfo())
                "startHotspot" -> startHotspot(result)
                "stopHotspot" -> { stopHotspot(); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }

    private fun apkInfo(): Map<String, Any?> {
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

    private fun startHotspot(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.error("unsupported", "LocalOnlyHotspot needs Android 8", null)
            return
        }
        val current = reservation
        if (current != null) {
            result.success(describe(current))
            return
        }
        val wifi = app.getSystemService(Context.WIFI_SERVICE) as WifiManager
        var replied = false
        try {
            wifi.startLocalOnlyHotspot(object : WifiManager.LocalOnlyHotspotCallback() {
                override fun onStarted(r: WifiManager.LocalOnlyHotspotReservation) {
                    reservation = r
                    if (!replied) { replied = true; result.success(describe(r)) }
                }

                override fun onStopped() {
                    reservation = null
                    channel.invokeMethod("hotspotStopped", null)
                }

                override fun onFailed(reason: Int) {
                    val code = when (reason) {
                        ERROR_NO_CHANNEL -> "no_channel"
                        ERROR_INCOMPATIBLE_MODE -> "incompatible_mode"
                        ERROR_TETHERING_DISALLOWED -> "tethering_disallowed"
                        else -> "generic"
                    }
                    Log.w(TAG, "LocalOnlyHotspot failed: $code")
                    if (!replied) { replied = true; result.error(code, null, null) }
                }
            }, main)
        } catch (e: SecurityException) {
            result.error("permission", e.message, null)
        } catch (e: IllegalStateException) {
            // Another request of ours is still outstanding.
            result.error("busy", e.message, null)
        }
    }

    @Suppress("DEPRECATION")
    private fun describe(r: WifiManager.LocalOnlyHotspotReservation): Map<String, Any?> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val c = r.softApConfiguration
            val security = when (c.securityType) {
                SoftApConfiguration.SECURITY_TYPE_OPEN -> "nopass"
                SoftApConfiguration.SECURITY_TYPE_WPA3_SAE -> "SAE"
                else -> "WPA"
            }
            return mapOf("ssid" to c.ssid, "psk" to c.passphrase, "security" to security)
        }
        val c = r.wifiConfiguration
        return mapOf(
            "ssid" to c?.SSID?.trim('"'),
            "psk" to c?.preSharedKey?.trim('"'),
            "security" to if (c?.preSharedKey.isNullOrEmpty()) "nopass" else "WPA",
        )
    }

    fun stopHotspot() {
        try {
            reservation?.close()
        } catch (_: Exception) {
        }
        reservation = null
    }

    fun dispose() {
        stopHotspot()
        channel.setMethodCallHandler(null)
    }
}
