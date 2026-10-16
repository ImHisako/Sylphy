package com.sylphy

import java.util.concurrent.Executors
import android.content.Context

/** Orders native security events independently of the Flutter engine. */
internal object SecurityLifecycle {
    const val CLOSE = 0
    const val BACKGROUND = 1
    const val SCREEN_OFF = 2
    private val worker = Executors.newSingleThreadExecutor { task ->
        Thread(task, "sylphy-security")
    }

    private external fun applyEvent(event: Int): Int

    fun submit(context: Context, event: Int) {
        worker.execute {
            try {
                System.loadLibrary("sylphy_core")
                when (applyEvent(event)) {
                    1 -> MemoryWipeService.start(context.applicationContext)
                    -1 -> MemoryCleanupNotifications.show(context, "Pulizia non completata", false)
                }
            } catch (_: Throwable) {
                MemoryCleanupNotifications.show(context, "Pulizia non completata", false)
            }
        }
    }

    // Startup/resume waits for queued events before opening an account again.
    fun flush(completed: () -> Unit) { worker.execute(completed) }
}
