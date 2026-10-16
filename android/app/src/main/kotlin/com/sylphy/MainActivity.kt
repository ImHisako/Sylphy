package com.sylphy

import android.content.Context
import android.content.ContextWrapper
import android.content.BroadcastReceiver
import android.content.IntentFilter
import android.Manifest
import android.app.Activity
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.net.Uri
import android.provider.Settings
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
    private var apkUpdates: ApkUpdateHandler? = null
    private var securityChannel: MethodChannel? = null
    private var screenshotsAllowed = false
    private var vaultLocked = true
    private var captureForeground = false

    private fun applyCapturePolicy() {
        if (screenshotsAllowed && !vaultLocked && captureForeground) {
            window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
        } else {
            window.addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
        }
    }
    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == Intent.ACTION_SCREEN_OFF) {
                vaultLocked = true
                applyCapturePolicy()
                securityChannel?.invokeMethod("screenOff", null)
                SecurityLifecycle.submit(context, SecurityLifecycle.SCREEN_OFF)
            }
        }
    }

    override fun onDestroy() {
        unregisterReceiver(screenReceiver)
        securityChannel = null
        if (!isChangingConfigurations) SecurityLifecycle.submit(this, SecurityLifecycle.CLOSE)
        wipePendingSave()
        apkUpdates?.close()
        super.onDestroy()
    }
    private external fun initializeVeilid(context: Context)
    private var nativeLibraryLoaded = false
    private var veilidBootstrapReady = false
    private var veilidBootstrapCode = "not_started"
    private var pendingSaveResult: MethodChannel.Result? = null
    private var pendingSaveBytes: ByteArray? = null

    override fun onResume() {
        super.onResume()
        captureForeground = true
        applyCapturePolicy()
        MessagingService.uiResumed = true
    }

    override fun onPause() {
        captureForeground = false
        vaultLocked = true // Keep task snapshots secure until Flutter rechecks the session.
        applyCapturePolicy()
        MessagingService.uiResumed = false
        super.onPause()
    }

    override fun popSystemNavigator(): Boolean {
        // Reached only after Flutter has exhausted its routes. On newer
        // Android versions Back can hide the root task without destroying it.
        securityChannel?.invokeMethod("appClosing", null)
        SecurityLifecycle.submit(this, SecurityLifecycle.CLOSE)
        wipePendingSave()
        return super.popSystemNavigator()
    }

    override fun onStop() {
        super.onStop()
        if (nativeLibraryLoaded) {
            SecurityLifecycle.submit(this, if (isFinishing) SecurityLifecycle.CLOSE else SecurityLifecycle.BACKGROUND)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        ensureVeilidInitialized()
        // Veilid needs Android's Context/JVM before Flutter can invoke FFI.
        super.onCreate(savedInstanceState)
        ContextCompat.registerReceiver(this, screenReceiver, IntentFilter(Intent.ACTION_SCREEN_OFF), ContextCompat.RECEIVER_NOT_EXPORTED)
        // Hide task snapshots until Flutter has read the saved vault policy.
        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_SECURE)
        MessageNotificationSettings.createChannel(this)
        NetworkRecovery.start(this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        securityChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "sylphy/security")
        apkUpdates = ApkUpdateHandler(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "sylphy/updates")
            .setMethodCallHandler(apkUpdates)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PLATFORM_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "flushSecurityEvents" -> SecurityLifecycle.flush { runOnUiThread { result.success(null) } }
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
                    "getNotificationSettings" -> {
                        result.success(MessageNotificationSettings.snapshot(this))
                    }
                    "setNotificationsEnabled" -> {
                        val enabled = call.arguments as? Boolean
                        if (enabled == null) {
                            result.error("invalid_arguments", "Valore notifiche non valido.", null)
                        } else {
                            try {
                                MessageNotificationSettings.setEnabled(this, enabled)
                                result.success(MessageNotificationSettings.snapshot(this))
                            } catch (_: Exception) {
                                result.error("notification_settings_failed", "Impossibile salvare le preferenze notifiche.", null)
                            }
                        }
                    }
                    "openNotificationSettings" -> {
                        try {
                            openNotificationSettings(call.arguments == true)
                            result.success(null)
                        } catch (_: Exception) {
                            result.error("notification_settings_unavailable", "Impossibile aprire le impostazioni Android.", null)
                        }
                    }
                    "showMessageNotification" -> {
                        showMessageNotification(call.argument<Boolean>("pinned") == true, call.argument<String>("conversation_id"))
                        result.success(true)
                    }
                    "clearConversationNotification" -> {
                        call.argument<String>("conversation_id")?.let {
                            NotificationManagerCompat.from(this).cancel("conversation:$it", MessagingService.INCOMING_NOTIFICATION_ID)
                        }
                        result.success(true)
                    }
                    "clearMessageSummary" -> {
                        NotificationManagerCompat.from(this).cancel(MessagingService.INCOMING_NOTIFICATION_ID)
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
                            AppDiagnostics.e("Sylphy", "Unable to start background messaging", error)
                            result.error(
                                "background_messaging_unavailable",
                                "Il servizio messaggi in background non è disponibile.",
                                null,
                            )
                        }
                    }
                    "saveFile" -> saveFile(call.arguments, result)
                    "setVaultProtected" -> {
                        val locked = call.arguments as? Boolean
                        if (locked == null) { result.error("invalid_arguments", "Expected a boolean", null) }
                        else { vaultLocked = locked; applyCapturePolicy(); result.success(null) }
                    }
                    "setAllowScreenshots" -> {
                        val allowed = call.arguments as? Boolean
                        if (allowed == null) { result.error("invalid_arguments", "Expected a boolean", null) }
                        else { screenshotsAllowed = allowed; applyCapturePolicy(); result.success(null) }
                    }
                    "setDiagnosticLogging" -> {
                        AppDiagnostics.enabled = call.arguments == true
                        result.success(null)
                    }
                    "memoryCleanupStatus" -> {
                        when (call.arguments) {
                            "started" -> MemoryCleanupNotifications.show(this, "Pulizia della memoria in corso…", true)
                            "completed" -> MemoryWipeService.start(this)
                            "failed" -> MemoryCleanupNotifications.show(this, "Pulizia non completata", false)
                        }
                        result.success(null)
                    }
                    "wipeSensitiveBuffers" -> {
                        wipePendingSave()
                        result.success(null)
                    }
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

    private fun wipePendingSave() {
        pendingSaveBytes?.fill(0)
        pendingSaveBytes = null
        val pending = pendingSaveResult
        pendingSaveResult = null
        pending?.success(null)
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
        if (result == null || bytes == null) return
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            bytes.fill(0)
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
        } finally {
            bytes.fill(0)
        }
    }

    private fun openNotificationSettings(channel: Boolean) {
        MessageNotificationSettings.createChannel(this)
        val details = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.parse("package:$packageName"))
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(if (channel) Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS
                else Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                if (channel) putExtra(Settings.EXTRA_CHANNEL_ID, MessageNotificationSettings.CHANNEL_ID)
            }
        } else details
        try {
            startActivity(intent)
        } catch (_: android.content.ActivityNotFoundException) {
            startActivity(details)
        }
    }

    private fun requestNotificationPermission() {
        if (!MessageNotificationSettings.enabled(this)) return
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

    private fun showMessageNotification(pinned: Boolean = false, conversationId: String? = null) {
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
        val notification = NotificationCompat.Builder(this, MessageNotificationSettings.CHANNEL_ID)
            .setDefaults(android.app.Notification.DEFAULT_SOUND or android.app.Notification.DEFAULT_VIBRATE)
            .setSmallIcon(R.drawable.sylphy_notification)
            .setContentTitle(if (pinned) "Messaggio fissato" else "Nuovo messaggio")
            .setContentText(if (pinned) "Un messaggio è stato fissato in un gruppo Sylphy" else "Hai ricevuto un nuovo messaggio su Sylphy")
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .build()
        MessageNotificationSettings.post(this, "conversation:${conversationId ?: "unknown"}", notification)
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
            AppDiagnostics.i("Sylphy", "Native Veilid platform bootstrap ready")
        } catch (error: ClassNotFoundException) {
            veilidBootstrapReady = false
            veilidBootstrapCode = "android_dependency_missing"
            AppDiagnostics.e("Sylphy", "Veilid protected-store dependency missing", error)
        } catch (error: UnsatisfiedLinkError) {
            veilidBootstrapReady = false
            veilidBootstrapCode = "native_library_missing"
            AppDiagnostics.e("Sylphy", "Sylphy native library unavailable", error)
        } catch (error: Throwable) {
            veilidBootstrapReady = false
            veilidBootstrapCode = "jni_initialization_failed"
            AppDiagnostics.e("Sylphy", "Native Veilid initialization failed", error)
        }
    }

    private companion object {
        const val PLATFORM_CHANNEL = "sylphy/platform"
        const val NOTIFICATION_PERMISSION_REQUEST = 4102
        const val SAVE_FILE_REQUEST = 4103
        val REQUIRED_PROTECTED_STORE_CLASSES = listOf(
            "androidx.security.crypto.MasterKey",
            "androidx.security.crypto.MasterKey\$Builder",
            "androidx.security.crypto.EncryptedSharedPreferences",
        )
    }
}
