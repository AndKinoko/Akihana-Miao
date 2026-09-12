package dev.akihana.akihana_miao

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * USB Host 通道（避坑清单 #5：日志统一 Log.i，ColorOS 会吞 Log.d）。
 *
 * 方法：
 *   listDevices        -> [{name, vendorId, productId, hasPermission}]
 *   requestPermission  -> bool（阻塞等待用户授权）
 *   open               -> {productName}（声明 Still Image 接口 class=6）
 *   bulkWrite          -> 写入字节数
 *   bulkRead(length)   -> Uint8List（内部循环读满或设备短包结束）
 *   interruptRead      -> 事件字节（超时返回 null）
 *   close              -> 释放接口与连接
 */
class UsbHostChannel(private val context: Context, engine: FlutterEngine) {
    companion object {
        const val CHANNEL = "dev.akihana/usb_host"
        const val ACTION_PERMISSION = "dev.akihana.USB_PERMISSION"
        const val TAG = "UsbHost"
    }

    private val usbManager = context.getSystemService(Context.USB_SERVICE) as UsbManager
    private var connection: android.hardware.usb.UsbDeviceConnection? = null
    private var claimedInterface: UsbInterface? = null
    private var bulkOut: android.hardware.usb.UsbEndpoint? = null
    private var bulkIn: android.hardware.usb.UsbEndpoint? = null
    private var interruptIn: android.hardware.usb.UsbEndpoint? = null

    // interrupt 线程持续把事件推入队列，供 interruptRead 取用
    private var eventThread: Thread? = null
    private val eventQueue = ArrayBlockingQueue<ByteArray>(64)
    @Volatile private var running = false

    init {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "listDevices" -> result.success(listDevices())
                    "bindWifi" -> result.success(bindWifi())
                    "unbindNetwork" -> result.success(unbindNetwork())
                    "isOnWifi" -> result.success(isOnWifi())
                    "saveToGallery" -> {
                        val path = call.argument<String>("path")!!
                        val fileName = call.argument<String>("fileName")!!
                        val subFolder = call.argument<String>("subFolder")
                        result.success(saveToGallery(path, fileName, subFolder))
                    }
                    "queryGallery" -> result.success(queryGallery())
                    "startKeepAlive" -> {
                        val text = call.argument<String>("text") ?: "后台运行中"
                        KeepAliveService.start(context, text)
                        result.success(true)
                    }
                    "stopKeepAlive" -> {
                        KeepAliveService.stop(context)
                        result.success(true)
                    }
                    "isKeepAliveRunning" -> result.success(KeepAliveService.running)
                    "getBattery" -> result.success(batteryInfo())
                    "requestPermission" -> {
                        val name = call.argument<String>("device")!!
                        result.success(requestPermission(name))
                    }
                    "open" -> {
                        val name = call.argument<String>("device")!!
                        result.success(open(name))
                    }
                    "bulkWrite" -> {
                        val data = call.argument<ByteArray>("data")!!
                        result.success(bulkWrite(data))
                    }
                    "bulkRead" -> {
                        val length = call.argument<Int>("length")!!
                        val timeout = call.argument<Int>("timeout") ?: 30000
                        result.success(bulkRead(length, timeout))
                    }
                    "interruptRead" -> {
                        val timeout = call.argument<Int>("timeout") ?: 1000
                        result.success(interruptRead(timeout))
                    }
                    "close" -> {
                        close()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                Log.i(TAG, "USB 通道异常: ${e.javaClass.simpleName}: ${e.message}")
                result.error("USB_ERROR", e.message, null)
            }
        }
    }

    private fun listDevices(): List<Map<String, Any>> =
        usbManager.deviceList.values.map { d ->
            mapOf(
                "name" to d.deviceName,
                "vendorId" to d.vendorId,
                "productId" to d.productId,
                "productName" to (d.productName ?: ""),
                "hasPermission" to usbManager.hasPermission(d),
            )
        }

    /** 把进程默认网络绑定到 WiFi：防止 ColorOS 把相机热点(192.168.1.x)流量路由到蜂窝/VPN */
    private fun bindWifi(): Boolean {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE)
                as android.net.ConnectivityManager
        for (n in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(n) ?: continue
            if (caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI)) {
                val ok = cm.bindProcessToNetwork(n)
                Log.i(TAG, "bindProcessToNetwork wifi=$n ok=$ok")
                return ok
            }
        }
        Log.i(TAG, "bindWifi 失败：没有可用的 WiFi 网络")
        return false
    }

    /** 解除绑定，恢复默认网络路由（上传等走蜂窝时用） */
    private fun unbindNetwork(): Boolean =
        context.getSystemService(Context.CONNECTIVITY_SERVICE)
            .let { it as android.net.ConnectivityManager }
            .let { it.bindProcessToNetwork(null) }

    /** 当前是否有可上网的 WiFi（相机热点不算：无互联网） */
    private fun isOnWifi(): Boolean {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE)
                as android.net.ConnectivityManager
        val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return false
        return caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) &&
                caps.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_VALIDATED)
    }

    /**
     * 把本地文件存入系统相册/下载目录（MediaStore，用户可见）。
     * 图片 → Pictures/AkihanaMiao，视频 → Movies/AkihanaMiao，其他(RAW等) → Download/AkihanaMiao。
     * 返回 MediaStore uri；失败返回 null。仅支持 API 29+。
     */
    private fun saveToGallery(srcPath: String, fileName: String, subFolder: String?): String? {
        if (Build.VERSION.SDK_INT < 29) return null
        val src = java.io.File(srcPath)
        if (!src.exists()) return null
        val ext = fileName.substringAfterLast('.', "").lowercase()
        val mime = when (ext) {
            "jpg", "jpeg" -> "image/jpeg"
            "png" -> "image/png"
            "mov" -> "video/quicktime"
            "mp4" -> "video/mp4"
            else -> "application/octet-stream"
        }
        // 日期子目录（相册按拍摄日期分文件夹）；仅接受安全的单段目录名
        val datePart = if (subFolder != null && subFolder.matches(Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}"))) "/$subFolder" else ""
        val (collection, relPath) = when {
            mime.startsWith("image/") -> Pair(
                android.provider.MediaStore.Images.Media.getContentUri(
                    android.provider.MediaStore.VOLUME_EXTERNAL_PRIMARY),
                "Pictures/AkihanaMiao$datePart")
            mime.startsWith("video/") -> Pair(
                android.provider.MediaStore.Video.Media.getContentUri(
                    android.provider.MediaStore.VOLUME_EXTERNAL_PRIMARY),
                "Movies/AkihanaMiao$datePart")
            else -> Pair(
                android.provider.MediaStore.Downloads.getContentUri(
                    android.provider.MediaStore.VOLUME_EXTERNAL_PRIMARY),
                "Download/AkihanaMiao$datePart")
        }
        return try {
            // 同名同目录已存在则复用该行（覆盖内容），避免 MediaStore 重复媒体
            val existing = context.contentResolver.query(
                collection,
                arrayOf(android.provider.MediaStore.MediaColumns._ID),
                "${android.provider.MediaStore.MediaColumns.DISPLAY_NAME}=? AND " +
                    "${android.provider.MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?",
                arrayOf(fileName, "$relPath%"),
                null,
            )?.use { c -> if (c.moveToFirst()) c.getLong(0) else null }
            if (existing != null) {
                val uri = android.content.ContentUris.withAppendedId(collection, existing)
                // "w" 截断写入（"wt" 在部分机型不受支持导致静默失败）
                context.contentResolver.openOutputStream(uri, "w")?.use { out ->
                    src.inputStream().use { it.copyTo(out) }
                } ?: return null
                Log.i(TAG, "覆盖相册同名文件: $relPath/$fileName")
                return uri.toString()
            }
            val values = android.content.ContentValues().apply {
                put(android.provider.MediaStore.MediaColumns.DISPLAY_NAME, fileName)
                put(android.provider.MediaStore.MediaColumns.MIME_TYPE, mime)
                put(android.provider.MediaStore.MediaColumns.RELATIVE_PATH, relPath)
            }
            val uri = context.contentResolver.insert(collection, values) ?: return null
            context.contentResolver.openOutputStream(uri)?.use { out ->
                src.inputStream().use { it.copyTo(out) }
            } ?: return null
            Log.i(TAG, "已存入相册: $relPath/$fileName")
            uri.toString()
        } catch (e: Exception) {
            Log.i(TAG, "存相册失败: ${e.message}")
            null
        }
    }

    /** 手机电池/充电状态（条件保护 gate：仅充电时上传 / 低电量暂停） */
    private fun batteryInfo(): Map<String, Any> {
        return try {
            val i = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            val level = i?.getIntExtra(android.os.BatteryManager.EXTRA_LEVEL, -1) ?: -1
            val scale = i?.getIntExtra(android.os.BatteryManager.EXTRA_SCALE, -1) ?: -1
            val status = i?.getIntExtra(android.os.BatteryManager.EXTRA_STATUS, -1) ?: -1
            val pct = if (level >= 0 && scale > 0) (level * 100 / scale) else -1
            mapOf(
                "level" to pct,
                "charging" to (status == android.os.BatteryManager.BATTERY_STATUS_CHARGING ||
                    status == android.os.BatteryManager.BATTERY_STATUS_FULL),
            )
        } catch (e: Exception) {
            Log.i(TAG, "batteryInfo 失败: ${e.message}")
            mapOf("level" to -1, "charging" to false)
        }
    }

    /**
     * 查询本应用存入系统相册/下载目录的媒体文件（AkihanaMiao 专属目录）。
     * 应用查询自己贡献的媒体无需存储权限；DATA 列为可直接读的绝对路径。
     */
    private fun queryGallery(): List<Map<String, String>> {
        if (Build.VERSION.SDK_INT < 29) return emptyList()
        val dirs = listOf(
            "Pictures/AkihanaMiao",
            "Movies/AkihanaMiao",
            "Download/AkihanaMiao",
        )
        val out = mutableListOf<Map<String, String>>()
        val collections = listOf(
            android.provider.MediaStore.Images.Media.getContentUri(
                android.provider.MediaStore.VOLUME_EXTERNAL_PRIMARY),
            android.provider.MediaStore.Video.Media.getContentUri(
                android.provider.MediaStore.VOLUME_EXTERNAL_PRIMARY),
            android.provider.MediaStore.Downloads.getContentUri(
                android.provider.MediaStore.VOLUME_EXTERNAL_PRIMARY),
        )
        for (c in collections) {
            try {
                context.contentResolver.query(
                    c,
                    arrayOf(
                        android.provider.MediaStore.MediaColumns.DISPLAY_NAME,
                        android.provider.MediaStore.MediaColumns.RELATIVE_PATH,
                        android.provider.MediaStore.MediaColumns.DATA,
                        android.provider.MediaStore.MediaColumns.SIZE,
                        android.provider.MediaStore.MediaColumns.DATE_MODIFIED,
                    ),
                    null, null, null,
                )?.use { cursor ->
                    while (cursor.moveToNext()) {
                        val rel = cursor.getString(1) ?: continue
                        if (dirs.none { rel.startsWith(it) }) continue
                        out.add(
                            mapOf(
                                "name" to (cursor.getString(0) ?: ""),
                                "path" to (cursor.getString(2) ?: ""),
                                "size" to (cursor.getLong(3)).toString(),
                                "dateModified" to (cursor.getLong(4)).toString(),
                            )
                        )
                    }
                }
            } catch (e: Exception) {
                Log.i(TAG, "queryGallery 查询失败: ${e.message}")
            }
        }
        return out
    }

    private fun deviceByName(name: String): UsbDevice =
        usbManager.deviceList[name] ?: throw IllegalStateException("设备不存在: $name")

    /** 请求授权；阻塞最多 30s 等待用户确认 */
    @SuppressLint("UnspecifiedRegisterFlagDetector")
    private fun requestPermission(name: String): Boolean {
        val device = deviceByName(name)
        if (usbManager.hasPermission(device)) return true
        val granted = ArrayBlockingQueue<Boolean>(1)
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, intent: Intent) {
                granted.offer(
                    intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                )
            }
        }
        if (Build.VERSION.SDK_INT >= 33) {
            context.registerReceiver(receiver, IntentFilter(ACTION_PERMISSION), Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(receiver, IntentFilter(ACTION_PERMISSION))
        }
        try {
            val flags = if (Build.VERSION.SDK_INT >= 31)
                PendingIntent.FLAG_MUTABLE else 0
            val pi = PendingIntent.getBroadcast(
                context, 0, Intent(ACTION_PERMISSION).setPackage(context.packageName), flags
            )
            usbManager.requestPermission(device, pi)
            return granted.poll(30, TimeUnit.SECONDS) ?: false
        } finally {
            context.unregisterReceiver(receiver)
        }
    }

    /** 打开设备并声明 Still Image 接口（class=6），解析三类端点 */
    private fun open(name: String): Map<String, Any> {
        val device = deviceByName(name)
        val conn = usbManager.openDevice(device)
            ?: throw IllegalStateException("无法打开设备（未授权？）")
        var siInterface: UsbInterface? = null
        for (i in 0 until device.interfaceCount) {
            val itf = device.getInterface(i)
            if (itf.interfaceClass == UsbConstants.USB_CLASS_STILL_IMAGE) {
                siInterface = itf
                break
            }
        }
        val itf = siInterface
            ?: throw IllegalStateException("设备无 Still Image 接口（相机 USB 模式请设为 PTP/MTP）")
        if (!conn.claimInterface(itf, true)) {
            conn.close()
            throw IllegalStateException("无法声明 USB 接口")
        }
        for (i in 0 until itf.endpointCount) {
            val ep = itf.getEndpoint(i)
            when (ep.type) {
                UsbConstants.USB_ENDPOINT_XFER_BULK ->
                    if (ep.direction == UsbConstants.USB_DIR_OUT) bulkOut = ep
                    else bulkIn = ep
                UsbConstants.USB_ENDPOINT_XFER_INT ->
                    if (ep.direction == UsbConstants.USB_DIR_IN) interruptIn = ep
            }
        }
        connection = conn
        claimedInterface = itf
        startEventThread()
        Log.i(TAG, "USB 已连接: ${device.deviceName} bulkOut=${bulkOut != null} bulkIn=${bulkIn != null}")
        return mapOf("productName" to (device.productName ?: device.deviceName))
    }

    private fun checkOpen() {
        if (connection == null) throw IllegalStateException("USB 未打开")
        if (bulkOut == null || bulkIn == null) throw IllegalStateException("缺少 bulk 端点")
    }

    private fun bulkWrite(data: ByteArray): Int {
        checkOpen()
        var sent = 0
        while (sent < data.size) {
            val n = connection!!.bulkTransfer(
                bulkOut, data, sent, minOf(16384, data.size - sent), 10000
            )
            if (n < 0) throw IllegalStateException("bulkWrite 失败 @ $sent")
            sent += n
        }
        return sent
    }

    /** 循环读满 length 字节；设备短包（提前结束）则返回已读部分 */
    private fun bulkRead(length: Int, timeoutMs: Int): ByteArray {
        checkOpen()
        val out = ByteArray(length)
        var got = 0
        while (got < length) {
            val want = minOf(16384, length - got)
            val n = connection!!.bulkTransfer(bulkIn, out, got, want, timeoutMs)
            if (n < 0) {
                if (got == 0) throw IllegalStateException("bulkRead 失败（超时/断开）")
                break // 部分返回
            }
            if (n < want) {
                got += n
                break // 短包 = 本次传输结束
            }
            got += n
        }
        // ZLP 处理：PTP 数据容器总长恰为端点 maxPacket(512) 整数倍时，
        // 相机会追加零长度包；残留的 ZLP 会污染下一事务的读取。
        // 读满且长度对齐时用短超时吸收一次可能的 ZLP。
        if (got == length && length % 512 == 0) {
            val zlp = ByteArray(512)
            connection!!.bulkTransfer(bulkIn, zlp, zlp.size, 50)
        }
        return out.copyOf(got)
    }

    private fun startEventThread() {
        val ep = interruptIn ?: return
        running = true
        eventThread = Thread {
            val buf = ByteArray(64)
            while (running) {
                val n = connection?.bulkTransfer(ep, buf, buf.size, 200) ?: break
                if (n > 0) {
                    eventQueue.offer(buf.copyOf(n))
                }
            }
        }.apply { isDaemon = true; name = "ptp-event"; start() }
    }

    private fun interruptRead(timeoutMs: Int): ByteArray? =
        eventQueue.poll(timeoutMs.toLong(), TimeUnit.MILLISECONDS)

    private fun close() {
        running = false
        eventThread = null
        try { claimedInterface?.let { connection?.releaseInterface(it) } } catch (_: Exception) {}
        try { connection?.close() } catch (_: Exception) {}
        connection = null
        claimedInterface = null
        bulkOut = null
        bulkIn = null
        interruptIn = null
        Log.i(TAG, "USB 已断开")
    }
}
