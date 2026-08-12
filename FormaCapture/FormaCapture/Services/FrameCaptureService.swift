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

        var errorDescription: String? {
            switch self {
            case .snapshotFailed(let detail): return "Snapshot failed: \(detail)"
            case .pngEncodingFailed: return "Failed to encode snapshot as PNG"
            case .noLayer: return "View has no backing CALayer -- expected WKWebView to be layer-backed"
            case .invalidBounds: return "View has zero width or height, can't capture"
            case .pixelBufferCreationFailed(let status): return "CVPixelBufferCreate failed with status \(status)"
            case .contextCreationFailed: return "Failed to create CGContext backed by the pixel buffer"
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

    // MARK: - Fast path (candidate, not yet trusted)

    /// Renders `view`'s CALayer directly into a CVPixelBuffer-backed
    /// CGContext, skipping NSImage/TIFF entirely. This is the production
    /// capture path IF it proves correct -- layer.render(in:) is a general
    /// AppKit mechanism not specifically designed around WKWebView's internal
    /// GPU compositing, and has known gaps with GPU-composited content in
    /// some cases. Compare its output against captureSnapshot()'s
    /// already-proven-correct output of the same frame before trusting this
    /// for the real encoder.
    ///
    /// Captures at the view's actual backing pixel resolution (accounting
    /// for Retina scale), matching what takeSnapshot() naturally returns --
    /// without this, a 640x360-point view on a 2x display would capture at
    /// 640x360 pixels here but ~1280x720 from takeSnapshot(), which is
    /// exactly the size mismatch that blocked the first comparison run.
    func capturePixelBuffer(from view: NSView) throws -> CVPixelBuffer {
        guard view.bounds.width > 0, view.bounds.height > 0 else {
            throw CaptureError.invalidBounds
        }
        guard let layer = view.layer else {
            throw CaptureError.noLayer
        }

        let scale = view.window?.backingScaleFactor ?? layer.contentsScale
        let width = Int(view.bounds.width * scale)
        let height = Int(view.bounds.height * scale)
        guard width > 0, height > 0 else {
            throw CaptureError.invalidBounds
        }
        AppLog.capture.info("capturePixelBuffer: bounds=\(String(describing: view.bounds)) scale=\(scale) -> \(width)x\(height)")

        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                          kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw CaptureError.pixelBufferCreationFailed(status)
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw CaptureError.contextCreationFailed
        }

        // Fill with a distinct color first, in raw device-space coordinates
        // (before any transform is applied) -- if layer.render(in:) below
        // draws nothing at all, this diagnostic magenta will show through
        // instead of an ambiguous black, which could otherwise mean either
        // "nothing drew" or "something drew, intentionally black."
        context.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Single combined transform: flip vertically (AppKit's bottom-left
        // origin -> CGContext's top-left) AND scale up to backing pixel
        // resolution, in one step. Deliberately not three separate
        // translateBy/scaleBy calls -- composing those correctly by hand,
        // without being able to run this myself to check, is exactly the
        // kind of thing that's easy to get subtly wrong. One call is less
        // to get wrong.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)

        layer.render(in: context)

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
}

// ── Status ────────────────────────────────────────────────────────────────
// Two capture paths now exist:
//   captureSnapshot()    -- takeSnapshot(), confirmed pixel-correct, slow
//   capturePixelBuffer() -- CALayer.render(in:), fast, NOT YET TRUSTED
//
// Before switching VideoEncodingService over to capturePixelBuffer(), compare
// its output against captureSnapshot()'s output of the SAME driven frame --
// both visually (do they look identical) and via meanAbsoluteDifference()
// (do the numbers back that up). Only trust the fast path once both agree.
