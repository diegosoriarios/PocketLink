package com.diego.pocketlink.mirroring

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import com.diego.pocketlink.protocol.MirrorProtocol
import java.nio.ByteBuffer

/**
 * Async H.264 encoder fed by a [MediaProjection] virtual display.
 *
 * Emits a config callback (parameters + csd blobs) once the codec reports
 * its output format, then one frame callback per access unit. Senders are
 * injected so this class stays free of connection dependencies.
 */
class ScreenCaptureEncoder(
    private val projection: MediaProjection,
    private val width: Int,
    private val height: Int,
    private val dpi: Int,
    private val onConfig: (MirrorProtocol.MirrorConfig) -> Unit,
    private val onFrame: (timestampMs: Long, keyframe: Boolean, accessUnit: ByteArray) -> Unit,
    private val onEnded: () -> Unit
) : MediaProjection.Callback() {

    private val codecThread = HandlerThread("PocketLinkMirrorEncoder").apply { start() }
    private val codecHandler = Handler(codecThread.looper)

    private var codec: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var virtualDisplay: android.hardware.display.VirtualDisplay? = null
    private var sentConfig = false
    private var stopped = false

    fun start() {
        projection.registerCallback(this, codecHandler)

        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(
                MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface
            )
            setInteger(MediaFormat.KEY_BIT_RATE, DEFAULT_BITRATE_BPS)
            setInteger(MediaFormat.KEY_FRAME_RATE, DEFAULT_FPS)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            setInteger(
                MediaFormat.KEY_BITRATE_MODE,
                MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR
            )
            setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline)
            if (android.os.Build.VERSION.SDK_INT >= 30) {
                setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }
        }

        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        this.codec = codec
        codec.setCallback(EncoderCallback(), codecHandler)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        val surface = codec.createInputSurface()
        inputSurface = surface
        codec.start()

        virtualDisplay = projection.createVirtualDisplay(
            "PocketLinkMirror",
            width,
            height,
            dpi,
            android.hardware.display.DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            surface,
            null,
            codecHandler
        )
        Log.d(TAG, "Encoder started (${width}x${height} @${DEFAULT_FPS}fps)")
    }

    fun stop() {
        if (stopped) return
        stopped = true
        try {
            virtualDisplay?.release()
        } catch (e: Exception) {
            Log.w(TAG, "VirtualDisplay release failed: ${e.message}")
        }
        virtualDisplay = null
        try {
            codec?.signalEndOfInputStream()
        } catch (_: Exception) {
            // Codec may already be in a terminal state.
        }
        try {
            codec?.stop()
        } catch (e: Exception) {
            Log.w(TAG, "Codec stop failed: ${e.message}")
        }
        try {
            codec?.release()
        } catch (e: Exception) {
            Log.w(TAG, "Codec release failed: ${e.message}")
        }
        codec = null
        inputSurface?.release()
        inputSurface = null
        try {
            projection.unregisterCallback(this)
            projection.stop()
        } catch (e: Exception) {
            Log.w(TAG, "Projection stop failed: ${e.message}")
        }
        codecThread.quitSafely()
        onEnded()
    }

    /** User stopped capture from the system cast tile. */
    override fun onStop() {
        MirroringService.onCaptureEnded()
    }

    private inner class EncoderCallback : MediaCodec.Callback() {
        override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {
            // Surface input: buffers are never dequeued manually.
        }

        override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
            // The finally block below is the single release point for `index`;
            // releasing here as well would double-release and corrupt the slot.
            try {
                val output = codec.getOutputBuffer(index) ?: return
                if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                    handleConfigBuffer(codec, output, info)
                    return
                }
                if (info.size <= 0) {
                    return
                }
                val accessUnit = ByteArray(info.size)
                output.position(info.offset)
                output.limit(info.offset + info.size)
                output.get(accessUnit)
                onFrame(
                    info.presentationTimeUs / 1000,
                    info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0,
                    accessUnit
                )
            } catch (e: Exception) {
                Log.w(TAG, "Output buffer handling failed: ${e.message}")
            } finally {
                try {
                    codec.releaseOutputBuffer(index, false)
                } catch (_: Exception) {
                }
            }
        }

        override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
            // Config blobs often arrive here instead of as a codec-config buffer.
            if (!sentConfig) {
                sendConfig(format)
            }
        }

        override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
            Log.e(TAG, "Encoder error: ${e.message}")
            MirroringService.onCaptureEnded()
        }

        private fun handleConfigBuffer(codec: MediaCodec, buffer: ByteBuffer, info: MediaCodec.BufferInfo) {
            if (sentConfig) return
            val format = codec.outputFormat
            sendConfig(format)
        }

        private fun sendConfig(format: MediaFormat) {
            if (sentConfig) return
            sentConfig = true
            val csd0 = format.getByteBuffer("csd-0")?.let { bufferToArray(it) } ?: ByteArray(0)
            val csd1 = format.getByteBuffer("csd-1")?.let { bufferToArray(it) } ?: ByteArray(0)
            val config = MirrorProtocol.MirrorConfig(
                width = width,
                height = height,
                fps = DEFAULT_FPS,
                bitrateBps = DEFAULT_BITRATE_BPS,
                sps = csd0,
                pps = csd1
            )
            onConfig(config)
        }
    }

    private fun bufferToArray(buffer: ByteBuffer): ByteArray {
        val duplicate = buffer.duplicate()
        val array = ByteArray(duplicate.remaining())
        duplicate.get(array)
        return array
    }

    companion object {
        private const val TAG = "ScreenCaptureEncoder"
        private const val DEFAULT_FPS = 30
        private const val DEFAULT_BITRATE_BPS = 4_000_000
    }
}
