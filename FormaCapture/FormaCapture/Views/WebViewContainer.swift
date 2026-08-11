//
//  WebViewContainer.swift
//  FormaCapture
//
//  Thin NSViewRepresentable so a WKWebView owned by WebRenderService can be
//  displayed inside SwiftUI. Kept intentionally dumb -- all the actual
//  driving logic lives in WebRenderService, not here.
//

import SwiftUI
import WebKit

struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // No-op -- WebRenderService drives the view directly via JS.
    }
}
