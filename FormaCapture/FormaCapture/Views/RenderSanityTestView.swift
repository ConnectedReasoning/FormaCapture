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

                Button(viewModel.isRunning ? "Running…" : "Capture test frame") {
                    Task { await viewModel.captureTestFrame() }
                }
                .disabled(viewModel.isRunning)

                Button(viewModel.isRunning ? "Running…" : "Compare capture methods") {
                    Task { await viewModel.compareCaptureMethods() }
                }
                .disabled(viewModel.isRunning)

                Spacer()

                if let maxDrift = viewModel.maxDrift {
                    Text(maxDrift < 0.000001 ? "Frame timing exact" : "Drift: \(maxDrift)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(maxDrift < 0.000001 ? .green : .orange)
                }
            }

            if let diffResult = viewModel.pixelDiffResult {
                Text(diffResult)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(diffResult.contains("SIGNIFICANTLY") ? .red : .primary)
            }

            if viewModel.snapshotCompareImage != nil || viewModel.pixelBufferCompareImage != nil {
                HStack(spacing: 12) {
                    VStack {
                        Text("takeSnapshot() -- baseline").font(.caption2).foregroundStyle(.secondary)
                        if let img = viewModel.snapshotCompareImage {
                            Image(nsImage: img).resizable().scaledToFit()
                        }
                    }
                    VStack {
                        Text("CALayer.render(in:) -- candidate").font(.caption2).foregroundStyle(.secondary)
                        if let img = viewModel.pixelBufferCompareImage {
                            Image(nsImage: img).resizable().scaledToFit()
                        }
                    }
                }
                .frame(maxHeight: 160)
            }

            if let captured = viewModel.lastCapturedImage {
                Image(nsImage: captured)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 160)
                    .border(Color.gray.opacity(0.3))
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
        .frame(minWidth: 900, minHeight: 900)
    }
}
