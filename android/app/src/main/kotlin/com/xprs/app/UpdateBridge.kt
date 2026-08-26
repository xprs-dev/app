package com.xprs.app

import android.app.DownloadManager
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Environment
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * The half of the Update Center channel that needs nothing but a [Context].
 *
 * This exists because an always-on station never opens its UI. The channel used
 * to be registered only in MainActivity.configureFlutterEngine, so on a
 * headless engine (BootReceiver -> BgService -> ensureFlutterEngine) it did not
 * exist at all: every call threw MissingPluginException, Dart swallowed it and
 * returned null, and the update mirror downloaded nothing forever without one
 * line of complaint.
 *
 * So the download methods live here, attached per engine by
 * [NativeBridgeRegistry] exactly like BLE and WiFi Direct. The calls that
 * genuinely need a foreground Activity -- installing an APK, opening a settings
 * screen -- stay in MainActivity and reach us through [uiHandler], which is set
 * while an Activity is attached and null the rest of the time. One channel with
 * one handler: registering a second MethodChannel under the same name would
 * silently replace the first, and which one won would depend on attach order.
 */
object UpdateBridge {
    private const val TAG = "UpdateBridge"
    const val CHANNEL = "com.xprs.app/updates"

    /**
     * Set by MainActivity while it is attached. Returns true when it handled the
     * call. Null on a headless engine, where those methods are unreachable by
     * definition -- the mirror never installs anything.
     */
    @Volatile
    var uiHandler: ((MethodCall, MethodChannel.Result) -> Boolean)? = null

    private var channel: MethodChannel? = null
    private var engine: FlutterEngine? = null

    @Synchronized
    fun attach(context: Context, flutterEngine: FlutterEngine) {
        if (engine === flutterEngine && channel != null) return
        val app = context.applicationContext
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .also { ch -> ch.setMethodCallHandler { call, result -> handle(app, call, result) } }
        engine = flutterEngine
        Log.d(TAG, "update bridge attached")
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
            "getSupportedAbis" ->
                result.success(android.os.Build.SUPPORTED_ABIS.toList())
            "getCurrentApkPath" -> result.success(app.applicationInfo.sourceDir)
            // System DownloadManager: a process-independent download that survives
            // the app being closed, auto-resumes an interrupted transfer, and only
            // reports success once the whole file has landed (so we never hand a
            // truncated APK to the installer or to the folder differ). The bytes go
            // straight to disk and never enter the Dart heap.
            "enqueueDownload" -> {
                val url = call.argument<String>("url")
                val name = call.argument<String>("filename")
                if (url == null || name == null) {
                    result.error("ARG", "url and filename required", null)
                } else {
                    val title = call.argument<String>("title") ?: "XPRS update"
                    result.success(enqueueDownload(app, url, name, title))
                }
            }
            "queryDownload" -> {
                val id = (call.argument<Number>("id"))?.toLong()
                if (id == null) result.error("ARG", "id required", null)
                else result.success(queryDownload(app, id))
            }
            "removeDownload" -> {
                val id = (call.argument<Number>("id"))?.toLong()
                if (id != null) removeDownload(app, id)
                result.success(true)
            }
            else -> {
                val ui = uiHandler
                if (ui == null || !ui(call, result)) {
                    // Headless: no Activity to install from or show settings on.
                    result.error(
                        "NO_UI",
                        "${call.method} needs a foreground Activity",
                        null,
                    )
                }
            }
        }
    }

    private fun dm(ctx: Context): DownloadManager =
        ctx.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager

    /**
     * Enqueue a background download into the app's external files dir (no storage
     * permission needed, and readable by the FileProvider for install). Returns the
     * DownloadManager id, or -1 on failure. Cleans any stale file of the same name
     * first so a fresh enqueue doesn't collide with a partial from a prior run.
     */
    private fun enqueueDownload(
        ctx: Context,
        url: String,
        filename: String,
        title: String,
    ): Long {
        return try {
            val dir = ctx.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
            File(dir, filename).takeIf { it.exists() }?.delete()
            val req = DownloadManager.Request(Uri.parse(url))
                .setTitle(title)
                .setDescription(filename)
                .setNotificationVisibility(
                    DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED,
                )
                .setDestinationInExternalFilesDir(
                    ctx, Environment.DIRECTORY_DOWNLOADS, filename,
                )
                .setAllowedOverMetered(true)
                .setAllowedOverRoaming(true)
                .addRequestHeader("User-Agent", "xprs-updater")
            dm(ctx).enqueue(req)
        } catch (e: Exception) {
            Log.e(TAG, "enqueueDownload failed: ${e.message}")
            -1L
        }
    }

    /**
     * Poll a DownloadManager job. Returns a map Dart reads:
     *   status: "pending"|"running"|"paused"|"success"|"failed"|"unknown"
     *   downloaded/total: bytes (total is -1 until the server sends Content-Length)
     *   localPath: absolute file path once successful, else null
     *   reason: the numeric failure/paused reason (0 when not applicable)
     */
    private fun queryDownload(ctx: Context, id: Long): Map<String, Any?> {
        var cursor: Cursor? = null
        return try {
            cursor = dm(ctx).query(DownloadManager.Query().setFilterById(id))
            if (cursor == null || !cursor.moveToFirst()) {
                return mapOf("status" to "unknown")
            }
            fun col(name: String) = cursor.getColumnIndex(name)
            val statusCode = cursor.getInt(col(DownloadManager.COLUMN_STATUS))
            val downloaded =
                cursor.getLong(col(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR))
            val total = cursor.getLong(col(DownloadManager.COLUMN_TOTAL_SIZE_BYTES))
            val reason = cursor.getInt(col(DownloadManager.COLUMN_REASON))
            var localPath: String? = null
            if (statusCode == DownloadManager.STATUS_SUCCESSFUL) {
                val localUri = cursor.getString(col(DownloadManager.COLUMN_LOCAL_URI))
                if (localUri != null) localPath = Uri.parse(localUri).path
            }
            val status = when (statusCode) {
                DownloadManager.STATUS_PENDING -> "pending"
                DownloadManager.STATUS_RUNNING -> "running"
                DownloadManager.STATUS_PAUSED -> "paused"
                DownloadManager.STATUS_SUCCESSFUL -> "success"
                DownloadManager.STATUS_FAILED -> "failed"
                else -> "unknown"
            }
            mapOf(
                "status" to status,
                "downloaded" to downloaded,
                "total" to total,
                "localPath" to localPath,
                "reason" to reason,
            )
        } catch (e: Exception) {
            mapOf("status" to "unknown")
        } finally {
            cursor?.close()
        }
    }

    private fun removeDownload(ctx: Context, id: Long) {
        try {
            dm(ctx).remove(id)
        } catch (_: Exception) {
        }
    }
}
