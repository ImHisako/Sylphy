package com.example.sylphy

import android.content.Context
import android.content.ContextWrapper
import android.Manifest
import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

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
    private var pendingSaveResult: MethodChannel.Result? = null
    private var pendingSaveBytes: ByteArray? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        ensureVeilidInitialized()
        // Veilid needs Android's Context/JVM before Flutter can invoke FFI.
        super.onCreate(savedInstanceState)
        createMessageChannel()
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
                    "requestNotificationPermission" -> {
                        requestNotificationPermission()
                        result.success(true)
                    }
                    "showMessageNotification" -> {
                        showMessageNotification()
                        result.success(true)
                    }
                    "startBackgroundMessaging" -> {
                        try {
                            ContextCompat.startForegroundService(
                                applicationContext,
                                Intent(applicationContext, MessagingService::class.java),
                            )
                            result.success(true)
                        } catch (error: Throwable) {
                            Log.e("Sylphy", "Unable to start background messaging", error)
                            result.error(
                                "background_messaging_unavailable",
                                "Il servizio messaggi in background non è disponibile.",
                                null,
                            )
                        }
                    }
                    "saveFile" -> saveFile(call.arguments, result)
                    else -> result.notImplemented()
                }
            }
    }

    @Suppress("UNCHECKED_CAST")
    private fun saveFile(arguments: Any?, result: MethodChannel.Result) {
        if (pendingSaveResult != null) {
            result.error("save_in_progress", "Un salvataggio è già in corso.", null)
            return
        }
        val values = arguments as? Map<String, Any?>
        val fileName = values?.get("fileName") as? String
        val bytes = values?.get("bytes") as? ByteArray
        if (fileName.isNullOrBlank() || bytes == null || bytes.isEmpty()) {
            result.error("invalid_file", "File non valido.", null)
            return
        }
        pendingSaveResult = result
        pendingSaveBytes = bytes
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/octet-stream"
            putExtra(Intent.EXTRA_TITLE, fileName)
        }
        startActivityForResult(intent, SAVE_FILE_REQUEST)
    }

    @Deprecated("Deprecated in Android; required by FlutterActivity compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != SAVE_FILE_REQUEST) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingSaveResult
        val bytes = pendingSaveBytes
        pendingSaveResult = null
        pendingSaveBytes = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result?.success(null)
            return
        }
        val destination = data.data!!
        try {
            contentResolver.openOutputStream(destination, "w").use { output ->
                requireNotNull(output).write(requireNotNull(bytes))
            }
            result?.success(destination.toString())
        } catch (error: Throwable) {
            result?.error("save_failed", "Impossibile salvare il file.", null)
        }
    }

    private fun createMessageChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                MESSAGE_CHANNEL_ID,
                "Nuovi messaggi",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Notifiche private per i nuovi messaggi Sylphy"
                enableVibration(true)
            }
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                NOTIFICATION_PERMISSION_REQUEST,
            )
        }
    }

    private fun showMessageNotification() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(this, MESSAGE_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Nuovo messaggio")
            .setContentText("Hai ricevuto un nuovo messaggio su Sylphy")
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .build()
        NotificationManagerCompat.from(this)
            .notify((System.currentTimeMillis() and 0x7fffffff).toInt(), notification)
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
        const val MESSAGE_CHANNEL_ID = "sylphy_messages"
        const val NOTIFICATION_PERMISSION_REQUEST = 4102
        const val SAVE_FILE_REQUEST = 4103
        val REQUIRED_PROTECTED_STORE_CLASSES = listOf(
            "androidx.security.crypto.MasterKey",
            "androidx.security.crypto.MasterKey\$Builder",
            "androidx.security.crypto.EncryptedSharedPreferences",
        )
    }
}
