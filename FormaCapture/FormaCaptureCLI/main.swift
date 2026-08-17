//
//  main.swift
//  FormaCaptureCLI
//
//  Command-line worker: renders one frame range of one animation/palette to
//  one MP4 file, then exits. Meant to be launched multiple times in
//  parallel (different --start-frame/--end-frame per instance) by an
//  external shell script, then the resulting segments concatenated with
//  ffmpeg -- same shape as the Python capture_fast_parallel_piped.py
//  approach, translated to Swift.
//
//  Deliberately NOT sandboxed (a bare Command Line Tool target has no App
//  Sandbox capability unless explicitly added -- don't add one). This is
//  what makes the whole parallelization plan viable without fighting
//  App Sandbox's process-spawning restrictions: the orchestrating shell
//  script and this worker are both outside the sandbox entirely, so the
//  question of "can a sandboxed process spawn children" never comes up.
//
//  Reuses WebRenderService, FrameCaptureService, VideoEncodingService, and
//  OffscreenRenderWindow from the GUI app target -- these are the same,
//  already-validated files (0.00-0.02/255 diff against on-screen rendering,
//  correct HEVC output). Make sure their target membership includes this
//  CLI target in Xcode (File Inspector -> Target Membership -> check this
//  target too), or these types won't be visible here.
//
//  UNVERIFIED, first-round-may-not-compile territory: whether a bare
//  NSApplication set up this way (no app bundle lifecycle, no Info.plist
//  the way a real .app has) gives WKWebView everything it needs. The
//  underlying requirement (a real window, not a fully detached webview)
//  is already proven via OffscreenRenderWindow in the GUI app -- what's
//  new here is doing that from a command-line process instead of a GUI
//  app process. If WKWebView behaves differently in this context, that's
//  the first thing to suspect.
//

import Foundation
import AppKit

// MARK: - Argument parsing

// RenderMode / knownEngines / engineRenderModes now live in
// WebRenderService.swift (shared by both the FormaCapture GUI target and
// FormaCaptureCLI) instead of here -- they were originally declared in this
// file, but main.swift is CLI-target-only, so WebRenderService.swift
// (compiled into BOTH targets) couldn't see them. Moved to fix that; see
// WebRenderService.swift for the full reasoning comments.

struct CLIOptions {
    var engine: String = "p5"
    var animation: String = "loop_topology"
    var palette: String = "starwars"
    var startFrame: Int = 0
    var endFrame: Int = 600  // exclusive
    var outputPath: String = "./output.mp4"
    var outputFPS: Double = 60.0
    var noiseSeed: Int = 20260810
    var baseURLString: String = "http://127.0.0.1:8000"

    // Orchestration mode -- when --orchestrate is passed, none of the
    // fields above matter except engine/animation/palette/outputFPS/
    // noiseSeed/baseURLString (passed through to each spawned worker).
    // Instead of rendering itself, this process becomes a parent that
    // launches `workers` copies of itself, each with a distinct
    // --start-frame/--end-frame slice, waits for all of them, then
    // concatenates the resulting segments with ffmpeg.
    var orchestrate: Bool = false
    var workers: Int = 2
    var durationSeconds: Double = 20.0
    var outputDir: String = ""
}

func parseArguments() -> CLIOptions {
    var options = CLIOptions()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = args.next() {
        switch arg {
        case "--engine":
            if let v = args.next() {
                if knownEngines.contains(v) {
                    options.engine = v
                } else {
                    errLog("Unknown --engine '\(v)'. Known engines: \(knownEngines.joined(separator: ", "))")
                    exit(1)
                }
            }
        case "--animation": if let v = args.next() { options.animation = v }
        case "--palette": if let v = args.next() { options.palette = v }
        case "--start-frame": if let v = args.next(), let i = Int(v) { options.startFrame = i }
        case "--end-frame": if let v = args.next(), let i = Int(v) { options.endFrame = i }
        case "--output": if let v = args.next() { options.outputPath = v }
        case "--fps": if let v = args.next(), let d = Double(v) { options.outputFPS = d }
        case "--noise-seed": if let v = args.next(), let i = Int(v) { options.noiseSeed = i }
        case "--base-url": if let v = args.next() { options.baseURLString = v }
        case "--orchestrate": options.orchestrate = true
        case "--workers": if let v = args.next(), let i = Int(v) { options.workers = i }
        case "--duration-seconds": if let v = args.next(), let d = Double(v) { options.durationSeconds = d }
        case "--output-dir": if let v = args.next() { options.outputDir = v }
        default:
            errLog("Unknown argument: \(arg)")
        }
    }
    return options
}

func errLog(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

func timestampedLog(_ s: String) {
    errLog("[\(timeFormatter.string(from: Date()))] \(s)")
}

// MARK: - Orchestration mode
//
// Genuinely new, untested territory as of this addition -- everything
// above this point (single-worker render) is already proven; self-
// relaunching via Process has not been exercised at all. Test with a
// short --duration-seconds before trusting this with a real long render.
//
// This mirrors render_parallel.sh's logic exactly, just in Swift instead
// of bash, so this process alone can do what previously needed an
// external orchestrating script. Works because this CLI target is
// unsandboxed -- a sandboxed process could not spawn children this way.

func runOrchestrator(_ options: CLIOptions) -> Never {
    guard !options.outputDir.isEmpty else {
        errLog("--orchestrate requires --output-dir (a folder on an external volume -- never the boot drive).")
        exit(1)
    }
    guard let executablePath = Bundle.main.executablePath else {
        errLog("Could not determine this executable's own path -- needed to spawn worker copies of itself. "
               + "This is genuinely uncertain territory; if this fires, that's the first thing to investigate.")
        exit(1)
    }

    try? FileManager.default.createDirectory(atPath: options.outputDir, withIntermediateDirectories: true)

    let totalFrames = Int(options.durationSeconds * options.outputFPS)
    let chunk = totalFrames / options.workers
    let stamp = timeFormatter.string(from: Date()).replacingOccurrences(of: ":", with: "")
        + "_" + String(Int(Date().timeIntervalSince1970))

    timestampedLog("Orchestrating \(options.workers) workers, \(totalFrames) frames "
                   + "(\(options.durationSeconds)s) -> \(options.outputDir)")
    timestampedLog("Self path for spawning workers: \(executablePath)")

    var segmentPaths: [String] = []
    var logPaths: [String] = []
    var processes: [Process] = []

    for w in 0..<options.workers {
        let start = w * chunk
        let end = (w == options.workers - 1) ? totalFrames : (w + 1) * chunk  // last worker takes any remainder
        let tag = String(format: "%02d", w)
        let segmentPath = "\(options.outputDir)/segment_\(tag)_\(stamp).mp4"
        let logPath = "\(options.outputDir)/worker_\(tag)_\(stamp).log"
        segmentPaths.append(segmentPath)
        logPaths.append(logPath)

        FileManager.default.createFile(atPath: logPath, contents: nil)
        guard let logHandle = FileHandle(forWritingAtPath: logPath) else {
            errLog("Could not open log file for worker \(w): \(logPath)")
            exit(1)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [
            "--engine", options.engine,
            "--animation", options.animation,
            "--palette", options.palette,
            "--start-frame", "\(start)",
            "--end-frame", "\(end)",
            "--output", segmentPath,
            "--fps", "\(options.outputFPS)",
            "--noise-seed", "\(options.noiseSeed)",  // explicit, not relying on matching defaults -- same lesson as the earlier parallel-noise-seed bug
            "--base-url", options.baseURLString,
        ]
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
            timestampedLog("  worker \(w): frames \(start)..<\(end) -> \((segmentPath as NSString).lastPathComponent) (PID \(process.processIdentifier))")
            processes.append(process)
        } catch {
            errLog("Failed to launch worker \(w): \(error.localizedDescription)")
            exit(1)
        }
    }

    timestampedLog("Launched \(processes.count) workers. Waiting...")

    var anyFailed = false
    for (i, process) in processes.enumerated() {
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            errLog("Worker \(i) FAILED (exit \(process.terminationStatus)) -- see \((logPaths[i] as NSString).lastPathComponent)")
            anyFailed = true
        } else {
            timestampedLog("Worker \(i) finished.")
        }
    }

    if anyFailed {
        errLog("One or more workers failed. Not concatenating -- check the logs above first.")
        exit(1)
    }

    timestampedLog("All workers finished. Verifying every segment exists and is non-empty...")
    for seg in segmentPaths {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: seg),
              let size = attrs[.size] as? Int, size > 0 else {
            errLog("Missing or empty segment: \(seg)")
            exit(1)
        }
    }

    timestampedLog("Concatenating (stream copy, lossless)...")
    let concatListPath = "\(options.outputDir)/_concat_list_\(stamp).txt"
    let concatListContent = segmentPaths.map { "file '\($0)'" }.joined(separator: "\n")
    do {
        try concatListContent.write(toFile: concatListPath, atomically: true, encoding: .utf8)
    } catch {
        errLog("Failed to write concat list: \(error.localizedDescription)")
        exit(1)
    }

    let finalPath = "\(options.outputDir)/render_\(options.animation)_\(options.palette)_\(stamp).mp4"
    let ffmpeg = Process()
    ffmpeg.executableURL = URL(fileURLWithPath: "/usr/bin/env")  // resolves ffmpeg via PATH, same as a shell would
    // -nostdin: ffmpeg normally reads keystrokes from stdin for interactive
    // control ("Press [q] to stop" -- visible in every ffmpeg log this
    // session). A process spawned via Process() isn't the terminal's
    // foreground process group even though it inherits the same stdin, so
    // the moment ffmpeg tries to read a keypress, the OS sends SIGTTIN,
    // which stops the process by default. That's the actual cause of the
    // repeated concat hang, not a stray keypress. Also explicitly nulling
    // standardInput below so there's nothing to read even if this flag
    // were somehow ignored.
    ffmpeg.arguments = ["ffmpeg", "-y", "-nostdin", "-f", "concat", "-safe", "0", "-i", concatListPath, "-c", "copy", finalPath]
    ffmpeg.standardInput = FileHandle.nullDevice

    do {
        try ffmpeg.run()
        ffmpeg.waitUntilExit()
    } catch {
        errLog("Failed to launch ffmpeg: \(error.localizedDescription)")
        errLog("Segments left in place in \(options.outputDir) for manual concatenation.")
        exit(1)
    }

    if ffmpeg.terminationStatus == 0,
       let attrs = try? FileManager.default.attributesOfItem(atPath: finalPath),
       let size = attrs[.size] as? Int, size > 0 {
        timestampedLog("Done: \(finalPath)")
        timestampedLog("Watch the \(options.workers - 1) boundary point(s) between worker ranges before trusting this.")
        try? FileManager.default.removeItem(atPath: concatListPath)
        exit(0)
    } else {
        errLog("Concat failed (ffmpeg exit \(ffmpeg.terminationStatus)) -- segments left in place in \(options.outputDir).")
        exit(1)
    }
}

let options = parseArguments()

if options.orchestrate {
    runOrchestrator(options)
    // runOrchestrator always exits -- nothing below this runs in orchestrate mode.
}

// MARK: - Minimal headless AppKit setup
// WKWebView needs a real run loop pumping (XPC communication with its
// WebContent process) and, per OffscreenRenderWindow's already-validated
// requirement, an actual NSWindow. .prohibited activation policy means no
// Dock icon, no menu bar -- as headless as a CLI tool can be while still
// having the Cocoa machinery WKWebView needs underneath it.
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.finishLaunching()

Task { @MainActor in
    do {
        timestampedLog("Starting. Engine=\(options.engine) Rendering frames \(options.startFrame)..<\(options.endFrame) -> \(options.outputPath)")

        guard let baseURL = URL(string: options.baseURLString) else {
            errLog("Invalid --base-url: \(options.baseURLString)")
            exit(1)
        }

        let offscreenWindow = OffscreenRenderWindow(width: 1920, height: 1080)
        let renderService = WebRenderService(externalWebView: offscreenWindow.webView)

        // load() appends engines/<engine>.html itself -- if --animation
        // doesn't belong to that engine's page, selectAnimation() below
        // throws a specific error naming what IS available on the page,
        // rather than a silent no-op or a generic timeout.
        try await renderService.load(baseURL: baseURL, engine: options.engine)
        try await renderService.selectAnimation(options.animation)
        try await renderService.selectPalette(options.palette)
        try await renderService.waitForSetupDone(engine: options.engine)
        try await renderService.setNoiseSeed(options.noiseSeed, engine: options.engine)
        try await renderService.hideControls()
        try await renderService.stopAutomaticLoop(engine: options.engine)

        timestampedLog("Setup complete, starting capture loop.")

        let captureService = FrameCaptureService()
        let encodingService = VideoEncodingService()

        let webView = offscreenWindow.webView
        let scale = webView.window?.backingScaleFactor ?? webView.layer?.contentsScale ?? 2.0
        let width = Int(webView.bounds.width * scale)
        let height = Int(webView.bounds.height * scale)

        let outputURL = URL(fileURLWithPath: options.outputPath)
        try encodingService.start(outputURL: outputURL, width: width, height: height, frameRate: options.outputFPS)

        let internalStep = 60.0 / options.outputFPS
        let frameCount = options.endFrame - options.startFrame
        let isRealtime = engineRenderModes[options.engine] == .realtime

        // Realtime engines (see RenderMode) have no seekable internal clock --
        // they only ever run forward from whenever switchAnim() fired on page
        // load, at real wall-clock speed. --start-frame > 0 would imply
        // "skip ahead to this point before capturing," which isn't possible
        // here without literally waiting that many seconds of real time first
        // (burning it, not skipping it). Rather than silently do that (which
        // would make a worker's captured segment start late relative to its
        // filename/expected timeline) or silently ignore --start-frame
        // (which would make every worker capture from t=0, producing N
        // identical segments instead of a sequence), refuse outright and
        // make the person choose deliberately -- e.g. --workers 1 for
        // realtime engines until this gets real parallel-worker support.
        if isRealtime && options.startFrame > 0 {
            errLog("--engine \(options.engine) is a realtime-captured engine (no external frame-stepping -- "
                   + "see RenderMode in this file) and cannot start capture at a nonzero --start-frame; "
                   + "its internal clock only runs forward from page load. This makes it incompatible with "
                   + "--orchestrate's multi-worker frame-range splitting as currently implemented. "
                   + "Use --workers 1 (single segment, --start-frame 0) for this engine for now.")
            exit(1)
        }

        // Priming/warm-up: confirmed via QuickTime (not an iMovie cache
        // artifact -- this pixel data is genuinely in the file) that the
        // very first captured frame of a fresh process shows stale,
        // pre-JS-driven page state (default palette, visible controls),
        // despite selectPalette()/hideControls() having already been
        // verified successful. Root cause: JS execution (synchronous,
        // correctly verified) and WebKit's own compositor actually
        // flushing that content into the GPU-backed layer we read via
        // layer.render(in:) are NOT the same thing -- the compositor has
        // its own commit cycle. The very first read can catch the layer
        // before it's ever been flushed at all. Discarding a few redraws
        // at the intended first target frame before starting the real
        // loop gives the compositor a chance to catch up. UNVERIFIED
        // whether 3 iterations / this delay is exactly right -- first
        // attempt at a now-confirmed, previously misdiagnosed bug (B-frame
        // disabling did not fix this, because it was never a concat issue).
        //
        // For realtime engines there's no stepFrame to call (no seekable
        // clock -- see above), so priming is just "let its own rAF loop
        // paint a few real frames" via a plain sleep instead of a driven step.
        let firstTarget = Double(options.startFrame) * internalStep
        for _ in 0..<3 {
            let primingBuffer = try encodingService.newPooledPixelBuffer()
            if isRealtime {
                try await Task.sleep(nanoseconds: 50_000_000)
            } else {
                _ = try await renderService.stepFrame(toTargetFrameCount: firstTarget)
            }
            try captureService.render(webView, into: primingBuffer)  // rendered and discarded, not appended
            try await Task.sleep(nanoseconds: 50_000_000)  // 50ms between attempts
        }
        timestampedLog("Warm-up complete, starting real capture.")

        var totalDriveTime = 0.0
        var totalCaptureTime = 0.0
        var totalEncodeTime = 0.0
        let wallStart = Date()
        // Realtime pacing reference point -- frame 0's capture should happen
        // at (roughly) this instant, frame 1 one outputFPS-period later, etc.
        // Deliberately NOT tied to stepFrame/targetFrameCount math at all,
        // since that's a virtual-frame concept these engines don't have.
        let realtimeStart = Date()
        let outputFrameInterval = 1.0 / options.outputFPS

        for i in options.startFrame..<options.endFrame {
            let t0 = Date()
            if isRealtime {
                // Wait until real elapsed time reaches this output frame's
                // slot, then capture whatever the page's own rAF loop has
                // painted by then -- there's nothing to "drive" here, the
                // page is animating on its own. If the page/system is running
                // behind (this frame's slot has already passed), don't sleep
                // at all -- capture immediately and let the timing drift
                // show up honestly in the output rather than trying to fake
                // catch-up, which would just duplicate-sample a stale frame.
                let targetInstant = realtimeStart.addingTimeInterval(Double(i) * outputFrameInterval)
                let waitSeconds = targetInstant.timeIntervalSinceNow
                if waitSeconds > 0 {
                    try await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
                }
            } else {
                let targetFrameCount = Double(i) * internalStep
                _ = try await renderService.stepFrame(toTargetFrameCount: targetFrameCount)
            }
            let t1 = Date()

            let pixelBuffer = try encodingService.newPooledPixelBuffer()
            try captureService.render(webView, into: pixelBuffer)
            let t2 = Date()

            try await encodingService.appendFrame(pixelBuffer)
            let t3 = Date()

            totalDriveTime += t1.timeIntervalSince(t0)
            totalCaptureTime += t2.timeIntervalSince(t1)
            totalEncodeTime += t3.timeIntervalSince(t2)

            let done = i - options.startFrame + 1
            if done % 100 == 0 || done == frameCount {
                let elapsed = Date().timeIntervalSince(wallStart)
                let rate = elapsed / Double(done)
                timestampedLog(String(format: "  frame %d/%d  elapsed=%.1fs  %.1fms/frame avg",
                                       done, frameCount, elapsed, rate * 1000))
            }
        }

        let wallElapsed = Date().timeIntervalSince(wallStart)

        try await encodingService.finish()
        offscreenWindow.close()

        timestampedLog("Done: \(options.outputPath)")
        errLog("")
        errLog("Timing breakdown over \(frameCount) frames:")
        errLog(String(format: "  drive (frameCount/redraw):  %.2fs total, %.1fms/frame",
                       totalDriveTime, 1000 * totalDriveTime / Double(frameCount)))
        errLog(String(format: "  capture (CALayer->buffer):  %.2fs total, %.1fms/frame",
                       totalCaptureTime, 1000 * totalCaptureTime / Double(frameCount)))
        errLog(String(format: "  encode (append to writer):  %.2fs total, %.1fms/frame",
                       totalEncodeTime, 1000 * totalEncodeTime / Double(frameCount)))
        errLog(String(format: "  wall-clock: %.2fs for %.1fs of output (%.3fx realtime)",
                       wallElapsed, Double(frameCount) / options.outputFPS,
                       (Double(frameCount) / options.outputFPS) / wallElapsed))
        let outputSeconds = Double(frameCount) / options.outputFPS
        let projectedMinutes = wallElapsed * (3600.0 / outputSeconds) / 60.0
        errLog(String(format: "  projected full 60-min render at this rate: %.1f minutes (single worker, this resolution)",
                       projectedMinutes))

        exit(0)
    } catch {
        errLog("FAILED: \(error.localizedDescription)")
        exit(1)
    }
}

app.run()
