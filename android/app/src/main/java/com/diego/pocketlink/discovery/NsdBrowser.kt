package com.diego.pocketlink.discovery

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.util.concurrent.ConcurrentHashMap

class NsdBrowser(
    context: Context,
    private val scope: CoroutineScope
) {
    private val nsdManager: NsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager

    private val _discoveredDevices = MutableStateFlow<List<DiscoveredDevice>>(emptyList())
    val discoveredDevices: StateFlow<List<DiscoveredDevice>> = _discoveredDevices.asStateFlow()

    private val deviceMap = ConcurrentHashMap<String, DiscoveredDevice>()
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    var isDiscovering: Boolean = false
        private set

    fun startDiscovery() {
        if (isDiscovering) return

        deviceMap.clear()
        updateDiscoveredList()

        discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(regType: String) {
                isDiscovering = true
                Log.d(TAG, "NSD Discovery started for $regType")
            }

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                Log.d(TAG, "NSD Service found: ${serviceInfo.serviceName}")
                if (serviceInfo.serviceType.contains("link", ignoreCase = true)) {
                    resolveService(serviceInfo)
                }
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                Log.d(TAG, "NSD Service lost: ${serviceInfo.serviceName}")
                deviceMap.remove(serviceInfo.serviceName)
                updateDiscoveredList()
            }

            override fun onDiscoveryStopped(serviceType: String) {
                isDiscovering = false
                Log.d(TAG, "NSD Discovery stopped")
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                isDiscovering = false
                Log.e(TAG, "NSD Discovery start failed: $errorCode")
                stopDiscovery()
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                isDiscovering = false
                Log.e(TAG, "NSD Discovery stop failed: $errorCode")
            }
        }

        try {
            nsdManager.discoverServices(
                NsdAdvertiser.SERVICE_TYPE,
                NsdManager.PROTOCOL_DNS_SD,
                discoveryListener
            )
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start NSD discovery: ${e.message}")
        }
    }

    private fun resolveService(serviceInfo: NsdServiceInfo) {
        scope.launch(Dispatchers.IO) {
            try {
                nsdManager.resolveService(serviceInfo, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                        Log.e(TAG, "NSD Resolve failed for ${serviceInfo.serviceName}: $errorCode")
                    }

                    override fun onServiceResolved(resolvedService: NsdServiceInfo) {
                        val host = resolvedService.host?.hostAddress ?: return
                        val port = resolvedService.port
                        val name = resolvedService.serviceName

                        Log.d(TAG, "NSD Service resolved: $name at $host:$port")
                        val device = DiscoveredDevice(
                            id = "$host:$port",
                            name = name,
                            host = host,
                            port = port
                        )
                        deviceMap[name] = device
                        updateDiscoveredList()
                    }
                })
            } catch (e: Exception) {
                Log.e(TAG, "Exception resolving NSD service: ${e.message}")
            }
        }
    }

    fun stopDiscovery() {
        val listener = discoveryListener ?: return
        try {
            nsdManager.stopServiceDiscovery(listener)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to stop NSD discovery: ${e.message}")
        } finally {
            discoveryListener = null
            isDiscovering = false
        }
    }

    private fun updateDiscoveredList() {
        _discoveredDevices.value = deviceMap.values.toList()
    }

    companion object {
        private const val TAG = "NsdBrowser"
    }
}
