//
//  WebRenderService.swift
//  FormaCapture
//
//  Owns a WKWebView and drives it exactly the way the Python capture scripts
//  drove headless Chromium via Playwright: select an animation and palette,
//  wait for p5's setup() to finish, then manually step frameCount and call
//  redraw() to advance the animation frame-by-frame under program control
//  instead of real time.
//
//  The frameCount/redraw() mechanics here mirror capture_fast.py's verified
//  behavior (checked against the actual p5.js 1.9.3 source via `npm pack`):
//  redraw() takes whatever frameCount currently is, adds 1, then runs draw().
//  stepFrame(toTargetFrameCount:) accounts for that off-by-one internally,
//  same as the Python version.
//
//  UNVERIFIED, THIS IS THE THING TO TEST FIRST: WKWebView reliably renders
//  when attached to a real window. Fully detached/off-screen WKWebViews are
//  a known WebKit soft spot -- this is why FormaCaptureApp keeps this view
//  visible in an actual window for now rather than trying to run it purely
//  in memory. If frames come back blank once capture is added later, this
//  assumption is the first thing to revisit.
//
//  Does NOT yet include: local file serving (point baseURL at your existing
//  `python3 -m http.server 8000` for now), UI-hiding, or any frame capture.
//  This service validates the render/drive layer in isolation, on purpose --
//  see the project scope doc for why.
//

import Foundation
import WebKit
import os

@MainActor
final class WebRenderService: NSObject {

    enum RenderError: LocalizedError {
        case paletteDidNotApply(requestedKey: String, got: String?)
        case javaScriptFailed(String)
        case timedOut(String)

        var errorDescription: String? {
            switch self {
            case .paletteDidNotApply(let key, let got):
                return "Palette key '\(key)' did not resolve to anything. Got: \(got ?? "nil"). Check web/palettes/manifest.js for valid keys (the dict key, not the display label)."
            case .javaScriptFailed(let detail):
                return "JavaScript evaluation failed: \(detail)"
            case .timedOut(let what):
                return "Timed out waiting for: \(what)"
            }
        }
    }

    let webView: WKWebView
    private var loadContinuation: CheckedContinuation<Void, Error>?

    override init() {
        let config = WKWebViewConfiguration()
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        // WKWebView is layer-backed internally in practice, but this makes
        // it explicit rather than assumed -- FrameCaptureService's
        // CALayer.render(in:) path needs webView.layer to be non-nil.
        webView.wantsLayer = true
    }

    // MARK: - Page load

    /// Loads engines/p5.html from the given base URL (e.g. http://127.0.0.1:8000).
    /// Requires the site already being served -- run
    ///     cd web/web && python3 -m http.server 8000
    /// in a terminal first, same as every Python capture script so far.
    func load(baseURL: URL) async throws {
        let pageURL = baseURL.appendingPathComponent("engines/p5.html")
        AppLog.render.info("Loading \(pageURL.absoluteString)")

        // Raced against a timeout deliberately -- without this, a network
        // request that gets silently blocked (e.g. missing sandbox
        // entitlement) rather than cleanly refused just hangs forever with
        // zero feedback, since didFinish/didFail never fire either way.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.loadContinuation = continuation
                    self.webView.load(URLRequest(url: pageURL))
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                throw RenderError.timedOut(
                    "page load (\(pageURL.absoluteString)). If the server is confirmed running "
                    + "and this still times out, check Signing & Capabilities -> App Sandbox -> "
                    + "Outgoing Connections (Client) is checked, and check Xcode's debug console "
                    + "(Shift-Cmd-Y) for a sandbox network-denial message."
                )
            }
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                // Resume the abandoned continuation so Swift doesn't flag it as
                // leaked (a harmless but noisy console warning), then clear the
                // reference so a later, now-moot delegate callback finds nil
                // and safely no-ops via `loadContinuation?.resume(...)` instead
                // of attempting a second resume.
                self.loadContinuation?.resume(throwing: error)
                self.loadContinuation = nil
                group.cancelAll()
                throw error
            }
        }

        // Mirrors: page.wait_for_selector("#anim")
        try await waitFor(jsCondition: "document.getElementById('anim') !== null", timeoutSeconds: 15,
                           description: "#anim to exist")
    }

    // MARK: - Animation / palette selection

    /// Mirrors: page.select_option("#anim", key)
    /// Waits for the target <option> to actually exist before selecting it --
    /// the dropdown's options are populated asynchronously (each animation
    /// module finishes its own dynamic import() before being appended), so
    /// setting .value before that finishes is a silent no-op rather than an
    /// error, leaving whichever animation loaded first selected instead.
    /// Playwright's select_option() has this wait built in; raw JS .value
    /// assignment does not -- this is what let "loop_topology" silently stay
    /// on "flowfield" with zero error the first time this ran.
    func selectAnimation(_ key: String) async throws {
        try await waitFor(
            jsCondition: "Array.from(document.getElementById('anim').options).some(o => o.value === '\(key)')",
            timeoutSeconds: 15,
            description: "<option value='\(key)'> to exist in #anim"
        )

        try await run("""
            (() => {
                const el = document.getElementById('anim');
                el.value = '\(key)';
                el.dispatchEvent(new Event('change'));
            })();
        """)

        let actual = try await runReturningString("document.getElementById('anim').value")
        guard actual == key else {
            throw RenderError.javaScriptFailed(
                "Animation selection did not stick: wanted '\(key)', got '\(actual ?? "nil")'"
            )
        }
        AppLog.render.info("Animation confirmed: \(actual ?? "?")")
    }

    /// Mirrors: page.select_option("#palette-selector", key) followed by the
    /// Python scripts' explicit verification step -- don't trust the palette
    /// applied silently, confirm it. This is what caught the very first bug
    /// in this whole project (PALETTE_KEY="Star Wars" vs the real key "starwars").
    /// Also waits for the option to exist first, same reasoning as
    /// selectAnimation above -- palette options are async-populated too.
    func selectPalette(_ key: String) async throws {
        try await waitFor(
            jsCondition: "Array.from(document.getElementById('palette-selector').options).some(o => o.value === '\(key)')",
            timeoutSeconds: 15,
            description: "<option value='\(key)'> to exist in #palette-selector"
        )

        try await run("""
            (() => {
                const el = document.getElementById('palette-selector');
                el.value = '\(key)';
                el.dispatchEvent(new Event('change'));
            })();
        """)

        let applied = try await runReturningString("window.FORMA_PALETTE && window.FORMA_PALETTE.name")
        guard let applied, !applied.isEmpty else {
            throw RenderError.paletteDidNotApply(requestedKey: key, got: applied)
        }
        AppLog.render.info("Palette confirmed: \(applied)")
    }

    // MARK: - Sketch lifecycle

    /// Mirrors: page.wait_for_function("window.currentSketch && window.currentSketch._setupDone")
    /// This is exactly the check that caught the "blank frames because setup()
    /// hadn't finished yet" failure mode in the Python scripts -- redraw()
    /// silently no-ops if _setupDone is false, with no error at all.
    func waitForSetupDone(timeoutSeconds: TimeInterval = 15) async throws {
        try await waitFor(
            jsCondition: "window.currentSketch && window.currentSketch._setupDone === true",
            timeoutSeconds: timeoutSeconds,
            description: "window.currentSketch._setupDone"
        )
    }

    /// Mirrors: window.currentSketch.noiseSeed(seed)
    /// Must be called before the first redraw(). Only matters once this
    /// service is driven by multiple parallel instances later -- see
    /// capture_fast_parallel.py's docstring for the full explanation of why
    /// (p5's noise() otherwise seeds itself from Math.random() on first use).
    func setNoiseSeed(_ seed: Int) async throws {
        try await run("window.currentSketch.noiseSeed(\(seed));")
    }

    /// Mirrors: window.currentSketch.noLoop()
    func stopAutomaticLoop() async throws {
        try await run("window.currentSketch.noLoop();")
    }

    /// Mirrors the exact frameCount dance from capture_fast.py. Pass the
    /// frameCount you want draw() to actually see -- this handles the
    /// redraw()-adds-1 offset internally. Returns the frameCount draw()
    /// actually ran with, so callers can verify drift the same way the
    /// Python scripts did.
    @discardableResult
    func stepFrame(toTargetFrameCount targetFrameCount: Double) async throws -> Double {
        let js = """
            (() => {
                window.currentSketch.frameCount = \(targetFrameCount - 1);
                window.currentSketch.redraw();
                return window.currentSketch.frameCount;
            })();
        """
        let result = try await webView.evaluateJavaScript(js)
        guard let number = result as? NSNumber else {
            throw RenderError.javaScriptFailed("stepFrame did not return a number (got \(String(describing: result)))")
        }
        return number.doubleValue
    }

    // MARK: - JS helpers

    private func run(_ js: String) async throws {
        do {
            _ = try await webView.evaluateJavaScript(js)
        } catch {
            throw RenderError.javaScriptFailed(error.localizedDescription)
        }
    }

    private func runReturningString(_ js: String) async throws -> String? {
        let result = try await webView.evaluateJavaScript(js)
        return result as? String
    }

    private func waitFor(jsCondition: String, timeoutSeconds: TimeInterval, description: String,
                          pollInterval: TimeInterval = 0.1) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let result = try? await webView.evaluateJavaScript(jsCondition) as? Bool, result {
                return
            }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        throw RenderError.timedOut(description)
    }
}

// MARK: - WKNavigationDelegate

extension WebRenderService: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }
}
