package com.example.sylphy

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Only a verified APK from the private update directory reaches Android's installer. */
class ApkUpdateHandler(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private val executor = Executors.newSingleThreadExecutor()
    private val busy = AtomicBoolean(false)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "allowInstalls" -> {
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:${activity.packageName}")))
                    }
                    result.success(null)
                } catch (_: Exception) {
                    result.error("settings_unavailable", "Apri le impostazioni Android per consentire gli aggiornamenti di Sylphy.", null)
                }
            }
            "installApk" -> {
                if (!busy.compareAndSet(false, true)) {
                    result.error("install_busy", "Un aggiornamento è già in preparazione.", null)
                    return
                }
                val path = call.argument<String>("path")
                val version = call.argument<String>("version")
                val build = call.argument<Number>("build")?.toLong()
                executor.execute {
                    try {
                        require(!path.isNullOrBlank() && version != null && build != null) { "Dati di aggiornamento non validi." }
                        val file = File(path).canonicalFile
                        val directory = File(activity.filesDir, "updates/packages").canonicalFile
                        require(file.parentFile == directory && file.isFile && file.extension == "apk") { "Percorso APK non autorizzato." }
                        @Suppress("DEPRECATION")
                        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
                        val manager = activity.packageManager
                        @Suppress("DEPRECATION")
                        val candidate = manager.getPackageArchiveInfo(file.path, flags)
                            ?: throw IllegalArgumentException("APK non valido. Scarica nuovamente l’aggiornamento.")
                        @Suppress("DEPRECATION")
                        val installed = manager.getPackageInfo(activity.packageName, flags)
                        require(candidate.packageName == activity.packageName) { "Questo APK appartiene a un’altra app." }
                        require(versionCode(candidate) == build && candidate.versionName == version) { "La versione dell’APK non corrisponde alla release." }
                        require(versionCode(candidate) > versionCode(installed)) { "L’APK non è più recente della versione installata." }
                        require(certificates(candidate).isNotEmpty() && certificates(candidate) == certificates(installed)) {
                            "Firma APK diversa dalla versione installata. Serve una release firmata con la stessa chiave; non disinstallare l’app."
                        }
                        activity.runOnUiThread {
                            try {
                                if (activity.isFinishing || activity.isDestroyed) {
                                    result.error("activity_closed", "Riapri Sylphy per aggiornare.", null)
                                } else if (Build.VERSION.SDK_INT >= 26 && !manager.canRequestPackageInstalls()) {
                                    result.success("permission_required")
                                } else {
                                    val uri = FileProvider.getUriForFile(activity,
                                        "${activity.packageName}.updates", file)
                                    val intent = Intent(Intent.ACTION_VIEW).apply {
                                        setDataAndType(uri, "application/vnd.android.package-archive")
                                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                        clipData = android.content.ClipData.newRawUri("Sylphy update", uri)
                                    }
                                    activity.startActivity(intent)
                                    result.success("started")
                                }
                            } catch (_: Exception) {
                                result.error("installer_unavailable", "Impossibile aprire l’installazione Android. Riprova.", null)
                            } finally { busy.set(false) }
                        }
                    } catch (error: Exception) {
                        activity.runOnUiThread {
                            result.error("invalid_update", if (error is IllegalArgumentException) error.message else "Impossibile verificare l’APK.", null)
                            busy.set(false)
                        }
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    @Suppress("DEPRECATION")
    private fun versionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()

    @Suppress("DEPRECATION")
    private fun certificates(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
        return signatures.orEmpty().map { signature ->
            MessageDigest.getInstance("SHA-256").digest(signature.toByteArray())
                .joinToString("") { "%02x".format(it) }
        }.toSet()
    }

    fun close() { executor.shutdown() }
}
