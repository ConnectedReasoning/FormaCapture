//
//  VideoEncodingService.swift
//  FormaCapture
//
//  Wraps AVAssetWriter + VideoToolbox hardware HEVC encoding. Takes the
//  CVPixelBuffers FrameCaptureService produces (validated pixel-correct
//  against takeSnapshot() -- see FrameCaptureService's comparison test,
//  mean abs diff 0.18/255) and writes them to an MP4 file, one frame at a
//  time, at a fixed output frame rate.
//
//  Frames are supplied by the caller in order via appendFrame(_:) -- this
//  service doesn't drive the animation or do any capture itself, it only
//  encodes whatever CVPixelBuffer it's handed. This is deliberately the
//  last piece of the pipeline to exist: render/drive and capture were each
//  validated independently first (same "one layer at a time" approach as
//  the original Python scripts' sanity checks).
//
//  Quality/bitrate settings are left at VideoToolbox's defaults for now --
//  an open, deliberately deferred decision, not a silent one. Revisit via
//  AVVideoCompressionPropertiesKey once there's a real render to judge
//  quality against.
//

import Foundation
import AVFoundation
import CoreVideo
import os

@MainActor
final class VideoEncodingService {

    enum EncodingError: LocalizedError {
        case writerCreationFailed(String)
        case writerNotReady
        case appendFailed(String)
        case finishFailed(String)
        case alreadyFinished
        case notStarted

        var errorDescription: String? {
            switch self {
            case .writerCreationFailed(let detail): return "Failed to create AVAssetWriter: \(detail)"
            case .writerNotReady: return "AVAssetWriter input never became ready to accept more data (timed out after 10s)"
            case .appendFailed(let detail): return "Failed to append pixel buffer: \(detail)"
            case .finishFailed(let detail): return "Failed to finish writing: \(detail)"
            case .alreadyFinished: return "This encoding session has already finished -- call start() again for a new one"
            case .notStarted: return "start() must be called before appendFrame(_:) or finish()"
            }
        }
    }

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var frameRate: Double = 60
    private var nextFrameIndex: Int64 = 0
    private var isFinished = false

    var framesWritten: Int64 { nextFrameIndex }

    /// Begins a new encoding session. Call once before any appendFrame(_:)
    /// calls. width/height must match the pixel buffers you'll append --
    /// FrameCaptureService.capturePixelBuffer(from:) derives its dimensions
    /// from the view's actual backing pixel size, so read those same
    /// dimensions and pass them here rather than assuming a fixed value.
    func start(outputURL: URL, width: Int, height: Int, frameRate: Double) throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw EncodingError.writerCreationFailed(error.localizedDescription)
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        // false because frames arrive as fast as we can drive/capture them
        // (a tight synchronous loop), not from a live real-time source.
        input.expectsMediaDataInRealTime = false

        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )

        guard writer.canAdd(input) else {
            throw EncodingError.writerCreationFailed("writer refused the video input (unsupported settings for \(width)x\(height)?)")
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw EncodingError.writerCreationFailed(writer.error?.localizedDescription ?? "startWriting() returned false")
        }
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        self.frameRate = frameRate
        self.nextFrameIndex = 0
        self.isFinished = false

        AppLog.encode.info("Started encoding session: \(outputURL.path), \(width)x\(height) @ \(frameRate)fps, HEVC")
    }

    /// Appends one frame. Frames must be appended in order -- the
    /// presentation timestamp is derived from how many frames have been
    /// appended so far (frame i lands at i/frameRate seconds), not passed
    /// in explicitly. Skipping or reordering frames would desync timing.
    func appendFrame(_ pixelBuffer: CVPixelBuffer) async throws {
        guard let input, let adaptor, let writer else {
            throw EncodingError.notStarted
        }
        guard !isFinished else {
            throw EncodingError.alreadyFinished
        }
        guard writer.status == .writing else {
            throw EncodingError.appendFailed(
                "writer.status=\(writer.status.rawValue) error=\(writer.error?.localizedDescription ?? "none")"
            )
        }

        // Poll rather than use requestMediaDataWhenReady -- that callback
        // API is designed for a continuous live-capture producer thread.
        // This is a synchronous loop (capture one frame, append, repeat),
        // so waiting here for the input to catch up if the encoder falls
        // behind is the correct shape for this use case.
        var waitedIterations = 0
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 5_000_000)  // 5ms
            waitedIterations += 1
            if waitedIterations > 2000 {  // ~10 seconds
                throw EncodingError.writerNotReady
            }
        }

        let presentationTime = CMTime(value: nextFrameIndex, timescale: CMTimeScale(frameRate))
        guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
            throw EncodingError.appendFailed(writer.error?.localizedDescription ?? "adaptor.append returned false")
        }
        nextFrameIndex += 1
    }

    /// Finalizes the file. Call once after all frames are appended.
    func finish() async throws {
        guard let input, let writer else {
            throw EncodingError.notStarted
        }
        guard !isFinished else { return }

        input.markAsFinished()
        await writer.finishWriting()

        guard writer.status == .completed else {
            throw EncodingError.finishFailed(
                writer.error?.localizedDescription ?? "writer.status=\(writer.status.rawValue)"
            )
        }

        isFinished = true
        AppLog.encode.info("Finished encoding: \(self.nextFrameIndex) frames written")
    }
}
