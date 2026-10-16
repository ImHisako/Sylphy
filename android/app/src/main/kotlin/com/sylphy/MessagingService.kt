package com.sylphy

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

class MessagingService : Service() {
    private external fun syncInbound(): Int
    private external fun waitForInboxEvent(after: Long): Long
    private external fun wakeEventWaiters()
    private lateinit var workerThread: HandlerThread
    private lateinit var worker: Handler
    private lateinit var eventThread: HandlerThread
    private lateinit var eventWorker: Handler
    private var eventSequence = 0L
    @Volatile private var stopped = false
    private val watchEvents = object : Runnable {
        override fun run() {
            if (stopped) return
            try {
                val next = waitForInboxEvent(eventSequence)
                if (next != eventSequence) {
                    eventSequence = next
                    if (!stopped) updatePolling()
                }
            } catch (_: Throwable) {
                // The periodic poll remains available if the watcher fails.
                return
            }
            if (!stopped) eventWorker.post(this)
        }
    }
    private val poll = object : Runnable {
        override fun run() {
            var outcome = 0
            val wake = getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Sylphy:inbox-commit").apply { setReferenceCounted(false) }
            try {
                // Flutter owns foreground polling and knows which chat is visible.
                if (uiResumed || stopped) return
                // Protect only bounded local processing, never the waiting thread.
                wake.acquire(10_000)
                outcome = syncInbound()
                if (outcome > 0 && !uiResumed) showIncomingNotification((outcome and 0x40000000) != 0)
            } catch (error: Throwable) {
                outcome = -1
                AppDiagnostics.w("Sylphy", "Background inbox poll unavailable", error)
            } finally {
                try { if (wake.isHeld) wake.release() } catch (_: RuntimeException) { }
                if (!stopped && !uiResumed) worker.postDelayed(this,
                    BackgroundPollPolicy.delay(NetworkRecovery.available, outcome))
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
            eventThread = HandlerThread("sylphy-inbox-events").apply { start() }
            eventWorker = Handler(eventThread.looper)
            eventWorker.post(watchEvents)
            activeService = this
            NetworkRecovery.start(this)
            updatePolling()
        } catch (error: Throwable) {
            AppDiagnostics.e("Sylphy", "Unable to start native inbox worker", error)
            stopSelf()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int =
        START_NOT_STICKY

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onTaskRemoved(rootIntent: Intent?) {
        SecurityLifecycle.submit(this, SecurityLifecycle.CLOSE)
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        stopped = true
        try { wakeEventWaiters() } catch (_: Throwable) { }
        if (::eventWorker.isInitialized) eventWorker.removeCallbacksAndMessages(null)
        if (::eventThread.isInitialized) eventThread.quitSafely()
        if (!uiResumed) SecurityLifecycle.submit(this, SecurityLifecycle.CLOSE)
        if (activeService === this) activeService = null
        if (::worker.isInitialized) worker.removeCallbacksAndMessages(null)
        if (::workerThread.isInitialized) workerThread.quitSafely()
        super.onDestroy()
    }

    private fun updatePolling() {
        if (!::worker.isInitialized || stopped) return
        // Serialize lifecycle changes with the poll to avoid duplicate loops.
        worker.post {
            worker.removeCallbacks(poll)
            if (!stopped && !uiResumed) worker.post(poll)
        }
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
        @Volatile private var activeService: MessagingService? = null
        @Volatile internal var uiResumed = false
            set(value) {
                if (field == value) return
                field = value
                activeService?.updatePolling()
            }
        const val CHANNEL_ID = "sylphy_background_messaging"
        const val NOTIFICATION_ID = 4104
        const val INCOMING_NOTIFICATION_ID = 4105
        internal fun requestInboxPoll() { activeService?.updatePolling() }
    }
}
