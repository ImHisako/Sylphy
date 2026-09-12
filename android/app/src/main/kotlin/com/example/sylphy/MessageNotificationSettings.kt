package com.example.sylphy

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationManagerCompat

/** Shared by Flutter's activity and the background inbox worker. */
internal object MessageNotificationSettings {
    const val CHANNEL_ID = "sylphy_messages"
    private const val PREFERENCES = "sylphy_notifications"

    fun enabled(context: Context): Boolean = context
        .getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        .getBoolean("messages_enabled", true)

    fun createChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, "Nuovi messaggi", NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Notifiche private per i nuovi messaggi Sylphy"
                enableVibration(true)
            }
            // Reusing the ID preserves all sound/vibration choices made in Android.
            context.getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }
    }

    fun snapshot(context: Context): Map<String, Any?> {
        createChannel(context)
        val channel = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.getSystemService(NotificationManager::class.java)
                .getNotificationChannel(CHANNEL_ID)
        } else null
        return mapOf(
            "enabled" to enabled(context),
            "system_enabled" to NotificationManagerCompat.from(context).areNotificationsEnabled(),
            "channel_enabled" to (channel == null || channel.importance != NotificationManager.IMPORTANCE_NONE),
            "sound_enabled" to channel?.let {
                it.importance >= NotificationManager.IMPORTANCE_DEFAULT && it.sound != null
            },
            "vibration_enabled" to channel?.let {
                it.importance >= NotificationManager.IMPORTANCE_DEFAULT && it.shouldVibrate()
            },
        )
    }

    @Synchronized
    fun setEnabled(context: Context, enabled: Boolean) {
        check(context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            .edit().putBoolean("messages_enabled", enabled).commit()) {
            "Unable to save notification preference"
        }
        if (!enabled) {
            val manager = context.getSystemService(NotificationManager::class.java)
            // Keep the ongoing notification required for background messaging.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                manager.activeNotifications
                    .filter { it.id == MessagingService.INCOMING_NOTIFICATION_ID }
                    .forEach { manager.cancel(it.tag, it.id) }
            }
        }
    }

    @Synchronized
    fun post(context: Context, tag: String?, notification: Notification) {
        if (!enabled(context) || !NotificationManagerCompat.from(context).areNotificationsEnabled()) return
        try {
            NotificationManagerCompat.from(context)
                .notify(tag, MessagingService.INCOMING_NOTIFICATION_ID, notification)
        } catch (_: SecurityException) {
            // The user may revoke POST_NOTIFICATIONS between the check and post.
        }
    }
}
