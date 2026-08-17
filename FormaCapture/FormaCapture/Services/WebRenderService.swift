
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

// MARK: - Engine metadata

// The web app has no single page that can render every engine -- each
// engine is its own HTML file (engines/p5.html, engines/pixi.html, ...)
// with its own hardcoded ANIMATION_FILES registry pointing at its own
// animations/<engine>/ folder. Keep this list in sync with web/engines/*.html
// filenames.
//
// Declared here (not in FormaCaptureCLI's main.swift, where this originally
// lived) because this file is compiled into BOTH the FormaCapture GUI target
// and the FormaCaptureCLI target, while main.swift belongs to the CLI target
// only -- WebRenderService's own methods below need this, and a CLI-only
// file can't provide something a shared file depends on.
let knownEngines = ["p5", "threejs", "canvas2d", "pixi", "regl", "svg"]

enum RenderMode {
    // p5 (native currentSketch/frameCount/redraw) and regl (shimmed with the
    // same p5-shaped contract in engines/regl.html) support deterministic,
    // externally-stepped capture: pause the page's own clock entirely and
    // drive it forward one virtual frame at a time. Reproducible byte-for-byte
    // across runs; correct even under heavy parallel-worker CPU contention,
    // since nothing depends on wall-clock timing.
    case steppable

    // threejs/canvas2d/pixi/svg each track elapsed time internally in their
    // own animation modules (performance.now(), PIXI's app.ticker, or a
    // fixed-per-call accumulator) with no exposed hook to freeze or drive
    // that clock externally -- see the per-engine audit that led to this
    // (project notes / conversation history, not restated per-method here).
    // Rather than patch every animation module across four different
    // time-tracking styles, these are captured the way a screen recorder
    // would: let the animation run at real wall-clock speed, sample
    // whatever's on screen at each output-frame boundary. NOT frame-accurate
    // or reproducible run-to-run, and vulnerable to real-world timing
    // pressure (GPU contention from parallel workers, thermal throttling)
    // actually showing up as uneven motion in the output, unlike steppable
    // capture.
    case realtime
}

// Single source of truth for engine capture behavior -- consulted by both
// WebRenderService (below) and FormaCaptureCLI's main.swift.
let engineRenderModes: [String: RenderMode] = [
    "p5": .steppable,
    "regl": .steppable,
    // Changed from .realtime -- engines/threejs.html now has the same
    // p5-shaped window.currentSketch shim as regl.html, so it can be driven
    // via stepFrame() like p5/regl instead of relying on its own
    // free-running rAF loop (which appeared frozen during capture --
    // rAF-throttling was tested directly via a setInterval swap and did NOT
    // fix it, so the mechanism is still not fully confirmed; this steppable
    // path sidesteps the question entirely rather than resolving it).
    "threejs": .steppable,
    "canvas2d": .realtime,
    "pixi": .realtime,
    "svg": .realtime,
]

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

    /// Pass an existing WKWebView (e.g. one hosted in an OffscreenRenderWindow)
    /// to drive that instead of creating a new one. Defaults to nil, which
    /// preserves the original behavior exactly -- the on-screen dev/test
    /// call site (WebRenderService()) is unaffected by this change.
    init(externalWebView: WKWebView? = nil) {
        if let externalWebView {
            self.webView = externalWebView
        } else {
            let config = WKWebViewConfiguration()
            self.webView = WKWebView(frame: .zero, configuration: config)
        }
        super.init()
        webView.navigationDelegate = self
        // WKWebView is layer-backed internally in practice, but this makes
        // it explicit rather than assumed -- FrameCaptureService's
        // CALayer.render(in:) path needs webView.layer to be non-nil.
        webView.wantsLayer = true
        installConsoleBridge()
    }

    // MARK: - Console bridge

    // WKWebView's own console.log/console.error calls are NOT visible
    // anywhere outside a Safari Web Inspector session attached to that
    // specific WKWebView, or Xcode's debug console when running under
    // Xcode's debugger. Neither is available when FormaCaptureCLI is
    // launched directly from Terminal (the normal/only way --orchestrate's
    // spawned workers run) -- so up to this point, ANY in-page JS error or
    // debug log during a real capture run was completely invisible, no
    // matter how much diagnostic logging got added to the HTML/JS. This
    // bridge pipes console output into AppLog/stdout via a
    // WKScriptMessageHandler, so it lands in the same worker .log files
    // main.swift already writes -- visible after the fact, no live
    // debugger session required.
    //
    // Injected as a userScript at .atDocumentStart so it overrides
    // window.console before any page script (including inline <script>
    // blocks and modules) runs and could call the original console.log.
    // Overriding rather than merely listening means nothing needs to
    // change in any engine page's own code -- existing console.log/
    // console.error calls (like the [regl][capture-debug] ones added
    // earlier) get bridged automatically, past and future.
    private static let consoleBridgeHandlerName = "formaConsoleBridge"

    private func installConsoleBridge() {
        let controller = webView.configuration.userContentController
        controller.add(self, name: Self.consoleBridgeHandlerName)

        let bridgeJS = """
        (function() {
            const handlerName = '\(Self.consoleBridgeHandlerName)';
            const send = (level, args) => {
                try {
                    // Best-effort stringify -- console.log accepts objects,
                    // Errors, etc., not just strings. JSON.stringify throws
                    // on circular structures, so fall back to String()
                    // rather than losing the message entirely.
                    const parts = args.map(a => {
                        if (typeof a === 'string') return a;
                        try { return JSON.stringify(a); }
                        catch (e) { return String(a); }
                    });
                    window.webkit.messageHandlers[handlerName].postMessage({
                        level: level,
                        text: parts.join(' ')
                    });
                } catch (e) {
                    // If the bridge itself fails, don't let that break the
                    // page's own console output -- original.apply below
                    // still runs regardless.
                }
            };
            ['log', 'warn', 'error', 'info'].forEach(level => {
                const original = console[level] ? console[level].bind(console) : null;
                console[level] = function(...args) {
                    send(level, args);
                    if (original) original(...args);
                };
            });
            // TEMP SELF-TEST: unconditional, fires on every page load
            // regardless of which engine/animation is active or whether
            // tick()/redraw() ever runs. Presence or absence of this exact
            // line in a worker's .log file is a clean yes/no on whether the
            // bridge mechanism itself works, decoupled from any
            // animation-specific logging. Remove once confirmed working.
            console.log('[capture-debug] console bridge installed and active');
        })();
        """
        let userScript = WKUserScript(source: bridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        controller.addUserScript(userScript)
    }

    // MARK: - Page load

    /// Loads engines/<engine>.html from the given base URL (e.g. http://127.0.0.1:8000).
    /// Defaults to "p5" so existing call sites (RenderSanityTestViewModel's
    /// already-validated p5 test flows) keep compiling and keep their proven
    /// behavior unchanged -- only the CLI passes engine explicitly for now.
    /// Requires the site already being served -- run
    ///     cd web/web && python3 -m http.server 8000
    /// in a terminal first, same as every Python capture script so far.
    func load(baseURL: URL, engine: String = "p5") async throws {
        let pageURL = baseURL.appendingPathComponent("engines/\(engine).html")
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
        // Bumped from 15s -> 60s as a diagnostic: regl.html loaded fine and
        // fast in a real Safari tab (confirmed manually), but consistently
        // timed out here through OffscreenRenderWindow specifically. That
        // page is far heavier than the others (~67KB, all shader source
        // inline) -- this widened timeout is to determine whether offscreen
        // WKWebView is genuinely slower to become interactive for a page
        // this size, or whether it's actually stalled and no timeout length
        // will help. If this still times out at 60s, it's not a speed
        // problem -- see WebRenderService's header comment re: offscreen
        // WKWebView being an unverified/known-soft-spot rendering context.
        try await waitFor(jsCondition: "document.getElementById('anim') !== null", timeoutSeconds: 60,
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
        do {
            try await waitFor(
                jsCondition: "Array.from(document.getElementById('anim').options).some(o => o.value === '\(key)')",
                timeoutSeconds: 15,
                description: "<option value='\(key)'> to exist in #anim"
            )
        } catch RenderError.timedOut {
            // Distinguish "this animation doesn't belong to the currently
            // loaded engine's page" from a generic timeout -- each engine
            // page builds #anim from its own hardcoded ANIMATION_FILES
            // list (see web/engines/<engine>.html), so a name that's valid
            // for one engine will never appear in another's dropdown, no
            // matter how long we wait. Read back the options that DID load
            // so the error names what's actually available instead of just
            // "not found".
            let available = (try? await runReturningString("""
                Array.from(document.getElementById('anim').options).map(o => o.value).join(', ')
            """)) ?? nil
            throw RenderError.javaScriptFailed(
                "Animation '\(key)' is not available on this engine page. "
                + "Available on this page: \(available ?? "(could not read #anim options)"). "
                + "Check that --animation matches the currently loaded --engine."
            )
        }

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
    ///
    /// steppable-only. Realtime engines (threejs/canvas2d/pixi/svg) have no
    /// _setupDone equivalent -- see RenderMode in main.swift for why -- so
    /// this uses a DOM-presence check specific to each: threejs/canvas2d/pixi
    /// each create their <canvas> element fresh inside switchAnim(), so its
    /// existence is real signal the animation has actually initialized, not
    /// just a guessed delay. svg's #svgroot exists in static markup from
    /// page load, so presence alone proves nothing there -- checking for at
    /// least one child element is the equivalent signal (setup() is what
    /// populates it).
    func waitForSetupDone(engine: String = "p5", timeoutSeconds: TimeInterval = 15) async throws {
        switch engineRenderModes[engine] {
        case .steppable, .none:
            try await waitFor(
                jsCondition: "window.currentSketch && window.currentSketch._setupDone === true",
                timeoutSeconds: timeoutSeconds,
                description: "window.currentSketch._setupDone"
            )
        case .realtime:
            let jsCondition = engine == "svg"
                ? "document.getElementById('svgroot') && document.getElementById('svgroot').children.length > 0"
                : "document.querySelector('canvas') !== null"
            try await waitFor(
                jsCondition: jsCondition,
                timeoutSeconds: timeoutSeconds,
                description: "\(engine) animation to initialize (canvas/svg content to appear)"
            )
        }
    }

    /// Mirrors: window.currentSketch.noiseSeed(seed)
    /// Must be called before the first redraw(). Only matters once this
    /// service is driven by multiple parallel instances later -- see
    /// capture_fast_parallel.py's docstring for the full explanation of why
    /// (p5's noise() otherwise seeds itself from Math.random() on first use).
    ///
    /// steppable-only -- realtime engines have no seeded-noise equivalent
    /// exposed (see the per-engine audit in the RenderMode doc comment), so
    /// this is a deliberate no-op for them rather than a call that would
    /// throw against a page with no window.currentSketch at all.
    func setNoiseSeed(_ seed: Int, engine: String = "p5") async throws {
        guard engineRenderModes[engine] != .realtime else { return }
        try await run("window.currentSketch.noiseSeed(\(seed));")
    }

    /// Mirrors: window.currentSketch.noLoop()
    ///
    /// steppable-only. Realtime engines are captured WHILE their own
    /// requestAnimationFrame loop keeps running at real wall-clock speed --
    /// that loop is the entire point for these engines (see RenderMode) --
    /// so there is deliberately nothing to stop here.
    func stopAutomaticLoop(engine: String = "p5") async throws {
        guard engineRenderModes[engine] != .realtime else { return }
        try await run("window.currentSketch.noLoop();")
    }

    /// Force-hides the #ui overlay deterministically, mirroring the
    /// original Python capture scripts' `page.add_style_tag(content=
    /// "#ui{display:none !important}")`. This was missing from the Swift
    /// pipeline entirely -- every render until this fix relied solely on
    /// ui-autohide.js's ambient 15-second idle timer, which is REAL
    /// wall-clock time, not simulated frame count. At ~90ms/frame capture,
    /// 15 real seconds is only ~167 simulated frames, so every render
    /// showed controls for its first ~167 frames before the timer fired.
    /// Worse for parallel workers: each is a fresh process with its own
    /// fresh 15-second timer, so every worker's segment -- not just the
    /// very start of the whole piece -- would show this same flash at
    /// every boundary in the final concatenated video.
    ///
    /// Call this after selectAnimation/selectPalette (same ordering lesson
    /// as hiding too early breaking Playwright's actionability checks --
    /// this JS-based approach may not have that exact problem, but keeping
    /// the same proven ordering rather than assuming this context is exempt).
    func hideControls() async throws {
        try await run("""
            (() => {
                const el = document.getElementById('ui');
                if (el) el.style.setProperty('display', 'none', 'important');
            })();
        """)
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

// MARK: - WKScriptMessageHandler (console bridge)

extension WebRenderService: WKScriptMessageHandler {
    // WKScriptMessageHandler callbacks are NOT guaranteed to arrive on the
    // main thread/actor per Apple's docs, despite this whole class being
    // @MainActor -- hence the explicit Task { @MainActor in ... } hop below
    // rather than assuming this method itself runs on the main actor just
    // because the class declaration says so.
    //
    // Writes directly to stderr rather than through AppLog/os.Logger: this
    // file is compiled into BOTH the FormaCapture GUI target and the CLI
    // target, and the CLI's worker processes each redirect their own
    // stderr to a per-worker .log file (see main.swift's orchestrator).
    // os.Logger output goes to the unified logging system instead --
    // viewable via Console.app/`log stream`, NOT stderr -- so it would
    // never actually land in those .log files, defeating the whole point
    // of this bridge. Duplicating main.swift's two-line stderr-write
    // instead of calling its errLog()/timestampedLog() directly, since
    // those are CLI-target-only and this file must stay buildable in the
    // GUI target too (same class of mistake as the earlier RenderMode
    // cross-target scoping bug -- not repeating it here).
    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                            didReceive message: WKScriptMessage) {
        guard message.name == Self.consoleBridgeHandlerName,
              let body = message.body as? [String: Any],
              let level = body["level"] as? String,
              let text = body["text"] as? String else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(formatter.string(from: Date()))] [console.\(level)] \(text)\n"
        FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
    }
}
