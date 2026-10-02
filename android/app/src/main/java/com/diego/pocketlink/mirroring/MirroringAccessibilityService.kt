package com.diego.pocketlink.mirroring

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Build
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import com.diego.pocketlink.protocol.MirrorProtocol

/**
 * Injects remote touch gestures. Enabled manually by the user in system
 * settings (side-loaded usage only; not compliant with Play policy if
 * distributed).
 *
 * Builds one continuous [GestureDescription.StrokeDescription] per touch
 * sequence: "down" starts the stroke, "move" continues it, "up" finishes it.
 */
class MirroringAccessibilityService : AccessibilityService() {

    private var pendingStroke: GestureDescription.StrokeDescription? = null
    private var lastX = 0f
    private var lastY = 0f

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        Log.d(TAG, "Accessibility service connected")
    }

    override fun onDestroy() {
        instance = null
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
                MirrorProtocol.ACTION_DOWN -> beginStroke(x, y)
                MirrorProtocol.ACTION_MOVE -> continueStroke(x, y)
                MirrorProtocol.ACTION_UP -> finishStroke(x, y)
            }
        } catch (e: Exception) {
            Log.w(TAG, "Gesture dispatch failed: ${e.message}")
            pendingStroke = null
        }
    }

    private fun beginStroke(x: Float, y: Float) {
        val path = Path().apply { moveTo(x, y) }
        val stroke = GestureDescription.StrokeDescription(path, 0, STROKE_DOWN_DURATION_MS, true)
        dispatch(GestureDescription.Builder().addStroke(stroke).build())
        pendingStroke = stroke
        lastX = x
        lastY = y
    }

    private fun continueStroke(x: Float, y: Float) {
        val previous = pendingStroke ?: return
        val path = Path().apply {
            moveTo(lastX, lastY)
            lineTo(x, y)
        }
        val stroke = previous.continueStroke(path, 0, STROKE_MOVE_DURATION_MS, true)
        dispatch(GestureDescription.Builder().addStroke(stroke).build())
        pendingStroke = stroke
        lastX = x
        lastY = y
    }

    private fun finishStroke(x: Float, y: Float) {
        val previous = pendingStroke
        pendingStroke = null
        if (previous == null) {
            // Tap without a prior down: short tap at the final position.
            val path = Path().apply { moveTo(x, y) }
            dispatch(
                GestureDescription.Builder()
                    .addStroke(GestureDescription.StrokeDescription(path, 0, STROKE_TAP_DURATION_MS))
                    .build()
            )
            return
        }
        val path = Path().apply {
            moveTo(lastX, lastY)
            lineTo(x, y)
        }
        val stroke = previous.continueStroke(path, 0, STROKE_UP_DURATION_MS, false)
        dispatch(GestureDescription.Builder().addStroke(stroke).build())
    }

    private fun dispatch(description: GestureDescription) {
        dispatchGesture(description, null, null)
    }

    companion object {
        private const val TAG = "MirroringA11yService"
        private const val STROKE_DOWN_DURATION_MS = 16L
        private const val STROKE_MOVE_DURATION_MS = 16L
        private const val STROKE_UP_DURATION_MS = 16L
        private const val STROKE_TAP_DURATION_MS = 80L

        @Volatile
        var instance: MirroringAccessibilityService? = null
            private set

        val isEnabled: Boolean
            get() = instance != null

        fun dispatchTouch(action: String, xNorm: Double, yNorm: Double) {
            instance?.handleTouch(action, xNorm, yNorm)
        }
    }
}
