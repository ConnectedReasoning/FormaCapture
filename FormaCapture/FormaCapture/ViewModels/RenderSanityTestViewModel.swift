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
    @Published var gpuDiffResult: String?
    @Published var gpuBaselineImage: NSImage?
    @Published var gpuCompareImage: NSImage?
    @Published var offscreenDiffResult: String?
    @Published var offscreenBaselineImage: NSImage?
    @Published var offscreenCandidateImage: NSImage?

    private let renderService = WebRenderService()
    private let captureService = FrameCaptureService()
    private let encodingService = VideoEncodingService()
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

    /// Now uses OffscreenRenderWindow instead of the visible dev preview --
    /// validated separately via compareOffscreenCapture() (0.00/255 diff,
    /// the cleanest result this project has produced). This is the actual
    /// "invisible render" path: nothing appears on screen, only this log
    /// and the final MP4.
    ///
    /// Duration deliberately still at 10s -- "off-screen in the real render
    /// loop" is itself a new variable (different from the isolated single-
    /// frame test), worth confirming on its own before combining it with a
    /// longer duration again. Once this passes, bump clipSeconds back up
    /// for a real timing projection at full 4K.
    func renderTestClip() async {
        isRunning = true
        log = ""
        defer { isRunning = false }

        var offscreen: OffscreenRenderWindow?
        defer { offscreen?.close() }

        do {
            append("Creating off-screen render window (invisible, real window)...")
            let offscreenWindow = OffscreenRenderWindow(width: 1920, height: 1080)
            offscreen = offscreenWindow
            let offscreenService = WebRenderService(externalWebView: offscreenWindow.webView)
            let webView = offscreenWindow.webView

            append("Loading engines/p5.html from \(baseURL.absoluteString)...")
            try await offscreenService.load(baseURL: baseURL)

            append("Selecting animation: \(animation)")
            try await offscreenService.selectAnimation(animation)

            append("Selecting palette: \(palette)")
            try await offscreenService.selectPalette(palette)

            append("Waiting for setup...")
            try await offscreenService.waitForSetupDone()

            try await offscreenService.setNoiseSeed(noiseSeed)
            try await offscreenService.stopAutomaticLoop()

            let clipSeconds = 10.0  // still 10s -- off-screen-in-the-render-loop is the new variable this run
            let clipFPS = 60.0
            let totalFrames = Int(clipSeconds * clipFPS)
            let internalStep = 60.0 / clipFPS

            let scale = webView.window?.backingScaleFactor ?? webView.layer?.contentsScale ?? 2.0
            let width = Int(webView.bounds.width * scale)
            let height = Int(webView.bounds.height * scale)

            let outputURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("formacapture_test_clip_\(Int(Date().timeIntervalSince1970)).mp4")

            append("Starting encoder: \(width)x\(height) @ \(Int(clipFPS))fps HEVC -> \(outputURL.lastPathComponent)")
            append("(off-screen -- nothing should appear on screen during this render)")
            try encodingService.start(outputURL: outputURL, width: width, height: height, frameRate: clipFPS)

            append("Rendering \(totalFrames) frames (\(Int(clipSeconds))s)...")

            var totalDriveTime = 0.0
            var totalCaptureTime = 0.0
            var totalEncodeTime = 0.0
            let wallStart = Date()

            for i in 0..<totalFrames {
                let targetFrameCount = Double(i) * internalStep

                let t0 = Date()
                _ = try await offscreenService.stepFrame(toTargetFrameCount: targetFrameCount)
                let t1 = Date()

                // Pooled buffer instead of a fresh ~33MB allocation every
                // frame -- see FrameCaptureService/VideoEncodingService for
                // why this changed. Same render(_:into:) call underneath,
                // just drawing into reused, IOSurface-backed memory instead
                // of a throwaway buffer.
                let pixelBuffer = try encodingService.newPooledPixelBuffer()
                try captureService.render(webView, into: pixelBuffer)
                let t2 = Date()

                try await encodingService.appendFrame(pixelBuffer)
                let t3 = Date()

                totalDriveTime += t1.timeIntervalSince(t0)
                totalCaptureTime += t2.timeIntervalSince(t1)
                totalEncodeTime += t3.timeIntervalSince(t2)

                if i % 300 == 0 {  // every 5s of output
                    append("  frame \(i)/\(totalFrames)")
                }
            }

            let wallElapsed = Date().timeIntervalSince(wallStart)

            append("Finishing...")
            try await encodingService.finish()
            append("Done: \(outputURL.path)")

            append("")
            append("Timing breakdown over \(totalFrames) frames:")
            append(String(format: "  drive (frameCount/redraw):  %.2fs total, %.1fms/frame",
                           totalDriveTime, 1000 * totalDriveTime / Double(totalFrames)))
            append(String(format: "  capture (CALayer->buffer):  %.2fs total, %.1fms/frame",
                           totalCaptureTime, 1000 * totalCaptureTime / Double(totalFrames)))
            append(String(format: "  encode (append to writer):  %.2fs total, %.1fms/frame",
                           totalEncodeTime, 1000 * totalEncodeTime / Double(totalFrames)))
            append(String(format: "  wall-clock: %.2fs for %.0fs of output (%.2fx realtime)",
                           wallElapsed, clipSeconds, clipSeconds / wallElapsed))
            let projectedMinutes = wallElapsed * (3600.0 / clipSeconds) / 60.0
            append(String(format: "  projected full 60-min render at this rate: %.1f minutes (at full 4K)",
                           projectedMinutes))

            NSWorkspace.shared.activateFileViewerSelecting([outputURL])

        } catch {
            append("FAILED: \(error.localizedDescription)")
            AppLog.encode.error("Render test clip failed: \(error.localizedDescription)")
        }
    }

    /// Validates the experimental GPU-native (CARenderer/Metal) capture
    /// path against the PROVEN CALayer.render(in:) baseline -- same
    /// discipline as the original takeSnapshot()-vs-CALayer validation.
    /// Single frame, both quantitative diff and visual comparison. Does
    /// NOT touch the render loop -- this only answers "is this correct,"
    /// not "is this fast," and definitely not both at once.
    func compareGPUCaptureMethod() async {
        isRunning = true
        log = ""
        gpuDiffResult = nil
        gpuCompareImage = nil
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

            let webView = renderService.webView
            let scale = webView.window?.backingScaleFactor ?? webView.layer?.contentsScale ?? 2.0
            let width = Int(webView.bounds.width * scale)
            let height = Int(webView.bounds.height * scale)

            append("Capturing via CALayer.render(in:) (proven baseline)...")
            let baselineBuffer = try captureService.capturePixelBuffer(from: webView)
            guard let baselineImage = captureService.image(from: baselineBuffer) else {
                throw FrameCaptureService.CaptureError.pngEncodingFailed
            }
            gpuBaselineImage = baselineImage

            append("Capturing via CARenderer/Metal (experimental GPU path)...")
            let gpuBuffer = try captureService.allocateMetalCompatibleBuffer(width: width, height: height)
            try captureService.renderViaGPU(webView, into: gpuBuffer)
            guard let gpuImage = captureService.image(from: gpuBuffer) else {
                throw FrameCaptureService.CaptureError.pngEncodingFailed
            }
            gpuCompareImage = gpuImage

            if let diff = captureService.meanAbsoluteDifference(baselineImage, gpuImage) {
                let verdict = diff < 2.0 ? "essentially identical -- GPU path looks correct"
                             : diff < 15.0 ? "close, minor differences (could be color space, not necessarily wrong)"
                             : "SIGNIFICANTLY DIFFERENT -- do not trust the GPU path yet"
                let result = String(format: "Mean abs diff: %.2f / 255 -- %@", diff, verdict)
                gpuDiffResult = result
                append(result)
            } else {
                append("Could not compute a pixel diff (size mismatch). Compare the two images by eye instead.")
            }

            append("Look at both images below. Same content = GPU path validated. Blank/garbled = it does not correctly capture WKWebView's out-of-process content.")

        } catch {
            append("FAILED: \(error.localizedDescription)")
            AppLog.capture.error("GPU capture comparison failed: \(error.localizedDescription)")
        }
    }

    /// Validates that the proven CALayer.render(in:) capture path still
    /// produces correct output when the WKWebView lives in a real but
    /// off-screen window (OffscreenRenderWindow), instead of the on-screen
    /// dev window used by every test so far. This is a genuinely new
    /// variable -- confirm it here before it becomes the real render path.
    /// Two things this test can reveal, both informative either way:
    ///   - Wrong content (blank/garbled): the off-screen window isn't
    ///     "live" enough for WebKit to render into correctly.
    ///   - Size mismatch (diff can't be computed): likely the off-screen
    ///     window's backingScaleFactor didn't come back as 2.0 the way an
    ///     on-screen Retina window's does -- see OffscreenRenderWindow's
    ///     comments for why that's a real, not hypothetical, possibility.
    func compareOffscreenCapture() async {
        isRunning = true
        log = ""
        offscreenDiffResult = nil
        offscreenBaselineImage = nil
        offscreenCandidateImage = nil
        defer { isRunning = false }

        var offscreen: OffscreenRenderWindow?
        defer { offscreen?.close() }

        do {
            append("Loading on-screen (proven) webView -- this is the ground truth...")
            try await renderService.load(baseURL: baseURL)
            try await renderService.selectAnimation(animation)
            try await renderService.selectPalette(palette)
            try await renderService.waitForSetupDone()
            try await renderService.setNoiseSeed(noiseSeed)
            try await renderService.stopAutomaticLoop()

            let targetSeconds = 5.0
            let targetFrameCount = targetSeconds * 60.0
            _ = try await renderService.stepFrame(toTargetFrameCount: targetFrameCount)

            append("Capturing on-screen...")
            let onscreenBuffer = try captureService.capturePixelBuffer(from: renderService.webView)
            guard let onscreenImage = captureService.image(from: onscreenBuffer) else {
                throw FrameCaptureService.CaptureError.pngEncodingFailed
            }
            offscreenBaselineImage = onscreenImage

            append("Creating off-screen window (same 1920x1080pt size) and loading the same page...")
            let offscreenWindow = OffscreenRenderWindow(width: 1920, height: 1080)
            offscreen = offscreenWindow
            let offscreenRenderService = WebRenderService(externalWebView: offscreenWindow.webView)

            try await offscreenRenderService.load(baseURL: baseURL)
            try await offscreenRenderService.selectAnimation(animation)
            try await offscreenRenderService.selectPalette(palette)
            try await offscreenRenderService.waitForSetupDone()
            try await offscreenRenderService.setNoiseSeed(noiseSeed)
            try await offscreenRenderService.stopAutomaticLoop()
            _ = try await offscreenRenderService.stepFrame(toTargetFrameCount: targetFrameCount)

            append("Capturing off-screen...")
            let offscreenBuffer = try captureService.capturePixelBuffer(from: offscreenWindow.webView)
            guard let offscreenImage = captureService.image(from: offscreenBuffer) else {
                throw FrameCaptureService.CaptureError.pngEncodingFailed
            }
            offscreenCandidateImage = offscreenImage

            if let diff = captureService.meanAbsoluteDifference(onscreenImage, offscreenImage) {
                let verdict = diff < 2.0 ? "essentially identical -- off-screen rendering validated"
                             : diff < 15.0 ? "close, minor differences"
                             : "SIGNIFICANTLY DIFFERENT -- do not trust off-screen rendering yet"
                let result = String(format: "Mean abs diff: %.2f / 255 -- %@", diff, verdict)
                offscreenDiffResult = result
                append(result)
            } else {
                append("Could not compute a pixel diff -- likely a size mismatch. Check the printed "
                       + "dimensions of each image: if the off-screen one is half the on-screen one in "
                       + "each direction, that's the backingScaleFactor falling back to 1.0 as warned "
                       + "about in OffscreenRenderWindow's comments, not a content problem.")
            }

            append("Look at both images below. Same content = off-screen rendering works and this can "
                   + "become the real, invisible render path.")

        } catch {
            append("FAILED: \(error.localizedDescription)")
            AppLog.render.error("Offscreen capture comparison failed: \(error.localizedDescription)")
        }
    }

    private func append(_ line: String) {
        log += line + "\n"
        AppLog.render.info("\(line)")
    }
}
