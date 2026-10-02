package com.diego.pocketlink.protocol

import org.json.JSONObject
import java.util.Base64
import java.nio.ByteBuffer

/**
 * Wire helpers for screen mirroring (B3).
 *
 * MIRROR_FRAME binary payload layout (big-endian, matching the frame header
 * convention): `u64 timestampMs | u8 keyframe | u32 accessUnitLength | bytes`.
 */
object MirrorProtocol {
    const val ACTION_DOWN = "down"
    const val ACTION_MOVE = "move"
    const val ACTION_UP = "up"

    data class EncodedMirrorFrame(
        val timestampMs: Long,
        val keyframe: Boolean,
        val accessUnit: ByteArray
    )

    fun encodeFramePayload(timestampMs: Long, keyframe: Boolean, accessUnit: ByteArray): ByteArray {
        val buffer = ByteBuffer.allocate(13 + accessUnit.size)
        buffer.putLong(timestampMs)
        buffer.put(if (keyframe) 1 else 0)
        buffer.putInt(accessUnit.size)
        buffer.put(accessUnit)
        return buffer.array()
    }

    fun decodeFramePayload(payload: ByteArray): EncodedMirrorFrame? {
        if (payload.size < 13) return null
        val buffer = ByteBuffer.wrap(payload)
        val timestampMs = buffer.long
        val keyframe = buffer.get().toInt() == 1
        val length = buffer.int
        if (length < 0 || 13 + length > payload.size) return null
        val accessUnit = ByteArray(length)
        buffer.get(accessUnit)
        return EncodedMirrorFrame(timestampMs, keyframe, accessUnit)
    }

    data class MirrorConfig(
        val width: Int,
        val height: Int,
        val fps: Int,
        val bitrateBps: Int,
        /** CSD blobs in Annex-B form; [sps] may contain SPS+PPS concatenated (csd-0). */
        val sps: ByteArray,
        val pps: ByteArray
    )

    fun encodeConfigJson(config: MirrorConfig): String {
        return JSONObject().apply {
            put("width", config.width)
            put("height", config.height)
            put("fps", config.fps)
            put("bitrateBps", config.bitrateBps)
            put("sps", Base64.getEncoder().encodeToString(config.sps))
            put("pps", Base64.getEncoder().encodeToString(config.pps))
        }.toString()
    }

    fun parseConfigJson(json: JSONObject): MirrorConfig? {
        val width = json.optInt("width", 0)
        val height = json.optInt("height", 0)
        if (width <= 0 || height <= 0) return null
        return MirrorConfig(
            width = width,
            height = height,
            fps = json.optInt("fps", 30),
            bitrateBps = json.optInt("bitrateBps", 4_000_000),
            sps = Base64.getDecoder().decode(json.optString("sps", "")),
            pps = Base64.getDecoder().decode(json.optString("pps", ""))
        )
    }

    fun encodeTouchJson(action: String, x: Double, y: Double): String {
        return JSONObject().apply {
            put("action", action)
            put("x", x)
            put("y", y)
        }.toString()
    }

    data class TouchPoint(val action: String, val x: Double, val y: Double)

    fun parseTouchJson(json: JSONObject): TouchPoint? {
        val action = json.optString("action")
        if (action != ACTION_DOWN && action != ACTION_MOVE && action != ACTION_UP) return null
        if (!json.has("x") || !json.has("y")) return null
        return TouchPoint(action = action, x = json.getDouble("x"), y = json.getDouble("y"))
    }
}
