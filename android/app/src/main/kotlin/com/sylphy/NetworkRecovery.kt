package com.sylphy

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.PowerManager
import androidx.core.content.ContextCompat

/** Process-wide default-network observer; stores no addresses, SSIDs or identifiers. */
internal object NetworkRecovery {
    private external fun networkChanged(available: Boolean): Int
    private var started = false
    private lateinit var worker: Handler
    private val transitions = NetworkTransitionState()
    @Volatile var available: Boolean = true
        private set

    @Synchronized fun start(context: Context) {
        if (started) return
        val app = context.applicationContext
        val connectivity = app.getSystemService(ConnectivityManager::class.java)
        val thread = HandlerThread("sylphy-network").apply { start() }
        worker = Handler(thread.looper)
        val evaluate = Runnable {
            val network = connectivity.activeNetwork
            val caps = network?.let { connectivity.getNetworkCapabilities(it) }
            // Validation probes can be blocked by VPNs or privacy-oriented networks.
            // INTERNET is only a hint; Veilid still verifies actual connectivity.
            val online = caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
            val revision = transitions.update(network, online) ?: return@Runnable
            available = online
            recover(online, revision, 0)
        }
        fun changed() {
            // Query after callbacks settle: a lost old network can overlap the new one.
            worker.removeCallbacks(evaluate)
            worker.postDelayed(evaluate, 500)
        }
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = changed()
            override fun onLost(network: Network) = changed()
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) = changed()
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                connectivity.registerDefaultNetworkCallback(callback)
            } else {
                connectivity.registerNetworkCallback(NetworkRequest.Builder()
                    .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET).build(), callback)
            }
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    changed()
                    MessagingService.requestInboxPoll()
                }
            }
            ContextCompat.registerReceiver(app, receiver, IntentFilter().apply {
                addAction(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
                addAction(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
                addAction(Intent.ACTION_SCREEN_ON)
            }, ContextCompat.RECEIVER_NOT_EXPORTED)
            started = true
            changed()
        } catch (error: RuntimeException) {
            try { connectivity.unregisterNetworkCallback(callback) } catch (_: RuntimeException) { }
            thread.quitSafely()
            AppDiagnostics.w("Sylphy", "Network observer unavailable", error)
        }
    }

    private fun recover(online: Boolean, revision: Long, attempt: Int) {
        if (!transitions.isCurrent(revision)) return
        try {
            System.loadLibrary("sylphy_core")
            val result = networkChanged(online)
            if (result != 0) {
                // A slow account commit must not consume the only network-change event.
                worker.postDelayed({ recover(online, revision, (attempt + 1).coerceAtMost(5)) }, 500L shl attempt.coerceAtMost(5))
            }
        } catch (error: Throwable) {
            AppDiagnostics.w("Sylphy", "Network recovery deferred", error)
        } finally {
            MessagingService.requestInboxPoll()
        }
    }
}
