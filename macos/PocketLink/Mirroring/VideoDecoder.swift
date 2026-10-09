import AVFoundation
import AppKit
import CoreMedia
import Foundation
import os

/// Decodes the phone's H.264 Annex-B stream and renders it into an
/// `AVSampleBufferDisplayLayer`.
///
/// MediaCodec emits Annex-B byte streams; AVSampleBufferDisplayLayer needs
/// AVCC (length-prefixed NAL units) plus a `CMVideoFormatDescription` built
/// from the SPS/PPS carried by MIRROR_CONFIG.
final class VideoDecoder {

    enum DecodeError: Error {
        case missingParameterSets
        case invalidFormatDescription
    }

    private static let log = Logger(subsystem: "com.diego.pocketlink", category: "video-decoder")

    private let layer = AVSampleBufferDisplayLayer()

    private var formatDescription: CMVideoFormatDescription?
    private var lastPresentedPTS: CMTime = .invalid
    private var decodedFrames = 0
    private var droppedFrames = 0
    /// Set after a decode-layer failure or a reconfiguration: delta frames
    /// reference a keyframe that is no longer queued, so they must be dropped
    /// until the next sync frame arrives (MediaCodec emits one every second).
    private var waitingForSyncFrame = true

    /// The layer hosting the decoded video. Install into a view once.
    var displayLayer: AVSampleBufferDisplayLayer { layer }

    /// Called with every ready AVCC sample buffer (before it is enqueued
    /// into the display layer) — used by the session recorder.
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    /// The active H.264 format description, or nil before the first config.
    var currentFormatDescription: CMVideoFormatDescription? { formatDescription }

    var dimensions: CGSize {
        guard let format = formatDescription else { return .zero }
        let d = CMVideoFormatDescriptionGetDimensions(format)
        return CGSize(width: CGFloat(d.width), height: CGFloat(d.height))
    }

    var stats: (decoded: Int, dropped: Int) {
        (decodedFrames, droppedFrames)
    }

    /// Builds the format description from parameter sets and resets the layer.
    func configure(width: Int, height: Int, sps: Data, pps: Data) throws {
        // csd-0 may contain SPS+PPS concatenated; split them out.
        let nalUnits = AnnexBNALParser.nalUnits(in: sps + pps)
        guard let spsUnit = nalUnits.first(where: { AnnexBNALParser.type(of: $0) == 7 }),
              let ppsUnit = nalUnits.first(where: { AnnexBNALParser.type(of: $0) == 8 }) else {
            throw DecodeError.missingParameterSets
        }

        guard !spsUnit.isEmpty, !ppsUnit.isEmpty else {
            throw DecodeError.invalidFormatDescription
        }
        try spsUnit.withUnsafeBytes { spsRaw in
            try ppsUnit.withUnsafeBytes { ppsRaw in
                guard let spsPtr = spsRaw.bindMemory(to: UInt8.self).baseAddress,
                      let ppsPtr = ppsRaw.bindMemory(to: UInt8.self).baseAddress else {
                    throw DecodeError.invalidFormatDescription
                }
                var pointers: [UnsafePointer<UInt8>] = [spsPtr, ppsPtr]
                var sizes = [spsUnit.count, ppsUnit.count]
                var newFormat: CMVideoFormatDescription?
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil,
                    parameterSetCount: 2,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &newFormat
                )
                guard status == noErr, let format = newFormat else {
                    throw DecodeError.invalidFormatDescription
                }
                formatDescription = format
            }
        }

        lastPresentedPTS = .invalid
        decodedFrames = 0
        droppedFrames = 0
        waitingForSyncFrame = true
        layer.flush()
    }

    /// Decodes one Annex-B access unit. Late frames are dropped.
    func decode(timestampMs: Int64, keyframe: Bool, accessUnit: Data) {
        guard let format = formatDescription else {
            droppedFrames += 1
            return
        }

        let pts = CMTime(value: CMTimeValue(timestampMs), timescale: 1000)
        if lastPresentedPTS.isValid && pts < lastPresentedPTS {
            droppedFrames += 1
            return
        }

        // Delta frames are useless without their reference frame (e.g. after
        // a layer flush) — hold decode until the next sync frame.
        if waitingForSyncFrame && !keyframe {
            droppedFrames += 1
            return
        }
        waitingForSyncFrame = false

        let avccData = AnnexBNALParser.avccData(fromAnnexB: accessUnit)
        guard !avccData.isEmpty,
              let blockBuffer = try? avccData.toBlockBuffer() else {
            droppedFrames += 1
            return
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = CMBlockBufferGetDataLength(blockBuffer)
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: nil,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let buffer = sampleBuffer else {
            droppedFrames += 1
            return
        }

        // The phone's timestamps are uptime-based (huge values). Mark each
        // sample DisplayImmediately so the layer renders it on arrival
        // instead of waiting for its control timebase to reach the PTS.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0),
                to: CFMutableDictionary.self
            )
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        layer.enqueue(buffer)
        // enqueue is asynchronous and non-throwing; decode errors surface
        // through the layer status afterwards. Flush and re-sync on the next
        // keyframe instead of feeding deltas against a broken reference.
        if layer.status == .failed {
            Self.log.error("Display layer failed: \(self.layer.error?.localizedDescription ?? "unknown error", privacy: .public)")
            droppedFrames += 1
            layer.flush()
            waitingForSyncFrame = true
            return
        }
        lastPresentedPTS = pts
        decodedFrames += 1
        onSampleBuffer?(buffer)
    }

    /// Renders the layer's most recently displayed frame to PNG data at the
    /// decoded video dimensions. Returns nil before the first frame.
    func screenshotPNG() -> Data? {
        let size = dimensions
        guard size.width >= 1, size.height >= 1,
              let context = CGContext(
                data: nil,
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        layer.render(in: context)
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    func invalidate() {
        layer.flush()
        formatDescription = nil
        lastPresentedPTS = .invalid
        decodedFrames = 0
        droppedFrames = 0
        waitingForSyncFrame = true
    }
}

/// Splits Annex-B byte streams into NAL units and converts them to AVCC.
enum AnnexBNALParser {

    /// Returns each NAL unit (start codes removed, including the NAL header byte).
    static func nalUnits(in annexB: Data) -> [Data] {
        var units: [Data] = []
        let bytes = [UInt8](annexB)
        var i = 0
        var unitStart: Int?

        func startCodeLength(at index: Int) -> Int? {
            if index + 3 < bytes.count,
               bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                return 4
            }
            if index + 2 < bytes.count,
               bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                return 3
            }
            return nil
        }

        while i < bytes.count {
            if let codeLength = startCodeLength(at: i) {
                if let start = unitStart, i > start {
                    units.append(Data(bytes[start..<i]))
                }
                i += codeLength
                unitStart = i
            } else {
                i += 1
            }
        }
        if let start = unitStart, start < bytes.count {
            units.append(Data(bytes[start...]))
        }
        return units.filter { !$0.isEmpty }
    }

    static func type(of nalUnit: Data) -> Int {
        guard let first = nalUnit.first else { return -1 }
        return Int(first & 0x1F)
    }

    /// Converts an Annex-B access unit to AVCC (4-byte length-prefixed NAL units).
    static func avccData(fromAnnexB annexB: Data) -> Data {
        var out = Data()
        for unit in nalUnits(in: annexB) {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
            out.append(unit)
        }
        return out
    }
}

private extension Data {
    func toBlockBuffer() throws -> CMBlockBuffer {
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil,
            memoryBlock: nil,
            blockLength: count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let buffer = blockBuffer else {
            throw VideoDecoder.DecodeError.invalidFormatDescription
        }
        status = withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: buffer,
                offsetIntoDestination: 0,
                dataLength: count
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw VideoDecoder.DecodeError.invalidFormatDescription
        }
        return buffer
    }
}
