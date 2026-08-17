//
//  FrameCaptureService.swift
//  FormaCapture
//
//  Grabs a single visual snapshot of a WKWebView and can save it as PNG for
//  visual inspection during development.
//
//  Uses WKWebView.takeSnapshot(), Apple's own purpose-built API for this,
//  rather than manually rendering the view's CALayer. layer.render(in:) is
//  a general AppKit mechanism not specifically designed around WKWebView's
//  internal GPU compositing, and has known gaps capturing certain kinds of
//  WebKit-rendered content correctly. takeSnapshot() is slower -- it's not
//  the path a real-time video encoder would want -- but far more likely to
//  just be correct on the first try, which is the actual goal of this step.
//  Performance comes later, once correctness is proven; see the note at the
//  bottom of this file for what changes when that's next.
//

import Foundation
import WebKit
import AppKit
import CoreVideo
import CoreImage
import CoreGraphics
import Metal
import QuartzCore
import os

@MainActor
final class FrameCaptureService {

    enum CaptureError: LocalizedError {
        case snapshotFailed(String)
        case pngEncodingFailed
        case noLayer
        case invalidBounds
        case pixelBufferCreationFailed(CVReturn)
        case contextCreationFailed
        case metalDeviceUnavailable
        case textureCacheCreationFailed(CVReturn)
        case metalTextureCreationFailed(CVReturn)

        var errorDescription: String? {
            switch self {
            case .snapshotFailed(let detail): return "Snapshot failed: \(detail)"
            case .pngEncodingFailed: return "Failed to encode snapshot as PNG"
            case .noLayer: return "View has no backing CALayer -- expected WKWebView to be layer-backed"
            case .invalidBounds: return "View has zero width or height, can't capture"
            case .pixelBufferCreationFailed(let status): return "CVPixelBufferCreate failed with status \(status)"
            case .contextCreationFailed: return "Failed to create CGContext backed by the pixel buffer"
            case .metalDeviceUnavailable: return "MTLCreateSystemDefaultDevice() returned nil -- no GPU available?"
            case .textureCacheCreationFailed(let status): return "CVMetalTextureCacheCreate failed with status \(status)"
            case .metalTextureCreationFailed(let status): return "CVMetalTextureCacheCreateTextureFromImage failed with status \(status)"
            }
        }
    }

    /// Captures the current visual state of `webView` as an NSImage.
    func captureSnapshot(of webView: WKWebView) async throws -> NSImage {
        try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, error in
                if let error {
                    continuation.resume(throwing: CaptureError.snapshotFailed(error.localizedDescription))
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: CaptureError.snapshotFailed("no image and no error returned"))
                }
            }
        }
    }

    /// Convenience for visual verification during development: capture and
    /// write straight to a PNG file.
    @discardableResult
    func captureSnapshotAndSavePNG(of webView: WKWebView, to url: URL) async throws -> NSImage {
        let image = try await captureSnapshot(of: webView)
        try save(image, to: url)
        return image
    }

    private func save(_ image: NSImage, to url: URL) throws {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw CaptureError.pngEncodingFailed
        }
        try pngData.write(to: url)
        AppLog.capture.info("Saved snapshot to \(url.path)")
    }

    // MARK: - Fast path (validated, now optimized)

    // Cached rather than recreated every call -- CGColorSpaceCreateDeviceRGB()
    // is immutable and cheap to reuse.
    private static let deviceRGB = CGColorSpaceCreateDeviceRGB()

    /// Renders `view`'s CALayer directly into a CVPixelBuffer-backed
    /// CGContext, skipping NSImage/TIFF entirely. This is the production
    /// capture path -- validated correct via meanAbsoluteDifference (0.18/255
    /// against captureSnapshot()'s takeSnapshot()-based baseline).
    ///
    /// Split into allocation (below) and drawing (this method) so a hot
    /// render loop can draw into a buffer pulled from
    /// VideoEncodingService's pixelBufferPool instead of allocating a fresh
    /// ~33MB buffer every single frame -- that repeated allocation was
    /// confirmed as dead weight in the render loop, not hypothetical.
    ///
    /// The buffer's own dimensions are used for the CGContext (not
    /// recomputed from view.bounds*scale), so this works correctly whether
    /// `buffer` came from allocateStandaloneBuffer(for:) below or from an
    /// external pool with its own exact sizing.
    func render(_ view: NSView, into buffer: CVPixelBuffer) throws {
        guard let layer = view.layer else {
            throw CaptureError.noLayer
        }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else {
            throw CaptureError.invalidBounds
        }

        let scale = view.window?.backingScaleFactor ?? layer.contentsScale

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: Self.deviceRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw CaptureError.contextCreationFailed
        }

        // Single combined transform: flip vertically (AppKit's bottom-left
        // origin -> CGContext's top-left) AND scale up to backing pixel
        // resolution, in one step. Deliberately not three separate
        // translateBy/scaleBy calls -- composing those correctly by hand,
        // without being able to run this myself to check, is exactly the
        // kind of thing that's easy to get subtly wrong. One call is less
        // to get wrong. (This is the fix for the black-frame regression
        // from earlier -- the diagnostic magenta fill that caught that bug
        // has been removed now that it's resolved and confirmed correct.)
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)

        layer.render(in: context)
    }

    /// Allocates a standalone (non-pooled) buffer -- used by the one-off
    /// test/comparison call sites below, which don't run in a hot loop and
    /// so don't need pooling. The render loop in practice should prefer a
    /// buffer from VideoEncodingService's pixelBufferPool instead, drawn
    /// into via render(_:into:) directly.
    func allocateStandaloneBuffer(for view: NSView) throws -> CVPixelBuffer {
        guard view.bounds.width > 0, view.bounds.height > 0 else {
            throw CaptureError.invalidBounds
        }
        let scale = view.window?.backingScaleFactor ?? view.layer?.contentsScale ?? 2.0
        let width = Int(view.bounds.width * scale)
        let height = Int(view.bounds.height * scale)
        guard width > 0, height > 0 else {
            throw CaptureError.invalidBounds
        }

        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            // IOSurface-backed even for the standalone/one-off path -- costs
            // nothing extra and keeps this path consistent with what the
            // pooled buffers use.
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                          kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw CaptureError.pixelBufferCreationFailed(status)
        }
        return buffer
    }

    /// Convenience combining the two steps above, for one-off calls
    /// (captureTestFrame, compareCaptureMethods) that don't need pooling.
    func capturePixelBuffer(from view: NSView) throws -> CVPixelBuffer {
        let buffer = try allocateStandaloneBuffer(for: view)
        try render(view, into: buffer)
        return buffer
    }

    /// Converts a captured pixel buffer to an NSImage, for display/comparison
    /// or for the PNG-saving convenience below.
    func image(from pixelBuffer: CVPixelBuffer) -> NSImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let ciContext = CIContext()
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Same convenience as captureSnapshotAndSavePNG, for the pixel buffer path.
    @discardableResult
    func savePixelBufferPNG(_ pixelBuffer: CVPixelBuffer, to url: URL) throws -> NSImage {
        guard let image = image(from: pixelBuffer) else {
            throw CaptureError.pngEncodingFailed
        }
        try save(image, to: url)
        return image
    }

    // MARK: - Comparison

    /// Rough quantitative comparison between two same-size images: mean
    /// absolute per-channel difference, on a 0-255 scale. Returns nil if the
    /// two images aren't the same pixel dimensions (comparing them directly
    /// wouldn't mean anything).
    ///
    /// This is a SECOND data point, not the verdict -- the two capture paths
    /// could differ slightly in color space handling or scaling in ways that
    /// show up here without meaning the actual rendered content is wrong.
    /// Look at both images before trusting a number here.
    func meanAbsoluteDifference(_ imageA: NSImage, _ imageB: NSImage) -> Double? {
        guard let cgA = imageA.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let cgB = imageB.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cgA.width == cgB.width, cgA.height == cgB.height,
              cgA.width > 0, cgA.height > 0 else {
            return nil
        }

        let width = cgA.width, height = cgA.height
        let bytesPerRow = width * 4
        var dataA = [UInt8](repeating: 0, count: height * bytesPerRow)
        var dataB = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let contextA = CGContext(data: &dataA, width: width, height: height, bitsPerComponent: 8,
                                        bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo),
              let contextB = CGContext(data: &dataB, width: width, height: height, bitsPerComponent: 8,
                                        bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo) else {
            return nil
        }

        contextA.draw(cgA, in: CGRect(x: 0, y: 0, width: width, height: height))
        contextB.draw(cgB, in: CGRect(x: 0, y: 0, width: width, height: height))

        var totalDiff: Int64 = 0
        for i in 0..<dataA.count {
            totalDiff += Int64(abs(Int(dataA[i]) - Int(dataB[i])))
        }
        return Double(totalDiff) / Double(dataA.count)
    }

    // MARK: - GPU-native path (EXPERIMENTAL, UNVERIFIED)

    private var metalDevice: MTLDevice?
    private var textureCache: CVMetalTextureCache?

    private func ensureMetalSetup() throws -> CVMetalTextureCache {
        if let textureCache { return textureCache }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw CaptureError.metalDeviceUnavailable
        }
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else {
            throw CaptureError.textureCacheCreationFailed(status)
        }
        self.metalDevice = device
        self.textureCache = cache
        return cache
    }

    /// Allocates a buffer with BOTH IOSurface and Metal compatibility --
    /// the render-loop pool (VideoEncodingService.newPooledPixelBuffer())
    /// doesn't request Metal compatibility yet, so this experiment uses its
    /// own standalone buffer rather than touching the already-working pool
    /// before this path is validated.
    func allocateMetalCompatibleBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                          kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw CaptureError.pixelBufferCreationFailed(status)
        }
        return buffer
    }

    /// EXPERIMENTAL, UNVERIFIED, ATTEMPT #2: same as before, but now also
    /// (a) forces a CATransaction flush before rendering, on the theory
    /// that CARenderer might only see whatever was last committed through
    /// the normal on-screen pipeline, and (b) prefers the presentation
    /// layer (the actual currently-displayed state) over the model layer,
    /// falling back to the model layer if no animation is in flight
    /// (presentation() is nil outside of active transactions).
    ///
    /// This tests a DIFFERENT failure mode than attempt #1's result ruled
    /// out. Attempt #1 came back at 63.83/255 diff against the CALayer
    /// baseline -- essentially blank. Two distinct explanations for that,
    /// and this only fixes one of them:
    ///   A) Stale/uncommitted content -- CARenderer saw the layer at a
    ///      moment before WKWebView's latest frame had been committed.
    ///      This attempt's flush + presentation() targets exactly this.
    ///   B) CARenderer structurally can't reach WKWebView's content at
    ///      all, because webView.layer is likely a remote layer HOST
    ///      (a reference to content actually living in the separate
    ///      WebContent process, bridged in via a private, XPC-connected
    ///      mechanism) rather than a layer with its own drawable content.
    ///      layer.render(in:) may have special-cased support for that
    ///      bridge; CARenderer's manual compositing walk might not.
    ///      If this is the real cause, nothing in this attempt fixes it --
    ///      it's architectural, not a timing bug.
    ///
    /// If this STILL comes back blank/significantly different, that's
    /// meaningful evidence for (B), not a reason to try a third timing
    /// variant.
    func renderViaGPU(_ view: NSView, into buffer: CVPixelBuffer) throws {
        guard let modelLayer = view.layer else {
            throw CaptureError.noLayer
        }

        CATransaction.flush()
        let layer = modelLayer.presentation() ?? modelLayer

        let cache = try ensureMetalSetup()

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, buffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture,
              let mtlTexture = CVMetalTextureGetTexture(cvTexture) else {
            throw CaptureError.metalTextureCreationFailed(status)
        }

        let renderer = CARenderer(mtlTexture: mtlTexture, options: nil)
        renderer.layer = layer
        renderer.bounds = layer.bounds

        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.render()
        renderer.endFrame()
    }
}

// ── Status ────────────────────────────────────────────────────────────────
// Three capture paths now exist:
//   captureSnapshot()    -- takeSnapshot(), proven correct, slow (reference)
//   capturePixelBuffer() -- CALayer.render(in:), PROVEN correct (0.18/255
//                           diff vs takeSnapshot()), current production
//                           path, ~81ms/frame at 4K
//   renderViaGPU()        -- CARenderer/Metal, UNVERIFIED, candidate to
//                           replace capturePixelBuffer() if it's both
//                           correct AND faster
//
// Validate renderViaGPU() against capturePixelBuffer() (now the trusted
// baseline) the same way capturePixelBuffer() was validated against
// takeSnapshot(): single-frame capture, meanAbsoluteDifference, look at
// both images. Only wire into the render loop once that agrees.
