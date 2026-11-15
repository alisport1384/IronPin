package ir.ironpin.ironpin

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Watches Android network connectivity changes without external plugins.
 *
 * Emits a `connected` event on every new internet connection (offline -> online,
 * Wi-Fi <-> cellular handoff, or VPN tunnel activation/deactivation) so Smart
 * Search 2 and its handoff to Smart Search 1 wake up immediately.
 */
class NetworkChannel(context: Context, messenger: BinaryMessenger) : EventChannel.StreamHandler {

    companion object {
        const val METHOD_CHANNEL = "ir.ironpin.ironpin/network"
        const val EVENT_CHANNEL = "ir.ironpin.ironpin/network_events"
    }

    private val appContext = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())
    private val cm =
        appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
    private var eventSink: EventChannel.EventSink? = null
    private var registered = false
    @Volatile
    private var lastSignature: String? = null

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            notifyIfChanged(network, cm?.getNetworkCapabilities(network))
        }

        override fun onCapabilitiesChanged(
            network: Network,
            networkCapabilities: NetworkCapabilities
        ) {
            notifyIfChanged(network, networkCapabilities)
        }

        override fun onLost(network: Network) {
            if (!isCurrentlyConnected()) {
                lastSignature = null
                emit(mapOf("type" to "disconnected", "connected" to false))
            } else {
                // Another network took over (e.g. VPN closed -> domestic Wi-Fi/LTE).
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    val active = cm?.activeNetwork
                    if (active != null) {
                        notifyIfChanged(active, cm?.getNetworkCapabilities(active))
                    }
                }
            }
        }
    }

    init {
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(currentStatus())
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(this)
        startMonitoring()
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun startMonitoring() {
        val manager = cm ?: return
        if (registered) return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                manager.registerDefaultNetworkCallback(callback)
            } else {
                val req = NetworkRequest.Builder()
                    .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    .build()
                manager.registerNetworkCallback(req, callback)
            }
            registered = true
            // Seed initial signature so only subsequent transitions (or reconnects)
            // count as fresh connection events after startup.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val active = manager.activeNetwork
                val caps = if (active != null) manager.getNetworkCapabilities(active) else null
                if (active != null && hasInternet(caps)) {
                    lastSignature = signatureOf(active, caps)
                }
            }
        } catch (_: Throwable) {
            registered = false
        }
    }

    private fun hasInternet(caps: NetworkCapabilities?): Boolean =
        caps != null && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)

    private fun signatureOf(network: Network, caps: NetworkCapabilities?): String {
        val vpn = caps?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
        val wifi = caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        val cell = caps?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true
        return "$network|vpn=$vpn|wifi=$wifi|cell=$cell"
    }

    private fun notifyIfChanged(network: Network, caps: NetworkCapabilities?) {
        val effectiveCaps = caps ?: cm?.getNetworkCapabilities(network)
        if (!hasInternet(effectiveCaps)) return
        val sig = signatureOf(network, effectiveCaps)
        if (sig == lastSignature) return
        lastSignature = sig
        val vpn = effectiveCaps?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
        emit(
            mapOf(
                "type" to "connected",
                "connected" to true,
                "vpn" to vpn,
                "signature" to sig
            )
        )
    }

    private fun isCurrentlyConnected(): Boolean {
        val manager = cm ?: return false
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val active = manager.activeNetwork ?: return false
                hasInternet(manager.getNetworkCapabilities(active))
            } else {
                @Suppress("DEPRECATION")
                manager.activeNetworkInfo?.isConnected == true
            }
        } catch (_: Throwable) {
            false
        }
    }

    private fun currentStatus(): Map<String, Any> {
        val manager = cm
        var connected = false
        var vpn = false
        try {
            if (manager != null) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    val active = manager.activeNetwork
                    val caps = if (active != null) manager.getNetworkCapabilities(active) else null
                    connected = hasInternet(caps)
                    vpn = caps?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
                } else {
                    @Suppress("DEPRECATION")
                    connected = manager.activeNetworkInfo?.isConnected == true
                }
            }
        } catch (_: Throwable) {
        }
        return mapOf("connected" to connected, "vpn" to vpn)
    }

    private fun emit(payload: Map<String, Any>) {
        mainHandler.post {
            try {
                eventSink?.success(payload)
            } catch (_: Throwable) {
            }
        }
    }

    fun dispose() {
        eventSink = null
        if (registered) {
            try {
                cm?.unregisterNetworkCallback(callback)
            } catch (_: Throwable) {
            }
            registered = false
        }
    }
}
