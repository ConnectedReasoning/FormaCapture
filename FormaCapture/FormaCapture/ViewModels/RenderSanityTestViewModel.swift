//
//  RenderSanityTestViewModel.swift
//  FormaCapture
//
//  Drives WebRenderService through the exact same sequence capture_fast.py
//  used for its 10-second sanity check, logging expected-vs-actual
//  elapsedSeconds per frame so drift can be confirmed the same way. This is
//  scaffolding to prove WebRenderService actually works -- not the real app
//  UI (that comes once the capture/encode layers exist too).
//

import Foundation
import Combine
import WebKit
import os

@MainActor
final class RenderSanityTestViewModel: ObservableObject {
    @Published var isRunning = false
    @Published var log: String = ""
    @Published var maxDrift: Double?
    @Published var lastCapturedImage: NSImage?
    @Published var snapshotCompareImage: NSImage?
    @Published var pixelBufferCompareImage: NSImage?
    @Published var pixelDiffResult: String?

    private let renderService = WebRenderService()
    private let captureService = FrameCaptureService()
    var webView: WKWebView { renderService.webView }

    // Same defaults as capture_fast.py's sanity-test config.
    private let baseURL = URL(string: "http://127.0.0.1:8000")!
    private let animation = "loop_topology"
    private let palette = "starwars"
    private let outputFPS = 60.0
    private let durationSeconds = 10.0
    private let noiseSeed = 20260810

    func runSanityTest() async {
        isRunning = true
        log = ""
        maxDrift = nil
        defer { isRunning = false }

        do {
            append("Loading engines/p5.html from \(baseURL.absoluteString) -- make sure `python3 -m http.server 8000` is running in web/web/")
            try await renderService.load(baseURL: baseURL)

            append("Selecting animation: \(animation)")
            try await renderService.selectAnimation(animation)

            append("Selecting palette: \(palette)")
            try await renderService.selectPalette(palette)

            append("Waiting for setup...")
            try await renderService.waitForSetupDone()

            try await renderService.setNoiseSeed(noiseSeed)
            try await renderService.stopAutomaticLoop()

            let totalFrames = Int(durationSeconds * outputFPS)
            let internalStep = 60.0 / outputFPS
            var observedMaxDrift = 0.0

            append("Stepping \(totalFrames) frames at \(Int(outputFPS))fps (\(Int(durationSeconds))s of output). No capture yet -- this only proves the render/drive layer.")

            for i in 0..<totalFrames {
                let targetFrameCount = Double(i) * internalStep
                let actualFrameCount = try await renderService.stepFrame(toTargetFrameCount: targetFrameCount)

                let expectedElapsed = targetFrameCount / 60.0
                let actualElapsed = actualFrameCount / 60.0
                let drift = abs(actualElapsed - expectedElapsed)
                observedMaxDrift = max(observedMaxDrift, drift)

                if i < 5 || i % 50 == 0 {
                    append(String(format: "  frame %5d  expected=%.4f  actual=%.4f  drift=%.6f",
                                  i, expectedElapsed, actualElapsed, drift))
                }
            }

            maxDrift = observedMaxDrift
            append(observedMaxDrift < 0.000001
                   ? "Frame timing confirmed exact. If the preview above visibly showed the animation, WKWebView-in-a-window is confirmed too."
                   : "WARNING: drift detected (\(observedMaxDrift)) -- do not proceed to capture until this is understood.")

        } catch {
            append("FAILED: \(error.localizedDescription)")
            AppLog.render.error("Sanity test failed: \(error.localizedDescription)")
        }
    }

    /// Independent of runSanityTest() -- does its own full setup so it works
    /// whether or not the sanity test ran first. Steps to a specific, known
    /// frame (5 seconds in) rather than capturing "whatever's currently
    /// showing," so what you see in the saved PNG is reproducible and tied
    /// to a controlled animation state, same principle as the drift checks.
    func captureTestFrame() async {
        isRunning = true
        log = ""
        lastCapturedImage = nil
        defer { isRunning = false }

        do {
            append("Loading engines/p5.html from \(baseURL.absoluteString)...")
            try await renderService.load(baseURL: baseURL)

            append("Selecting animation: \(animation)")
            try await renderService.selectAnimation(animation)

            append("Selecting palette: \(palette)")
            try await renderService.selectPalette(palette)

            append("Waiting for setup...")
            try await renderService.waitForSetupDone()

            try await renderService.setNoiseSeed(noiseSeed)
            try await renderService.stopAutomaticLoop()

            let targetSeconds = 5.0
            let targetFrameCount = targetSeconds * 60.0
            append("Stepping to frameCount \(Int(targetFrameCount)) (\(targetSeconds)s in)...")
            let actual = try await renderService.stepFrame(toTargetFrameCount: targetFrameCount)
            append("Landed at frameCount \(actual)")

            let outputURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("formacapture_test_frame_\(Int(Date().timeIntervalSince1970)).png")

            append("Capturing snapshot...")
            let image = try await captureService.captureSnapshotAndSavePNG(of: renderService.webView, to: outputURL)
            lastCapturedImage = image

            append("Saved: \(outputURL.path)")
            NSWorkspace.shared.activateFileViewerSelecting([outputURL])

        } catch {
            append("FAILED: \(error.localizedDescription)")
            AppLog.capture.error("Frame capture test failed: \(error.localizedDescription)")
        }
    }

    /// Captures the same driven frame two ways -- takeSnapshot() (proven
    /// correct) and CALayer.render(in:) via CVPixelBuffer (candidate fast
    /// path) -- and compares them, both quantitatively and by putting both
    /// images in front of you. The number alone isn't the verdict; look at
    /// both thumbnails.
    func compareCaptureMethods() async {
        isRunning = true
        log = ""
        snapshotCompareImage = nil
        pixelBufferCompareImage = nil
        pixelDiffResult = nil
        defer { isRunning = false }

        do {
            append("Loading engines/p5.html from \(baseURL.absoluteString)...")
            try await renderService.load(baseURL: baseURL)

            append("Selecting animation: \(animation)")
            try await renderService.selectAnimation(animation)

            append("Selecting palette: \(palette)")
            try await renderService.selectPalette(palette)

            append("Waiting for setup...")
            try await renderService.waitForSetupDone()

            try await renderService.setNoiseSeed(noiseSeed)
            try await renderService.stopAutomaticLoop()

            let targetSeconds = 5.0
            let targetFrameCount = targetSeconds * 60.0
            append("Stepping to frameCount \(Int(targetFrameCount)) (\(targetSeconds)s in)...")
            _ = try await renderService.stepFrame(toTargetFrameCount: targetFrameCount)

            append("Capturing via takeSnapshot() (proven-correct baseline)...")
            let snapshotImage = try await captureService.captureSnapshot(of: renderService.webView)
            snapshotCompareImage = snapshotImage

            append("Capturing via CALayer.render(in:) -> CVPixelBuffer (candidate fast path)...")
            let pixelBuffer = try captureService.capturePixelBuffer(from: renderService.webView)
            guard let layerImage = captureService.image(from: pixelBuffer) else {
                throw FrameCaptureService.CaptureError.pngEncodingFailed
            }
            pixelBufferCompareImage = layerImage

            if let diff = captureService.meanAbsoluteDifference(snapshotImage, layerImage) {
                let verdict = diff < 2.0 ? "essentially identical"
                             : diff < 15.0 ? "close, minor differences (could be color space/scaling, not necessarily wrong)"
                             : "SIGNIFICANTLY DIFFERENT -- do not trust the fast path yet"
                let result = String(format: "Mean abs diff: %.2f / 255 -- %@", diff, verdict)
                pixelDiffResult = result
                append(result)
            } else {
                append("Could not compute a pixel diff (likely a size mismatch between the two captures). "
                       + "Compare the two thumbnails below by eye instead.")
            }

            append("Look at both images below. Same content, same colors, no blank/corruption = fast path validated.")

        } catch {
            append("FAILED: \(error.localizedDescription)")
            AppLog.capture.error("Capture comparison failed: \(error.localizedDescription)")
        }
    }

    private func append(_ line: String) {
        log += line + "\n"
        AppLog.render.info("\(line)")
    }
}
