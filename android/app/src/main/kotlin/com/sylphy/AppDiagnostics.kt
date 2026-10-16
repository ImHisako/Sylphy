package com.sylphy

/** Native application diagnostics follow the explicit Flutter preference. */
internal object AppDiagnostics {
    @Volatile var enabled = false
    fun i(tag: String, message: String) { if (enabled) android.util.Log.i(tag, message) }
    fun w(tag: String, message: String, error: Throwable? = null) {
        if (enabled) android.util.Log.w(tag, message, error)
    }
    fun e(tag: String, message: String, error: Throwable? = null) {
        if (enabled) android.util.Log.e(tag, message, error)
    }
}
