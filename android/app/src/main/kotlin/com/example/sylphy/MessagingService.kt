package com.example.sylphy

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat

class MessagingService : Service() {
    private external fun syncInbound(): Int
    private lateinit var workerThread: HandlerThread
    private lateinit var worker: Handler
    @Volatile private var stopped = false
    private val poll = object : Runnable {
        override fun run() {
            try {
                // Flutter owns foreground polling and knows which chat is visible.
                if (uiResumed) return
                val received = syncInbound()
                if (received > 0 && !uiResumed) showIncomingNotification((received and 0x40000000) != 0)
            } catch (error: Throwable) {
                Log.w("Sylphy", "Background inbox poll unavailable", error)
            } finally {
                if (!stopped) worker.postDelayed(this, POLL_INTERVAL_MS)
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Messaggistica in background",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Mantiene disponibile la mailbox privata Sylphy"
                setShowBadge(false)
            }
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }
        MessageNotificationSettings.createChannel(this)
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.sylphy_notification)
            .setContentTitle("Sylphy è attivo")
            .setContentText("Ricezione privata dei messaggi in background")
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setOngoing(true)
            .setContentIntent(pendingIntent)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .build()
        startForeground(NOTIFICATION_ID, notification)
        try {
            System.loadLibrary("sylphy_core")
            workerThread = HandlerThread("sylphy-inbox").apply { start() }
            worker = Handler(workerThread.looper)
            worker.post(poll)
        } catch (error: Throwable) {
            Log.e("Sylphy", "Unable to start native inbox worker", error)
            stopSelf()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int =
        START_NOT_STICKY

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        stopped = true
        if (::worker.isInitialized) worker.removeCallbacksAndMessages(null)
        if (::workerThread.isInitialized) workerThread.quitSafely()
        super.onDestroy()
    }

    private fun showIncomingNotification(pinned: Boolean = false) {
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            1,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(this, MessageNotificationSettings.CHANNEL_ID)
            .setDefaults(android.app.Notification.DEFAULT_SOUND or android.app.Notification.DEFAULT_VIBRATE)
            .setSmallIcon(R.drawable.sylphy_notification)
            .setContentTitle(if (pinned) "Messaggio fissato" else "Nuovo messaggio")
            .setContentText(if (pinned) "Un messaggio è stato fissato in un gruppo Sylphy" else "Apri Sylphy per leggerlo")
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .build()
        MessageNotificationSettings.post(this, null, notification)
    }

    companion object {
        @Volatile internal var uiResumed = false
        const val CHANNEL_ID = "sylphy_background_messaging"
        const val NOTIFICATION_ID = 4104
        const val INCOMING_NOTIFICATION_ID = 4105
        const val POLL_INTERVAL_MS = 10_000L
    }
}
