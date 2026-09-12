package dev.akihana.akihana_miao

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.PowerManager
import android.os.IBinder
import android.net.wifi.WifiManager
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * 后台保活前台服务（避坑清单 #5：日志统一 Log.i）。
 *
 * 只做「保活壳」：抬升整个进程优先级，让 Dart 侧的 PTP 链路、
 * 自动拉取 Timer、上传队列在退后台/锁屏/Doze 下继续运行。
 * 业务逻辑不进服务——多端（iOS/鸿蒙）只需替换这个壳。
 *
 * - dataSync 类型（Android 14+ 必须声明）；Android 15 有 6 小时上限，
 *   onTimeout 里重启续期
 * - PARTIAL_WAKE_LOCK + WIFI_MODE_FULL_HIGH_PERF：锁屏后 CPU/WiFi 不休眠
 * - 通知常显：提醒用户服务是否正在进行；点击回 App
 */
class KeepAliveService : Service() {
    companion object {
        const val TAG = "KeepAlive"
        const val CHANNEL_ID = "keepalive"
        const val NOTIF_ID = 1001

        @Volatile
        var running = false
            private set

        /** 启动/更新通知文案（幂等；未运行则启动，运行中仅刷新通知） */
        fun start(context: Context, text: String) {
            val intent = Intent(context, KeepAliveService::class.java)
                .putExtra("text", text)
            try {
                context.startForegroundService(intent)
            } catch (e: Exception) {
                // 从后台启动受 Android 12+ 限制；前台触发路径不受影响
                Log.i(TAG, "startForegroundService 失败: ${e.message}")
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, KeepAliveService::class.java))
        }

        private fun buildNotification(context: Context, text: String): Notification {
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
            val pi = PendingIntent.getActivity(
                context, 0, launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            return NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_menu_camera)
                .setContentTitle("Akihana Miao")
                .setContentText(text)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setContentIntent(pi)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .build()
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onCreate() {
        super.onCreate()
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID, "后台运行", NotificationManager.IMPORTANCE_LOW,
            ).apply { description = "相机连接与上传的后台保活" },
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra("text") ?: "后台运行中"
        val notification = buildNotification(this, text)
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(
                NOTIF_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIF_ID, notification)
        }
        acquireLocks()
        running = true
        return START_STICKY
    }

    /** Android 15 dataSync 6 小时上限：重启续期（保活场景合法且必要） */
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.i(TAG, "FGS 超时($fgsType)，重启续期")
        if (Build.VERSION.SDK_INT >= 35) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        }
        start(this, "相机已连接 · 拍摄后自动拉取")
    }

    private fun acquireLocks() {
        try {
            if (wakeLock?.isHeld != true) {
                wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "akihana:keepalive")
                    .apply { acquire(8 * 3600 * 1000L) } // 8h 上限，onTimeout 重启时续
            }
        } catch (e: Exception) {
            Log.i(TAG, "WakeLock 获取失败: ${e.message}")
        }
        try {
            if (wifiLock?.isHeld != true) {
                // 锁模式只能用单一位：API 29+ 用 LOW_LATENCY（已隐含高性能），
                // OR 组合多个模式会抛 IllegalArgumentException(lockMode =7) 导致闪退
                val mode = if (Build.VERSION.SDK_INT >= 29) {
                    WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                } else {
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF
                }
                wifiLock = (applicationContext
                    .getSystemService(WIFI_SERVICE) as WifiManager)
                    .createWifiLock(mode, "akihana:wifi")
                    .apply { acquire() }
            }
        } catch (e: Exception) {
            Log.i(TAG, "WifiLock 获取失败: ${e.message}")
        }
    }

    private fun releaseLocks() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Exception) {}
        try {
            if (wifiLock?.isHeld == true) wifiLock?.release()
        } catch (_: Exception) {}
    }

    override fun onDestroy() {
        running = false
        releaseLocks()
        Log.i(TAG, "服务已停止")
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
