package com.example.idl0

import android.annotation.SuppressLint
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Platform channel plugin for the device-AP link: a pure sensor/actuator
 * (SPEC §6.2). All policy — timeouts, retries, state — lives in Dart.
 *
 * Commands (MethodChannel "idl0/wifi_network", both return immediately):
 *   request(ssid, password) — register a WifiNetworkSpecifier request
 *   release()               — unregister + stop the proxy
 *
 * Events (EventChannel "idl0/wifi_network_events"), each a Map:
 *   {event:"available", ssid, port}  — link up; device reachable at
 *                                      127.0.0.1:port (port null on
 *                                      API < 29: talk to 192.168.4.1
 *                                      directly)
 *   {event:"lost", ssid}             — Android dropped the network
 *   {event:"unavailable", ssid}      — request rejected (user denied)
 *
 * No process-wide bind: device traffic flows through [LoopbackProxy] over
 * [Network.socketFactory] sockets, so internet routing (Drive sync) is
 * untouched while linked. No timers: the system approval dialog is never
 * dismissed by our side; Dart owns the request budget.
 */
class WifiNetworkPlugin(private val context: Context) {

    companion object {
        /** Command channel. Must match [WifiNetworkBinder] in Dart. */
        const val CHANNEL = "idl0/wifi_network"

        /** Event channel. Must match [WifiNetworkBinder] in Dart. */
        const val EVENT_CHANNEL = "idl0/wifi_network_events"

        private const val TAG = "idl0-wifi"
    }

    private val connectivityManager =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    /** Active network callback; non-null while a request is registered. */
    @Volatile
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    @Volatile
    private var proxy: LoopbackProxy? = null

    /** Registers the method + event channels on [flutterEngine]. */
    fun register(flutterEngine: FlutterEngine) {
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "request" -> {
                    val ssid = call.argument<String>("ssid")
                    val password = call.argument<String>("password")
                    if (ssid == null || password == null) {
                        result.error("INVALID_ARGS", "ssid and password are required", null)
                        return@setMethodCallHandler
                    }
                    request(ssid, password)
                    result.success(null)
                }
                "release" -> {
                    release()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink) {
                    eventSink = sink
                }
                override fun onCancel(args: Any?) {
                    eventSink = null
                }
            }
        )
    }

    /** Emits [event] on the main thread (EventChannel requirement). */
    private fun emit(event: Map<String, Any?>) {
        mainHandler.post { eventSink?.success(event) }
    }

    @SuppressLint("MissingPermission")
    private fun request(ssid: String, password: String) {
        // One request at a time: a new SSID supersedes whatever was live.
        // This is also what keys the network to the SSID — there is no
        // cached Network that a different device's request could reuse.
        release()

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            // No specifier API: the user joins the AP in system Settings and
            // 192.168.4.1 routes correctly. Report available with no proxy.
            Log.i(TAG, "request($ssid): API ${Build.VERSION.SDK_INT} < 29 — direct mode")
            emit(mapOf("event" to "available", "ssid" to ssid, "port" to null))
            return
        }

        Log.i(TAG, "request($ssid)")
        val specifier = WifiNetworkSpecifier.Builder()
            .setSsid(ssid)
            .setWpa2Passphrase(password)
            .build()

        // The AP is local-only: without removing NET_CAPABILITY_INTERNET the
        // request can never be satisfied and neither callback ever fires.
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()

        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                Log.i(TAG, "onAvailable($ssid)")
                proxy?.stop()
                val p = LoopbackProxy(network)
                val port = try {
                    p.start()
                } catch (e: Exception) {
                    Log.e(TAG, "proxy start failed: $e")
                    emit(mapOf("event" to "unavailable", "ssid" to ssid))
                    return
                }
                proxy = p
                emit(mapOf("event" to "available", "ssid" to ssid, "port" to port))
            }

            override fun onLost(network: Network) {
                Log.w(TAG, "onLost($ssid)")
                proxy?.stop()
                proxy = null
                emit(mapOf("event" to "lost", "ssid" to ssid))
            }

            override fun onUnavailable() {
                Log.w(TAG, "onUnavailable($ssid)")
                // Terminal for this request: unregister so the registration
                // is never leaked (ConnectivityManager caps requests per app).
                unregisterCallback()
                emit(mapOf("event" to "unavailable", "ssid" to ssid))
            }
        }

        networkCallback = callback
        connectivityManager.requestNetwork(request, callback)
    }

    private fun release() {
        unregisterCallback()
        proxy?.stop()
        proxy = null
    }

    private fun unregisterCallback() {
        networkCallback?.let { cb ->
            try {
                connectivityManager.unregisterNetworkCallback(cb)
            } catch (_: Exception) {
                // Already unregistered — safe to ignore.
            }
        }
        networkCallback = null
    }
}
