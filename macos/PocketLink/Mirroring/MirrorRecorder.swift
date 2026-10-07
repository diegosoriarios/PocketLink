import AVFoundation
import CoreMedia
import Foundation

/// Writes the mirror session's H.264 access units (already AVCC-converted
/// by `VideoDecoder`) to an MP4 via a passthrough `AVAssetWriter`.
@MainActor
final class MirrorRecorder {
    enum RecorderError: Error {
        case notWriting
    }

    private(set) var isActive = false
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var outputURL: URL?
    private var sessionStart: CMTime = .invalid

    func start(url: URL, formatDescription: CMVideoFormatDescription) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        // outputSettings: nil → passthrough of the compressed samples
        // (re-mux only, no re-encode).
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: formatDescription
        )
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? RecorderError.notWriting
        }
        self.writer = writer
        self.input = input
        self.outputURL = url
        self.sessionStart = .invalid
        self.isActive = true
    }

    /// Appends one ready sample buffer. If the input is momentarily full the
    /// frame is dropped — consistent with the display layer's drop-late policy.
    func append(_ sampleBuffer: CMSampleBuffer) {
        guard isActive, let input, let writer, input.isReadyForMoreMediaData else { return }
        if !sessionStart.isValid {
            sessionStart = sampleBuffer.presentationTimeStamp
            writer.startSession(atSourceTime: sessionStart)
        }
        input.append(sampleBuffer)
    }

    /// Finalizes the movie; completion runs on an arbitrary queue.
    func finish(_ completion: @escaping @Sendable (URL?, Error?) -> Void) {
        guard isActive, let input, let writer, let outputURL else {
            completion(nil, RecorderError.notWriting)
            return
        }
        isActive = false
        input.markAsFinished()
        // AVAssetWriter isn't Sendable, but after finishWriting it's only
        // touched by AVFoundation's internal queue, which reads its terminal
        // status here.
        nonisolated(unsafe) let finalized = writer
        writer.finishWriting {
            if finalized.status == .completed {
                completion(outputURL, nil)
            } else {
                completion(nil, finalized.error)
            }
        }
    }
}
