package com.sylphy

import java.util.concurrent.Executors

/** Orders native security events independently of the Flutter engine. */
internal object SecurityLifecycle {
    const val CLOSE = 0
    const val BACKGROUND = 1
    const val SCREEN_OFF = 2
    private val worker = Executors.newSingleThreadExecutor { task ->
        Thread(task, "sylphy-security")
    }

    private external fun applyEvent(event: Int): Boolean

    fun submit(event: Int) {
        worker.execute {
            try {
                System.loadLibrary("sylphy_core")
                if (!applyEvent(event)) android.util.Log.w("Sylphy", "Native memory cleanup unavailable")
            } catch (_: Throwable) {
                android.util.Log.w("Sylphy", "Native memory cleanup unavailable")
            }
        }
    }

    // Startup/resume waits for queued events before opening an account again.
    fun flush(completed: () -> Unit) { worker.execute(completed) }
}
