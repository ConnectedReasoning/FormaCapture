//
//  RenderSanityTestView.swift
//  FormaCapture
//
//  Step 1 validation screen. Shows the live WKWebView (so you can SEE
//  whether it's actually rendering -- that's the real unverified risk here)
//  plus a log mirroring capture_fast.py's per-frame drift output.
//

import SwiftUI

struct RenderSanityTestView: View {
    @StateObject private var viewModel = RenderSanityTestViewModel()

    var body: some View {
        VStack(spacing: 12) {
            Text("If this pane shows the animation rendering, WKWebView-in-a-window works.")
                .font(.caption)
                .foregroundStyle(.secondary)

            WebViewContainer(webView: viewModel.webView)
                .frame(width: 640, height: 360)   // scaled down for on-screen testing;
                                                    // real captures will use 3840x2160
                .border(Color.gray.opacity(0.3))

            HStack {
                Button(viewModel.isRunning ? "Running…" : "Run sanity test") {
                    Task { await viewModel.runSanityTest() }
                }
                .disabled(viewModel.isRunning)

                Spacer()

                if let maxDrift = viewModel.maxDrift {
                    Text(maxDrift < 0.000001 ? "Frame timing exact" : "Drift: \(maxDrift)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(maxDrift < 0.000001 ? .green : .orange)
                }
            }

            ScrollView {
                Text(viewModel.log)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 300)
        }
        .padding()
        .frame(minWidth: 700, minHeight: 640)
    }
}
