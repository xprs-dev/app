package com.xprs.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * Foreground service that keeps the app process alive (with a persistent
 * notification) so background wapps keep receiving with the screen off / app
 * backgrounded. It drives a periodic heartbeat into Dart ('onTick' on the
 * bg_service channel) because Dart Timers are throttled in the background
 * while this native Handler is not — see BackgroundWappManager.tickAllFromNative.
 */
class BgService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var wifiLockMode: Int = -1
    private var multicastLock: WifiManager.MulticastLock? = null

    /**
     * Screen state, straight from the system. Dart cannot see this while it is
     * headless (there is no Activity to receive a lifecycle event), and the
     * screen is the single biggest input to "is anybody waiting for this".
     */
    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val on = when (intent?.action) {
                Intent.ACTION_SCREEN_ON, Intent.ACTION_USER_PRESENT -> true
                Intent.ACTION_SCREEN_OFF -> false
                else -> return
            }
            try {
                (XprsApplication.bgChannel ?: MainActivity.channel)
                    ?.invokeMethod("power.screen", on)
            } catch (_: Throwable) {
            }
        }
    }

    private val ticker = object : Runnable {
        override fun run() {
            // In the saving tiers there is no standing wake lock (see
            // applyTier), so the tick takes one for itself with a short
            // timeout: enough for Dart to do its housekeeping, impossible to
            // leak. Inbound work — a scan result, socket data — wakes the
            // process on its own and does not depend on this.
            val transient = if (tickWakeLock) wakeLock else null
            try {
                transient?.acquire(3_000L)
            } catch (_: Throwable) {
            }
            try {
                // Prefer the shared channel (set whether the engine is headless
                // from boot or owned by the Activity); fall back to the Activity's.
                (XprsApplication.bgChannel ?: MainActivity.channel)
                    ?.invokeMethod("onTick", null)
            } catch (_: Throwable) {
            }
            handler.postDelayed(this, tickMs)
        }
    }

    /**
     * Apply a tier published by Dart's PowerState. Three dials, none of which
     * can stop delivery: how often the heartbeat fires, whether the CPU wake
     * lock stands or is taken per tick, and how hard the WiFi radio is held.
     * The multicast lock is NOT one of them — Reticulum's LAN discovery is
     * broadcast, and dropping it makes the device deaf to its neighbours.
     */
    fun applyTier(t: String) {
        tier = t
        val saving = t == "battery" || t == "low"
        tickMs = when (t) {
            "battery" -> 10_000L
            "low" -> 30_000L
            else -> 2_000L
        }
        tickWakeLock = saving
        val wl = wakeLock
        if (wl != null) {
            // Saving: drop the standing lock (the ticker takes a bounded one).
            // Otherwise: hold it, as this service always did.
            try {
                if (saving && wl.isHeld) wl.release()
                if (!saving && !wl.isHeld) wl.acquire()
            } catch (_: Throwable) {
            }
        }
        @Suppress("DEPRECATION")
        val mode = if (saving) WifiManager.WIFI_MODE_FULL else WifiManager.WIFI_MODE_FULL_HIGH_PERF
        ensureWifiLock(mode)
        // Re-arm at the new cadence rather than waiting out the old one.
        handler.removeCallbacks(ticker)
        handler.postDelayed(ticker, tickMs)
    }

    /**
     * A WifiLock's mode is fixed at creation, so a mode change means a new
     * lock. High-performance keeps the radio out of power-save so the device
     * stays REACHABLE (incoming seeds, pushed data) — worth its cost while
     * somebody is looking or the phone is on a charger, not at 4 a.m. on
     * battery, where a plain full lock still keeps WiFi associated.
     */
    private fun ensureWifiLock(mode: Int) {
        if (wifiLock != null && wifiLockMode == mode) return
        val wm = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
        val old = wifiLock
        try {
            @Suppress("DEPRECATION")
            val fresh = wm.createWifiLock(mode, "aurora:wifi")
                .apply { setReferenceCounted(false); acquire() }
            wifiLock = fresh
            wifiLockMode = mode
        } catch (_: Throwable) {
            return
        }
        try { if (old != null && old.isHeld) old.release() } catch (_: Throwable) {}
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra("text") ?: "Running in background"
        startAsForeground(text)

        // There may be no Activity (boot/system restart), so make sure a cached
        // Flutter engine exists and has the native BLE/WiFi bridges attached.
        XprsApplication.instance?.ensureFlutterEngine()
        if (wakeLock == null) {
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "aurora:bg")
                .apply { setReferenceCounted(false); acquire() }
        }
        // Keep WiFi fully powered with the screen off. The wake lock alone keeps
        // the CPU running, but WiFi power-save still stops the device from
        // serving INCOMING connections (Blossom / BitTorrent seeds) and adds
        // latency to pushed APRS-IS data. A high-perf WiFi lock keeps the radio
        // up so a backgrounded/asleep device stays reachable by other devices.
        @Suppress("DEPRECATION")
        ensureWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF)
        // Reticulum finds peers on the LAN with UDP broadcast, and Android's
        // WiFi chip drops broadcast/multicast frames before userspace unless a
        // multicast lock is held. MainActivity holds one — but only while the
        // Activity exists, so with the screen off (or after a boot with no UI)
        // the device went deaf to its own neighbours: it kept announcing and
        // stopped hearing anyone. Hold it for as long as this service lives.
        if (multicastLock == null) {
            try {
                val wm = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
                multicastLock = wm.createMulticastLock("aurora-rns-lan-bg")
                    .apply { setReferenceCounted(false); acquire() }
            } catch (_: Throwable) {
            }
        }
        if (!screenReceiverOn) {
            try {
                registerReceiver(
                    screenReceiver,
                    IntentFilter().apply {
                        addAction(Intent.ACTION_SCREEN_ON)
                        addAction(Intent.ACTION_SCREEN_OFF)
                        addAction(Intent.ACTION_USER_PRESENT)
                    },
                )
                screenReceiverOn = true
            } catch (_: Throwable) {
            }
        }
        live = this
        // A restart (START_STICKY, or a second start intent) must not silently
        // return the process to full price: re-apply whatever tier Dart last
        // published.
        applyTier(tier)
        handler.removeCallbacks(ticker)
        handler.postDelayed(ticker, tickMs)
        return START_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacks(ticker)
        if (screenReceiverOn) {
            try { unregisterReceiver(screenReceiver) } catch (_: Throwable) {}
            screenReceiverOn = false
        }
        if (live === this) live = null
        wifiLockMode = -1
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        wifiLock?.let { if (it.isHeld) it.release() }
        wifiLock = null
        multicastLock?.let { if (it.isHeld) it.release() }
        multicastLock = null
        super.onDestroy()
    }

    private fun startAsForeground(text: String) {
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
        } else {
            0
        }
        ServiceCompat.startForeground(this, NOTIF_ID, buildNotification(text), type)
    }

    private fun buildNotification(text: String): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID,
                        "Background services",
                        NotificationManager.IMPORTANCE_LOW,
                    ).apply {
                        // Status, not news: the ongoing keep-alive must never
                        // put a dot on the launcher icon. Only aurora_events
                        // (real messages) may badge.
                        setShowBadge(false)
                    },
                )
                // The pre-badge-policy channel; its settings are sticky, so a
                // rename is the only way existing installs lose the dot.
                nm.deleteNotificationChannel("aurora_bg")
            }
        }
        val pi = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("XPRS")
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_stat_xprs)
            .setOngoing(true)
            .setContentIntent(pi)
            .build()
    }

    companion object {
        // Renamed from "aurora_bg": channel settings are immutable once
        // created, and the old channel badged the launcher icon forever.
        private const val CHANNEL_ID = "aurora_service"
        private const val NOTIF_ID = 7001
        /** The heartbeat period, set by [applyTier]. 2 s is the active rate
         *  this service always used; the saving tiers stretch it. Riders
         *  tolerate that: the BLE watchdogs trigger on 120-150 s of silence
         *  and catch-up self-gates. Inbound events do not wait for a tick. */
        @Volatile private var tickMs = 2000L

        /** In the saving tiers the ticker takes a bounded wake lock instead of
         *  the service holding one permanently. */
        @Volatile private var tickWakeLock = false

        /** Last tier published by Dart, re-applied on every (re)start. */
        @Volatile private var tier = "active"

        /** The running service, so a tier can be applied without an Intent. */
        @Volatile private var live: BgService? = null

        private var screenReceiverOn = false

        /** Called from the bg_service channel when Dart's PowerState changes. */
        fun setTier(t: String) {
            tier = t
            live?.let { s -> s.handler.post { s.applyTier(t) } }
        }
        const val ACTION_START_FROM_BOOT = "com.xprs.app.START_FROM_BOOT"

        /** Start the service from the boot receiver (no Activity available). */
        fun startFromBoot(context: Context) {
            val i = Intent(context, BgService::class.java).apply {
                action = ACTION_START_FROM_BOOT
                putExtra("text", "Internet without internet")
            }
            ContextCompat.startForegroundService(context, i)
        }
    }
}
