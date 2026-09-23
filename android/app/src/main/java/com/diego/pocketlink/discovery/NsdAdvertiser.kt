package com.diego.pocketlink.discovery

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.util.Log

class NsdAdvertiser(context: Context) {

    private val nsdManager: NsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private var registrationListener: NsdManager.RegistrationListener? = null
    var isAdvertising: Boolean = false
        private set

    fun registerService(port: Int, customDeviceName: String? = null) {
        if (isAdvertising) return

        val deviceName = customDeviceName ?: "Link-${Build.MODEL.replace(" ", "-")}"
        val serviceInfo = NsdServiceInfo().apply {
            serviceName = deviceName
            serviceType = SERVICE_TYPE
            this.port = port
        }

        registrationListener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(NsdServiceInfo: NsdServiceInfo) {
                isAdvertising = true
                Log.d(TAG, "NSD Service registered successfully: ${NsdServiceInfo.serviceName}")
            }

            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                isAdvertising = false
                Log.e(TAG, "NSD Service registration failed with error code: $errorCode")
            }

            override fun onServiceUnregistered(arg0: NsdServiceInfo) {
                isAdvertising = false
                Log.d(TAG, "NSD Service unregistered successfully")
            }

            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                isAdvertising = false
                Log.e(TAG, "NSD Service unregistration failed with error code: $errorCode")
            }
        }

        try {
            nsdManager.registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, registrationListener)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to register NSD service: ${e.message}")
        }
    }

    fun unregisterService() {
        val listener = registrationListener ?: return
        try {
            nsdManager.unregisterService(listener)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to unregister NSD service: ${e.message}")
        } finally {
            registrationListener = null
            isAdvertising = false
        }
    }

    companion object {
        const val SERVICE_TYPE = "_link._tcp."
        private const val TAG = "NsdAdvertiser"
    }
}
