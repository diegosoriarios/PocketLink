package com.diego.pocketlink.battery

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.PowerManager
import android.util.Log

data class BatteryStatus(
    val level: Int,
    val isCharging: Boolean,
    val powerSaveMode: Boolean
)

class BatterySyncManager(
    private val context: Context,
    private val onBatteryStatusChanged: (BatteryStatus) -> Unit
) {
    private var lastStatus: BatteryStatus? = null

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            val status = getBatteryStatus() ?: return
            if (status != lastStatus) {
                lastStatus = status
                Log.d(TAG, "Battery status updated: Level=${status.level}%, Charging=${status.isCharging}, PowerSave=${status.powerSaveMode}")
                onBatteryStatusChanged(status)
            }
        }
    }

    fun startListening() {
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_BATTERY_CHANGED)
            addAction(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
        }
        try {
            context.registerReceiver(receiver, filter)
            // Immediately fetch and dispatch initial status
            getBatteryStatus()?.let { status ->
                lastStatus = status
                onBatteryStatusChanged(status)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to register battery receiver: ${e.message}")
        }
    }

    fun stopListening() {
        try {
            context.unregisterReceiver(receiver)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to unregister battery receiver: ${e.message}")
        }
    }

    fun getBatteryStatus(): BatteryStatus? {
        return try {
            val batteryStatusIntent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            val level = batteryStatusIntent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
            val scale = batteryStatusIntent?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
            val status = batteryStatusIntent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1

            val batteryPct = if (level >= 0 && scale > 0) {
                ((level / scale.toFloat()) * 100).toInt()
            } else 0

            val isCharging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
                    status == BatteryManager.BATTERY_STATUS_FULL

            val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            val powerSaveMode = powerManager.isPowerSaveMode

            BatteryStatus(
                level = batteryPct,
                isCharging = isCharging,
                powerSaveMode = powerSaveMode
            )
        } catch (e: Exception) {
            Log.e(TAG, "Failed to read battery status: ${e.message}")
            null
        }
    }

    companion object {
        private const val TAG = "BatterySyncManager"
    }
}
