package com.example.sylphy

import android.content.Context
import android.content.ContextWrapper
import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterActivity

internal fun veilidBinaryClassName(name: String): String = name.replace('/', '.')

private class VeilidClassLoader(delegate: ClassLoader) : ClassLoader(delegate) {
    override fun loadClass(name: String, resolve: Boolean): Class<*> =
        super.loadClass(veilidBinaryClassName(name), resolve)
}

private class VeilidAndroidContext(base: Context) : ContextWrapper(base) {
    private val veilidClassLoader = VeilidClassLoader(base.classLoader)

    override fun getClassLoader(): ClassLoader = veilidClassLoader
}

class MainActivity : FlutterActivity() {
    private external fun initializeVeilid(context: Context)

    override fun onCreate(savedInstanceState: Bundle?) {
        try {
            System.loadLibrary("sylphy_core")
            // keyring-manager 0.8.3 asks Context.getClassLoader() to load JNI
            // internal names (with '/'). Android ClassLoader accepts binary
            // names (with '.'), so normalize them at this narrow boundary.
            initializeVeilid(VeilidAndroidContext(applicationContext))
        } catch (error: Throwable) {
            Log.e("Sylphy", "Native Veilid initialization failed", error)
        }
        // Veilid needs Android's Context/JVM before Flutter can invoke FFI.
        super.onCreate(savedInstanceState)
    }
}
