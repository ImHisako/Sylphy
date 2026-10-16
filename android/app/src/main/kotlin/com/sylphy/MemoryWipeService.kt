package com.sylphy

import android.app.ActivityManager
import android.app.Application
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.Process
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import java.nio.ByteBuffer

internal object MemoryCleanupNotifications {
    const val ID = 4213
    private const val CHANNEL = "sylphy-memory-cleanup"
    fun notification(context: Context, text: String, running: Boolean, progress: Int? = null): Notification {
        val manager = context.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Pulizia della memoria", NotificationManager.IMPORTANCE_LOW)
                .apply { setShowBadge(false) }
        )
        return NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.sylphy_notification)
            .setContentTitle("Sylphy · Pulizia RAM")
            .setContentText(text)
            .setOngoing(running).setOnlyAlertOnce(true).setShowWhen(false)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setProgress(if (running) 100 else 0, progress ?: 0, running && progress == null)
            .setTimeoutAfter(if (running) 0L else 15_000L)
            .build()
    }
    fun show(context: Context, text: String, running: Boolean, progress: Int? = null) {
        try {
            context.getSystemService(NotificationManager::class.java)
                .notify(ID, notification(context, text, running, progress))
        } catch (_: RuntimeException) { /* Permission does not gate cleanup. */ }
    }
}

/** Free-page sweep in an expendable process, after the main core has revoked access.
 * Inspired by Molly's WipeMemoryService: held chunks, touched pages, 2x OS reserve,
 * low-memory cancellation and progress. A time budget bounds the pass on mobile.
 */
class MemoryWipeService : Service() {
    companion object {
        fun start(context: Context) {
            try {
                ContextCompat.startForegroundService(context, Intent(context, MemoryWipeService::class.java))
            } catch (_: RuntimeException) {
                MemoryCleanupNotifications.show(context, "Buffer ripuliti · passaggio RAM non avviato", false)
            }
        }
    }
    @Volatile private var cancelled = false
    private var running = false
    private var foregroundReady = false
    private var wakeLock: PowerManager.WakeLock? = null
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onCreate() {
        super.onCreate()
        try {
            startForeground(MemoryCleanupNotifications.ID,
                MemoryCleanupNotifications.notification(this, "Pulizia della memoria in corso…", true))
            foregroundReady = true
        } catch (_: RuntimeException) { stopSelf() }
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!foregroundReady || running) return START_NOT_STICKY
        running = true
        Thread({ sweep() }, "sylphy-free-pages").start()
        return START_NOT_STICKY
    }
    private fun sweep() {
        val manager = getSystemService(ActivityManager::class.java)
        val info = ActivityManager.MemoryInfo()
        fun available(): Long {
            manager.getMemoryInfo(info)
            return (info.availMem - 2 * info.threshold).coerceAtLeast(0)
        }
        val chunks = ArrayList<ByteBuffer>()
        var overwritten = 0L
        var interrupted = false
        val deadline = SystemClock.elapsedRealtime() + 20_000
        try {
            Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
            wakeLock = getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Sylphy:RAMCleanup")
                .apply { acquire(30_000) }
            val budget = available()
            var lastNotification = 0L
            val zeroPage = ByteArray(4096)
            sweep@ while (overwritten < budget) {
                if (cancelled || SystemClock.elapsedRealtime() >= deadline) { interrupted = true; break }
                val remaining = available()
                if (remaining < 4096 || info.lowMemory) break
                val size = minOf(4L * 1024 * 1024, remaining, budget - overwritten).toInt()
                val chunk = ByteBuffer.allocateDirect(size)
                chunks.add(chunk) // Hold every chunk until the process is discarded.
                // Explicitly overwrite every byte, also covering larger OS pages.
                while (chunk.hasRemaining()) {
                    if (cancelled || SystemClock.elapsedRealtime() >= deadline) {
                        interrupted = true
                        break@sweep
                    }
                    val count = minOf(zeroPage.size, chunk.remaining())
                    chunk.put(zeroPage, 0, count)
                    overwritten += count
                }
                val now = SystemClock.elapsedRealtime()
                if (now - lastNotification >= 250) {
                    lastNotification = now
                    val progress = (overwritten * 100 / budget.coerceAtLeast(1)).coerceAtMost(99).toInt()
                    MemoryCleanupNotifications.show(this, "Passaggio sulle pagine libere · $progress%", true, progress)
                }
            }
        } catch (_: OutOfMemoryError) { interrupted = true
        } catch (_: RuntimeException) { interrupted = true
        } finally {
            val message = (if (interrupted) "Passaggio RAM interrotto" else "Passaggio RAM terminato") +
                " · ${overwritten / (1024 * 1024)} MiB trattati"
            Handler(Looper.getMainLooper()).post {
                if (wakeLock?.isHeld == true) wakeLock?.release()
                stopForeground(STOP_FOREGROUND_REMOVE)
                MemoryCleanupNotifications.show(this, message, false)
                stopSelf()
            }
        }
    }
    override fun onTrimMemory(level: Int) {
        if (level >= TRIM_MEMORY_RUNNING_CRITICAL) cancelled = true
        super.onTrimMemory(level)
    }
    override fun onLowMemory() { cancelled = true; super.onLowMemory() }
    override fun onDestroy() {
        cancelled = true
        if (wakeLock?.isHeld == true) wakeLock?.release()
        super.onDestroy()
        val processName = if (Build.VERSION.SDK_INT >= 28) Application.getProcessName() else
            getSystemService(ActivityManager::class.java).runningAppProcesses
                ?.firstOrNull { it.pid == Process.myPid() }?.processName
        // Never terminate the messenger or its foreground reception service.
        if (processName == "$packageName:ram_wiper") Process.killProcess(Process.myPid())
    }
}
