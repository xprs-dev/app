package com.xprs.app

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * USB serial over the Android USB host API, for flashing a board from the
 * phone (lib/services/flash). No library: CDC-ACM is a class protocol and
 * the two UART bridges XPRS boards ship with (CP210x, CH34x) are a handful
 * of vendor requests each.
 *
 * Ported from geogram's UsbSerialPlugin and attached per engine by
 * [NativeBridgeRegistry] like the other bridges. Transfers run on an
 * executor; every answer is posted to the main thread, so Dart awaits and
 * never blocks. The CDC path is what every native-USB Espressif board
 * (S2/S3/C3) presents and is the one verified on the bench; the CP210x and
 * CH34x inits follow the datasheets and usb-serial-for-android and are
 * written, not yet exercised on a board.
 */
object UsbSerial {
    private const val TAG = "UsbSerial"
    const val CHANNEL = "com.xprs.app/usb_serial"
    private const val ACTION_USB_PERMISSION = "com.xprs.app.USB_PERMISSION"

    private const val CDC_COMM_CLASS = 0x02
    private const val CDC_DATA_CLASS = 0x0A
    private const val SET_LINE_CODING = 0x20
    private const val SET_CONTROL_LINE_STATE = 0x22

    private const val VID_ESPRESSIF = 0x303A
    private const val VID_SILABS = 0x10C4
    private const val VID_QINHENG = 0x1A86
    private const val VID_FTDI = 0x0403

    private val KNOWN = setOf(
        Pair(VID_ESPRESSIF, 0x1001), Pair(VID_ESPRESSIF, 0x0002),
        Pair(VID_SILABS, 0xEA60), Pair(VID_SILABS, 0xEA70),
        Pair(VID_QINHENG, 0x7523), Pair(VID_QINHENG, 0x55D4), Pair(VID_QINHENG, 0x5523),
        Pair(VID_FTDI, 0x6001), Pair(VID_FTDI, 0x6015),
    )

    private const val USB_TIMEOUT_MS = 1000
    private const val READ_MAX = 4096

    private enum class Kind { CDC, CP210X, CH34X }

    private class Conn(
        val connection: UsbDeviceConnection,
        val kind: Kind,
        val controlInterface: UsbInterface?,
        val dataInterface: UsbInterface,
        val readEndpoint: UsbEndpoint,
        val writeEndpoint: UsbEndpoint,
        var dtr: Boolean = true,
        var rts: Boolean = true,
    )

    private var channel: MethodChannel? = null
    private var engine: FlutterEngine? = null
    private var appContext: Context? = null
    private val main = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private val open = ConcurrentHashMap<String, Conn>()
    private val pendingPermission = ConcurrentHashMap<String, MethodChannel.Result>()
    private var receiver: BroadcastReceiver? = null

    @Synchronized
    fun attach(context: Context, flutterEngine: FlutterEngine) {
        if (engine === flutterEngine && channel != null) return
        val app = context.applicationContext
        appContext = app
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .also { ch -> ch.setMethodCallHandler { call, result -> handle(app, call, result) } }
        engine = flutterEngine
        registerReceiver(app)
        Log.d(TAG, "usb serial bridge attached")
    }

    @Synchronized
    fun dispose(flutterEngine: FlutterEngine) {
        if (engine !== flutterEngine) return
        closeAll()
        appContext?.let { unregisterReceiver(it) }
        channel?.setMethodCallHandler(null)
        channel = null
        engine = null
    }

    private fun manager(context: Context): UsbManager? =
        context.getSystemService(Context.USB_SERVICE) as? UsbManager

    private fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
        val name = call.argument<String>("deviceName")
        when (call.method) {
            "listDevices" -> listDevices(context, result)
            "hasPermission" -> {
                val m = manager(context)
                val d = name?.let { m?.deviceList?.get(it) }
                result.success(d != null && m?.hasPermission(d) == true)
            }
            "requestPermission" -> if (name != null) requestPermission(context, name, result)
                else result.error("INVALID_ARGUMENT", "deviceName required", null)
            "open" -> if (name != null) openDevice(context, name, call.argument<Int>("baudRate") ?: 115200, result)
                else result.error("INVALID_ARGUMENT", "deviceName required", null)
            "close" -> { name?.let { closeDevice(it) }; result.success(true) }
            "read" -> if (name != null) read(name, call.argument<Int>("maxBytes") ?: READ_MAX,
                    call.argument<Int>("timeoutMs") ?: USB_TIMEOUT_MS, result)
                else result.error("INVALID_ARGUMENT", "deviceName required", null)
            "write" -> {
                val data = call.argument<ByteArray>("data")
                if (name != null && data != null) write(name, data, result)
                else result.error("INVALID_ARGUMENT", "deviceName and data required", null)
            }
            "setDTR" -> withConn(name, result) { c ->
                c.dtr = call.argument<Boolean>("value") ?: false
                setModem(c)
            }
            "setRTS" -> withConn(name, result) { c ->
                c.rts = call.argument<Boolean>("value") ?: false
                setModem(c)
            }
            "setBaudRate" -> withConn(name, result) { c ->
                setBaud(c, call.argument<Int>("baudRate") ?: 115200)
            }
            "flush" -> withConn(name, result) { c ->
                val buf = ByteArray(READ_MAX)
                c.connection.bulkTransfer(c.readEndpoint, buf, buf.size, 20)
                true
            }
            else -> result.notImplemented()
        }
    }

    private fun withConn(name: String?, result: MethodChannel.Result, body: (Conn) -> Boolean) {
        val c = name?.let { open[it] }
        if (c == null) {
            result.error("NOT_OPEN", "device not open", null)
            return
        }
        executor.execute {
            val ok = try { body(c) } catch (t: Throwable) { Log.w(TAG, "control failed: ${t.message}"); false }
            main.post { result.success(ok) }
        }
    }

    private fun kindOf(device: UsbDevice): Kind? {
        if (device.vendorId == VID_SILABS) return Kind.CP210X
        if (device.vendorId == VID_QINHENG) return Kind.CH34X
        if (device.deviceClass == CDC_COMM_CLASS) return Kind.CDC
        for (i in 0 until device.interfaceCount) {
            val c = device.getInterface(i).interfaceClass
            if (c == CDC_COMM_CLASS || c == CDC_DATA_CLASS) return Kind.CDC
        }
        if (KNOWN.contains(Pair(device.vendorId, device.productId))) return Kind.CDC
        return null
    }

    private fun listDevices(context: Context, result: MethodChannel.Result) {
        val m = manager(context)
        if (m == null) {
            result.success(emptyList<Map<String, Any?>>())
            return
        }
        val out = mutableListOf<Map<String, Any?>>()
        for ((_, d) in m.deviceList) {
            if (kindOf(d) == null) continue
            out.add(mapOf(
                "deviceName" to d.deviceName,
                "vendorId" to d.vendorId,
                "productId" to d.productId,
                "manufacturerName" to d.manufacturerName,
                "productName" to d.productName,
                "serialNumber" to (try { if (m.hasPermission(d)) d.serialNumber else null } catch (_: SecurityException) { null }),
                "hasPermission" to m.hasPermission(d),
            ))
        }
        result.success(out)
    }

    private fun requestPermission(context: Context, name: String, result: MethodChannel.Result) {
        val m = manager(context)
        val d = m?.deviceList?.get(name)
        if (m == null || d == null) {
            result.error("NOT_FOUND", "no device $name", null)
            return
        }
        if (m.hasPermission(d)) {
            result.success(true)
            return
        }
        pendingPermission[name] = result
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
        else PendingIntent.FLAG_UPDATE_CURRENT
        val intent = Intent(ACTION_USB_PERMISSION).apply {
            setPackage(context.packageName)
            putExtra(UsbManager.EXTRA_DEVICE, d)
        }
        m.requestPermission(d, PendingIntent.getBroadcast(context, 0, intent, flags))
    }

    private fun openDevice(context: Context, name: String, baud: Int, result: MethodChannel.Result) {
        val m = manager(context)
        val d = m?.deviceList?.get(name)
        if (m == null || d == null) {
            result.error("NOT_FOUND", "no device $name", null)
            return
        }
        if (open.containsKey(name)) {
            result.success(true)
            return
        }
        if (!m.hasPermission(d)) {
            result.error("PERMISSION_DENIED", "no permission for $name", null)
            return
        }
        val kind = kindOf(d)
        if (kind == null) {
            result.error("NOT_SUPPORTED", "not a serial device this app drives", null)
            return
        }
        executor.execute {
            try {
                val conn = m.openDevice(d)
                if (conn == null) {
                    main.post { result.error("OPEN_FAILED", "cannot open $name", null) }
                    return@execute
                }
                val c = claim(d, conn, kind)
                if (c == null) {
                    conn.close()
                    main.post { result.error("NOT_SUPPORTED", "no bulk endpoints on $name", null) }
                    return@execute
                }
                init(c, baud)
                open[name] = c
                Log.d(TAG, "opened $name as $kind at $baud")
                main.post { result.success(true) }
            } catch (t: Throwable) {
                Log.e(TAG, "open failed: ${t.message}")
                main.post { result.error("OPEN_FAILED", t.message, null) }
            }
        }
    }

    private fun claim(device: UsbDevice, connection: UsbDeviceConnection, kind: Kind): Conn? {
        var control: UsbInterface? = null
        var data: UsbInterface? = null
        for (i in 0 until device.interfaceCount) {
            val iface = device.getInterface(i)
            when (iface.interfaceClass) {
                CDC_COMM_CLASS -> control = control ?: iface
                CDC_DATA_CLASS -> data = data ?: iface
            }
        }
        if (data == null) {
            // A vendor bridge: the first interface with a bulk pair.
            loop@ for (i in 0 until device.interfaceCount) {
                val iface = device.getInterface(i)
                for (j in 0 until iface.endpointCount) {
                    if (iface.getEndpoint(j).type == UsbConstants.USB_ENDPOINT_XFER_BULK) {
                        data = iface
                        break@loop
                    }
                }
            }
        }
        val di = data ?: return null
        var rd: UsbEndpoint? = null
        var wr: UsbEndpoint? = null
        for (j in 0 until di.endpointCount) {
            val ep = di.getEndpoint(j)
            if (ep.type != UsbConstants.USB_ENDPOINT_XFER_BULK) continue
            if (ep.direction == UsbConstants.USB_DIR_IN) rd = rd ?: ep else wr = wr ?: ep
        }
        if (rd == null || wr == null) return null
        if (!connection.claimInterface(di, true)) return null
        if (control != null && control != di && !connection.claimInterface(control, true)) {
            Log.w(TAG, "control interface not claimed")
        }
        return Conn(connection, kind, control ?: di, di, rd, wr)
    }

    private fun init(c: Conn, baud: Int) {
        when (c.kind) {
            Kind.CDC -> {
                setBaud(c, baud)
                setModem(c)
            }
            Kind.CP210X -> {
                // IFC_ENABLE, then 8N1 and the rate.
                vendorOut(c, 0x41, 0x00, 0x0001)
                vendorOut(c, 0x41, 0x03, 0x0800) // SET_LINE_CTL: 8 data, no parity, 1 stop
                setBaud(c, baud)
                setModem(c)
            }
            Kind.CH34X -> {
                val two = ByteArray(2)
                c.connection.controlTransfer(0xC0, 0x5F, 0, 0, two, 2, USB_TIMEOUT_MS)
                vendorOut(c, 0x40, 0xA1, 0, 0)
                setBaud(c, baud)
                c.connection.controlTransfer(0xC0, 0x95, 0x2518, 0, two, 2, USB_TIMEOUT_MS)
                vendorOut(c, 0x40, 0x9A, 0x2518, 0x00C3) // LCR: enable RX/TX, 8 bits
                c.connection.controlTransfer(0xC0, 0x95, 0x0706, 0, two, 2, USB_TIMEOUT_MS)
                vendorOut(c, 0x40, 0xA1, 0x501F, 0xD90A)
                setBaud(c, baud)
                setModem(c)
            }
        }
    }

    private fun vendorOut(c: Conn, type: Int, req: Int, value: Int, index: Int = 0, data: ByteArray? = null): Boolean {
        val n = c.connection.controlTransfer(type, req, value, index, data, data?.size ?: 0, USB_TIMEOUT_MS)
        if (n < 0) Log.w(TAG, "control 0x${req.toString(16)} failed: $n")
        return n >= 0
    }

    private fun setBaud(c: Conn, baud: Int): Boolean = when (c.kind) {
        Kind.CDC -> {
            val coding = byteArrayOf(
                (baud and 0xFF).toByte(), ((baud shr 8) and 0xFF).toByte(),
                ((baud shr 16) and 0xFF).toByte(), ((baud shr 24) and 0xFF).toByte(),
                0, 0, 8,
            )
            c.connection.controlTransfer(0x21, SET_LINE_CODING, 0, c.controlInterface?.id ?: 0,
                coding, coding.size, USB_TIMEOUT_MS) >= 0
        }
        Kind.CP210X -> {
            val b = byteArrayOf(
                (baud and 0xFF).toByte(), ((baud shr 8) and 0xFF).toByte(),
                ((baud shr 16) and 0xFF).toByte(), ((baud shr 24) and 0xFF).toByte(),
            )
            vendorOut(c, 0x41, 0x1E, 0, 0, b)
        }
        Kind.CH34X -> {
            var factor = 1532620800L / baud
            var divisor = 3
            while (factor > 0xFFF0 && divisor > 0) {
                factor = factor shr 3
                divisor--
            }
            if (factor > 0xFFF0) false else {
                factor = 0x10000 - factor
                divisor = divisor or 0x80
                vendorOut(c, 0x40, 0x9A, 0x1312, ((factor and 0xFF00) or divisor.toLong()).toInt()) &&
                    vendorOut(c, 0x40, 0x9A, 0x0F2C, (factor and 0xFF).toInt())
            }
        }
    }

    private fun setModem(c: Conn): Boolean = when (c.kind) {
        Kind.CDC -> {
            val v = (if (c.dtr) 0x01 else 0) or (if (c.rts) 0x02 else 0)
            c.connection.controlTransfer(0x21, SET_CONTROL_LINE_STATE, v, c.controlInterface?.id ?: 0,
                null, 0, USB_TIMEOUT_MS) >= 0
        }
        Kind.CP210X -> {
            // SET_MHS: bits 0/1 the lines, bits 8/9 which of them this call sets.
            val v = (if (c.dtr) 0x01 else 0) or (if (c.rts) 0x02 else 0) or 0x0300
            vendorOut(c, 0x41, 0x07, v)
        }
        Kind.CH34X -> {
            val v = ((if (c.dtr) 0x20 else 0) or (if (c.rts) 0x40 else 0)).inv() and 0xFF
            vendorOut(c, 0x40, 0xA4, v, 0)
        }
    }

    private fun read(name: String, max: Int, timeoutMs: Int, result: MethodChannel.Result) {
        val c = open[name]
        if (c == null) {
            result.error("NOT_OPEN", "device not open", null)
            return
        }
        executor.execute {
            try {
                val buf = ByteArray(minOf(max, READ_MAX))
                val n = c.connection.bulkTransfer(c.readEndpoint, buf, buf.size, timeoutMs)
                val out = if (n > 0) buf.copyOf(n) else ByteArray(0)
                main.post { result.success(out) }
            } catch (t: Throwable) {
                main.post { result.error("READ_ERROR", t.message, null) }
            }
        }
    }

    private fun write(name: String, data: ByteArray, result: MethodChannel.Result) {
        val c = open[name]
        if (c == null) {
            result.error("NOT_OPEN", "device not open", null)
            return
        }
        executor.execute {
            try {
                var off = 0
                val max = c.writeEndpoint.maxPacketSize
                while (off < data.size) {
                    val n = minOf(max, data.size - off)
                    val chunk = data.copyOfRange(off, off + n)
                    val sent = c.connection.bulkTransfer(c.writeEndpoint, chunk, n, USB_TIMEOUT_MS)
                    if (sent < 0) break
                    off += sent
                }
                val total = off
                main.post { result.success(total) }
            } catch (t: Throwable) {
                main.post { result.error("WRITE_ERROR", t.message, null) }
            }
        }
    }

    private fun closeDevice(name: String) {
        val c = open.remove(name) ?: return
        try {
            c.connection.releaseInterface(c.dataInterface)
            if (c.controlInterface != null && c.controlInterface != c.dataInterface) {
                c.connection.releaseInterface(c.controlInterface)
            }
            c.connection.close()
        } catch (t: Throwable) {
            Log.w(TAG, "close failed: ${t.message}")
        }
    }

    private fun closeAll() {
        for (n in open.keys.toList()) closeDevice(n)
    }

    private fun registerReceiver(context: Context) {
        if (receiver != null) return
        val r = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context?, intent: Intent?) {
                val action = intent?.action ?: return
                val device = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
                    intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
                else @Suppress("DEPRECATION") intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
                when (action) {
                    ACTION_USB_PERMISSION -> {
                        val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                        val name = device?.deviceName ?: return
                        val pending = pendingPermission.remove(name)
                        main.post {
                            pending?.success(granted)
                            channel?.invokeMethod("onPermissionChanged", mapOf("deviceName" to name, "granted" to granted))
                        }
                    }
                    UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                        device?.deviceName?.let { closeDevice(it) }
                        main.post { channel?.invokeMethod("onDevicesChanged", null) }
                    }
                    UsbManager.ACTION_USB_DEVICE_ATTACHED -> {
                        main.post { channel?.invokeMethod("onDevicesChanged", null) }
                    }
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(ACTION_USB_PERMISSION)
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(r, filter, Context.RECEIVER_EXPORTED)
        } else {
            context.registerReceiver(r, filter)
        }
        receiver = r
    }

    private fun unregisterReceiver(context: Context) {
        receiver?.let {
            try { context.unregisterReceiver(it) } catch (_: IllegalArgumentException) {}
        }
        receiver = null
    }
}
