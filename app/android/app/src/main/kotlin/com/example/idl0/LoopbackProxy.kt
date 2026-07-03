package com.example.idl0

import android.net.Network
import android.util.Log
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Minimal loopback TCP forwarder scoping device traffic to the AP network
 * without process-wide binding (SPEC §6.2).
 *
 * Listens on 127.0.0.1:<ephemeral> and forwards each accepted connection to
 * 192.168.4.1:80 over a socket from [Network.socketFactory] — only these
 * sockets route via the AP; the rest of the app (Drive sync) keeps its
 * default network. Blocking I/O with one accept thread plus two pump
 * threads per connection: at the device's ~500 KB/s and a handful of
 * concurrent connections this is far below any thread-count concern.
 */
class LoopbackProxy(
    private val network: Network,
    private val targetHost: String = "192.168.4.1",
    private val targetPort: Int = 80,
) {
    companion object {
        private const val TAG = "idl0-proxy"

        /** 16 KiB pump buffer — matches WifiTransfer's OTA chunk size. */
        private const val BUF_BYTES = 16 * 1024
    }

    @Volatile
    private var serverSocket: ServerSocket? = null

    /** All live sockets (loopback + device side) so [stop] can kill them. */
    private val sockets = CopyOnWriteArrayList<Socket>()

    /**
     * Starts listening. Returns the loopback port. Throws on bind failure
     * (caller reports the link unavailable).
     */
    fun start(): Int {
        // Explicit IPv4 loopback. InetAddress.getLoopbackAddress() returns
        // the IPv6 ::1 on Android (preferIPv6Addresses=true in libcore), but
        // Dart connects to the literal 127.0.0.1 — an IPv6-bound listener
        // then refuses every connection (observed in the field as instant
        // ECONNREFUSED with no proxy accept logs).
        val v4Loopback = InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1))
        val server = ServerSocket(0, 16, v4Loopback)
        serverSocket = server
        Thread({ acceptLoop(server) }, "idl0-proxy-accept").start()
        Log.i(TAG, "proxy up on 127.0.0.1:${server.localPort} -> $targetHost:$targetPort")
        return server.localPort
    }

    /** Closes the listener and every in-flight connection. Idempotent. */
    fun stop() {
        val server = serverSocket ?: return
        serverSocket = null
        closeQuietly { server.close() }
        sockets.forEach { s -> closeQuietly { s.close() } }
        sockets.clear()
        Log.i(TAG, "proxy stopped")
    }

    private fun acceptLoop(server: ServerSocket) {
        while (!server.isClosed) {
            val client = try {
                server.accept()
            } catch (_: Exception) {
                break  // listener closed by stop()
            }
            sockets.add(client)
            Thread({ handle(client) }, "idl0-proxy-conn").start()
        }
    }

    private fun handle(client: Socket) {
        val device = try {
            network.socketFactory.createSocket(targetHost, targetPort)
        } catch (e: Exception) {
            Log.w(TAG, "device connect failed: $e")
            closeQuietly { client.close() }
            sockets.remove(client)
            return
        }
        sockets.add(device)

        // tcpNoDelay: HTTP request/response on a local link — don't Nagle.
        closeQuietly { client.tcpNoDelay = true }
        closeQuietly { device.tcpNoDelay = true }

        val up = Thread({ pump(client, device) }, "idl0-proxy-up")
        up.start()
        pump(device, client)   // downstream pumped on this thread
        closeQuietly { up.join() }

        closeQuietly { client.close() }
        closeQuietly { device.close() }
        sockets.remove(client)
        sockets.remove(device)
    }

    /**
     * Copies [from] → [to] until EOF, then half-closes [to] so HTTP
     * connection-close semantics propagate through the proxy.
     */
    private fun pump(from: Socket, to: Socket) {
        val buf = ByteArray(BUF_BYTES)
        try {
            val input = from.getInputStream()
            val output = to.getOutputStream()
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                output.write(buf, 0, n)
                output.flush()
            }
            to.shutdownOutput()
        } catch (_: Exception) {
            // Either side dropped — handle() closes both sockets.
        }
    }

    private inline fun closeQuietly(block: () -> Unit) {
        try { block() } catch (_: Exception) {}
    }
}
