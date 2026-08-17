//
//  OffscreenRenderWindow.swift
//  FormaCapture
//
//  Hosts a WKWebView inside a real, live NSWindow that's positioned off any
//  physical screen's visible bounds, rather than being a fully detached/
//  unattached WKWebView. That distinction matters: a WKWebView with no
//  window at all was the original unverified risk from the start of this
//  project (detached WKWebViews are a known WebKit soft spot), which is why
//  every capture method validated so far was tested with a real, visible
//  window. This uses a real window -- WebKit gets whatever it needs from
//  being part of an actual window hierarchy -- it's just not placed
//  anywhere a person would see it.
//
//  This is a NEW, not-yet-validated variable on its own, distinct from
//  everything already proven. Confirm it produces pixel-identical output
//  to the on-screen path (see RenderSanityTestViewModel.compareOffscreenCapture())
//  before trusting it for a real render.
//

import AppKit
import WebKit

@MainActor
final class OffscreenRenderWindow {
    let window: NSWindow
    let webView: WKWebView

    init(width: CGFloat, height: CGFloat) {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: config)
        webView.wantsLayer = true

        // Positioned far outside any physical screen's coordinate space --
        // a real window the window server tracks and composites normally,
        // just nowhere a person would ever see it. Deliberately not
        // alphaValue = 0 at a normal on-screen position -- staying fully
        // off-screen avoids any interaction with Mission Control, screen
        // recording, or display-sleep behavior a transparent-but-present
        // window might have.
        //
        // UNVERIFIED: backingScaleFactor is normally derived from whichever
        // physical screen a window sits on. A window out here isn't on any
        // screen, so what this returns (correctly inherited 2.0, or a
        // silent fallback to 1.0) is genuinely unknown until tested. If
        // captures come back at half the expected resolution, this is
        // where to look first.
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.hasShadow = false

        self.window = window
        self.webView = webView

        // orderFront, not makeKeyAndOrderFront -- becomes a real, live
        // window WebKit can render into, without stealing keyboard focus
        // from whatever window is actually in use.
        window.orderFront(nil)
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }
}
