package com.diego.pocketlink.mirroring

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Build
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import com.diego.pocketlink.protocol.MirrorProtocol
import kotlin.math.hypot

/**
 * Injects remote touch gestures. Enabled manually by the user in system
 * settings (side-loaded usage only; not compliant with Play policy if
 * distributed).
 *
 * Buffers the points of one touch sequence and dispatches a single gesture
 * on "up": a short tap when the pointer barely moved, otherwise one
 * continuous stroke through all buffered points. Dispatching one gesture
 * per sequence avoids preemption and too-short strokes, which MIUI
 * launchers tend to drop.
 */
class MirroringAccessibilityService : AccessibilityService() {

    private val strokePoints = mutableListOf<Pair<Float, Float>>()

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        _enabledFlow.value = true
        Log.d(TAG, "Accessibility service connected")
    }

    override fun onDestroy() {
        instance = null
        _enabledFlow.value = false
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}

    override fun onInterrupt() {}

    fun handleTouch(action: String, xNorm: Double, yNorm: Double) {
        val metrics = resources.displayMetrics
        val x = (xNorm * metrics.widthPixels).coerceIn(0.0, (metrics.widthPixels - 1).toDouble()).toFloat()
        val y = (yNorm * metrics.heightPixels).coerceIn(0.0, (metrics.heightPixels - 1).toDouble()).toFloat()

        try {
            when (action) {
                MirrorProtocol.ACTION_DOWN -> startStroke(x, y)
                MirrorProtocol.ACTION_MOVE -> strokePoints.add(x to y)
                MirrorProtocol.ACTION_UP -> finishStroke(x, y)
            }
        } catch (e: Exception) {
            Log.w(TAG, "Gesture dispatch failed: ${e.message}")
            strokePoints.clear()
        }
    }

    private fun startStroke(x: Float, y: Float) {
        strokePoints.clear()
        strokePoints.add(x to y)
    }

    private fun finishStroke(x: Float, y: Float) {
        strokePoints.add(x to y)
        val points = strokePoints.toList()
        strokePoints.clear()
        if (points.isEmpty()) return

        val (firstX, firstY) = points.first()
        val last = points.last()
        val displacement = hypot(
            (last.first - firstX).toDouble(),
            (last.second - firstY).toDouble()
        )

        val path = Path().apply {
            moveTo(firstX, firstY)
            for (i in 1 until points.size) {
                lineTo(points[i].first, points[i].second)
            }
        }
        val durationMs = if (displacement < TAP_SLOP_PX) {
            TAP_DURATION_MS
        } else {
            (points.size * 33L).coerceIn(MIN_DRAG_DURATION_MS, MAX_DRAG_DURATION_MS)
        }
        dispatch(
            GestureDescription.Builder()
                .addStroke(GestureDescription.StrokeDescription(path, 0, durationMs))
                .build()
        )
    }

    private fun dispatch(description: GestureDescription) {
        dispatchGesture(
            description,
            object : GestureResultCallback() {
                override fun onCancelled(gestureDescription: GestureDescription?) {
                    Log.w(TAG, "Gesture dispatch cancelled by the system")
                }
            },
            null
        )
    }

    companion object {
        private const val TAG = "MirroringA11yService"
        private const val TAP_SLOP_PX = 24.0
        private const val TAP_DURATION_MS = 120L
        private const val MIN_DRAG_DURATION_MS = 200L
        private const val MAX_DRAG_DURATION_MS = 1200L

        @Volatile
        var instance: MirroringAccessibilityService? = null
            private set

        private val _enabledFlow = kotlinx.coroutines.flow.MutableStateFlow(false)

        /** True while the user has enabled (and the system has bound) this service. */
        val enabledFlow: kotlinx.coroutines.flow.StateFlow<Boolean> = _enabledFlow

        val isEnabled: Boolean
            get() = instance != null

        fun dispatchTouch(action: String, xNorm: Double, yNorm: Double) {
            instance?.handleTouch(action, xNorm, yNorm)
        }
    }
}
