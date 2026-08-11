# FormaCapture

A native macOS app for rendering [FormaProjection](https://connectedreasoning.com) animations to video, driving the browser frame-by-frame instead of recording it in real time.

Status: early. The render/drive layer works. Capture and encode don't exist yet. Don't expect a finished tool here.

## Purpose

FormaProjection's animations run in a browser at 3840x2160, 60fps. Getting them out as clean video files without a human babysitting a recording for an hour turned out to be a harder problem than it sounds.

The first approach was Playwright driving headless Chromium: manually step the animation's `frameCount`, screenshot each frame, stitch with ffmpeg. That part worked. What didn't work was speed. Measured on real hardware, PNG encoding plus the DevTools Protocol round-trip to pull each frame out of the browser cost about 290ms per frame, regardless of how fast the animation itself rendered (which was under 5ms per frame). Parallelizing across workers helped, but never got past roughly real-time. The whole premise of "faster than real time, no human required" didn't hold up once it was actually measured. OBS recording in real time, an hour for an hour of footage, ended up being the more practical choice for one-off renders.

This project is the next attempt at the original goal. Playwright's bottleneck was the browser automation protocol, not headless rendering itself. A native app using `WKWebView` in-process, pulling frames directly via `CVPixelBuffer` and encoding with hardware VideoToolbox, removes both the PNG step and the protocol round-trip. Same rendering, same JS-driven frame-stepping trick, but without the two things that made Playwright slow.

Whether that actually beats real time hasn't been proven yet. That's what this repo is for.

## Architecture

Same shape as [Planzu](https://github.com/manuelhernandez/Planzu) and [Intervallo](https://github.com/manuelhernandez/Intervallo): MVVM, Models, Model Stores, Services.

```
App/            App entry point
Models/         RenderJob, AnimationCatalog, PaletteCatalog
Model Stores/   Persisted render queue and history
Services/       WebRenderService, FrameCaptureService, VideoEncodingService,
                RenderCoordinatorService, LocalServerService
ViewModels/     Bridge Services/Stores to the UI
Views/          SwiftUI
Utilities/      AppLog (os.Logger)
```

Only `WebRenderService` exists right now.

## Current status

**Built and needs testing:** `WebRenderService` owns a `WKWebView` and drives it through the same sequence the Python capture scripts used — select animation, select palette, verify the palette actually applied, wait for `p5.js` setup to finish, then manually step `frameCount` and call `redraw()` frame by frame. There's a sanity-test view that runs 600 steps and logs expected-vs-actual elapsed time per frame, same drift check the Python version did.

**Not built yet:** frame capture into a pixel buffer, video encoding, the render coordinator that ties them together, the render queue, and any real UI.

**Not yet verified — the actual open question this repo exists to answer:** whether `WKWebView` renders reliably when driven this way. Detached, off-screen `WKWebView` instances are a known soft spot in WebKit. This app currently keeps the web view visible in a real window so that can be confirmed by eye before anything gets built on top of it.

## Requirements

- macOS 12+ (needed for the async `evaluateJavaScript` API)
- Xcode
- A local copy of FormaProjection's `web/web` folder, served over HTTP — this app does not yet serve files itself, it points at `http://127.0.0.1:8000`

Sandboxed apps can't make network calls, including to localhost, without the entitlement for it. If the web view fails to load with no obvious error, check Signing & Capabilities → App Sandbox → Outgoing Connections (Client).

## Running it

```
cd web/web
python3 -m http.server 8000
```

Then build and run in Xcode, and hit "Run sanity test." The web view pane should show the animation actually rendering. The log below it should end in "Frame timing confirmed exact."

## Related

- [FormaProjection](https://github.com/manuelhernandez/FormaProjection) — the animation platform this renders
- The Playwright-based capture scripts that came before this live in FormaProjection's own repo, kept for reference and for anyone who wants real-time-speed unattended capture without building a native app
