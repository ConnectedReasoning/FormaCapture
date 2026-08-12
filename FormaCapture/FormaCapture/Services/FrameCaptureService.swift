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
import os

@MainActor
final class FrameCaptureService {

    enum CaptureError: LocalizedError {
        case snapshotFailed(String)
        case pngEncodingFailed

        var errorDescription: String? {
            switch self {
            case .snapshotFailed(let detail): return "Snapshot failed: \(detail)"
            case .pngEncodingFailed: return "Failed to encode snapshot as PNG"
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
}

// ── Next step, once this is confirmed correct ────────────────────────────────
// takeSnapshot() renders to an NSImage via a full compositing pass -- fine for
// a one-off "does this look right" check, too slow to call per frame for a
// real render (this is roughly the same class of cost that made the Python/
// Playwright approach slow -- see capture_fast.py's docstring, ~290ms/frame
// there was PNG encoding + protocol transfer, not rendering itself).
//
// The production path once this snapshot is confirmed pixel-correct:
// CALayer.render(in:) directly into a CVPixelBuffer-backed CGContext,
// skipping NSImage/TIFF entirely -- much faster, but needs its own
// correctness check before VideoEncodingService trusts it. Compare its
// output against a takeSnapshot() PNG of the same driven frame before
// switching over.
