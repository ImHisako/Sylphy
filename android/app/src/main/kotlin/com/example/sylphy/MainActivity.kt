package com.example.sylphy

import android.content.Context
import android.content.ContextWrapper
import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

internal fun veilidBinaryClassName(name: String): String = name.replace('/', '.')

private class VeilidClassLoader(delegate: ClassLoader) : ClassLoader(delegate) {
    override fun loadClass(name: String, resolve: Boolean): Class<*> =
        super.loadClass(veilidBinaryClassName(name), resolve)
}

private class VeilidAndroidContext(base: Context) : ContextWrapper(base) {
    private val veilidClassLoader = VeilidClassLoader(base.classLoader)

    override fun getClassLoader(): ClassLoader = veilidClassLoader

    // Keep the adapted ClassLoader when AndroidX asks for the application
    // context while creating EncryptedSharedPreferences.
    override fun getApplicationContext(): Context = this
}

class MainActivity : FlutterActivity() {
    private external fun initializeVeilid(context: Context)
    private var nativeLibraryLoaded = false
    private var veilidBootstrapReady = false
    private var veilidBootstrapCode = "not_started"

    override fun onCreate(savedInstanceState: Bundle?) {
        ensureVeilidInitialized()
        // Veilid needs Android's Context/JVM before Flutter can invoke FFI.
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PLATFORM_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "ensureVeilidInitialized" -> {
                        ensureVeilidInitialized()
                        result.success(
                            mapOf(
                                "ready" to veilidBootstrapReady,
                                "code" to veilidBootstrapCode,
                            ),
                        )
                    }
                    else -> result.notImplemented()
                }
            }
    }

    @Synchronized
    private fun ensureVeilidInitialized() {
        if (veilidBootstrapReady) {
            return
        }
        try {
            if (!nativeLibraryLoaded) {
                System.loadLibrary("sylphy_core")
                nativeLibraryLoaded = true
            }
            val context = VeilidAndroidContext(applicationContext)
            REQUIRED_PROTECTED_STORE_CLASSES.forEach(context.classLoader::loadClass)
            // keyring-manager 0.8.3 asks Context.getClassLoader() to load JNI
            // internal names (with '/'). Android ClassLoader accepts binary
            // names (with '.'), so normalize them at this narrow boundary.
            initializeVeilid(context)
            veilidBootstrapReady = true
            veilidBootstrapCode = "ready"
            Log.i("Sylphy", "Native Veilid platform bootstrap ready")
        } catch (error: ClassNotFoundException) {
            veilidBootstrapReady = false
            veilidBootstrapCode = "android_dependency_missing"
            Log.e("Sylphy", "Veilid protected-store dependency missing", error)
        } catch (error: UnsatisfiedLinkError) {
            veilidBootstrapReady = false
            veilidBootstrapCode = "native_library_missing"
            Log.e("Sylphy", "Sylphy native library unavailable", error)
        } catch (error: Throwable) {
            veilidBootstrapReady = false
            veilidBootstrapCode = "jni_initialization_failed"
            Log.e("Sylphy", "Native Veilid initialization failed", error)
        }
    }

    private companion object {
        const val PLATFORM_CHANNEL = "sylphy/platform"
        val REQUIRED_PROTECTED_STORE_CLASSES = listOf(
            "androidx.security.crypto.MasterKey",
            "androidx.security.crypto.MasterKey\$Builder",
            "androidx.security.crypto.EncryptedSharedPreferences",
        )
    }
}
