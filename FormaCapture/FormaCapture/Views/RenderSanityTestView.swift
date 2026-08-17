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
        ScrollView {
            VStack(spacing: 12) {
                Text("If this pane shows the animation rendering, WKWebView-in-a-window works.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Now at true 3840x2160 (1920x1080 points @ 2x retina) --
                // matches the actual target resolution, not a scaled-down
                // stand-in. This is the same webView/pipeline already
                // validated at 640x360, just resized via the normal SwiftUI
                // .frame() modifier -- not manually poking the underlying
                // NSView's frame, which would risk fighting SwiftUI's own
                // layout pass. Wrapped in ScrollView above since a window
                // this size can't assume it fits on every screen.
                WebViewContainer(webView: viewModel.webView)
                    .frame(width: 1920, height: 1080)
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

                    Button(viewModel.isRunning ? "Running…" : "Render test clip (off-screen)") {
                        Task { await viewModel.renderTestClip() }
                    }
                    .disabled(viewModel.isRunning)

                    Button(viewModel.isRunning ? "Running…" : "Compare GPU capture (experimental)") {
                        Task { await viewModel.compareGPUCaptureMethod() }
                    }
                    .disabled(viewModel.isRunning)

                    Button(viewModel.isRunning ? "Running…" : "Compare off-screen rendering") {
                        Task { await viewModel.compareOffscreenCapture() }
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

                if let diffResult = viewModel.gpuDiffResult {
                    Text(diffResult)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(diffResult.contains("SIGNIFICANTLY") ? .red : .primary)
                }

                if viewModel.gpuBaselineImage != nil || viewModel.gpuCompareImage != nil {
                    HStack(spacing: 12) {
                        VStack {
                            Text("CALayer.render(in:) -- baseline").font(.caption2).foregroundStyle(.secondary)
                            if let img = viewModel.gpuBaselineImage {
                                Image(nsImage: img).resizable().scaledToFit()
                            }
                        }
                        VStack {
                            Text("CARenderer/Metal -- experimental").font(.caption2).foregroundStyle(.secondary)
                            if let img = viewModel.gpuCompareImage {
                                Image(nsImage: img).resizable().scaledToFit()
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                }

                if let diffResult = viewModel.offscreenDiffResult {
                    Text(diffResult)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(diffResult.contains("SIGNIFICANTLY") ? .red : .primary)
                }

                if viewModel.offscreenBaselineImage != nil || viewModel.offscreenCandidateImage != nil {
                    HStack(spacing: 12) {
                        VStack {
                            Text("On-screen -- baseline").font(.caption2).foregroundStyle(.secondary)
                            if let img = viewModel.offscreenBaselineImage {
                                Image(nsImage: img).resizable().scaledToFit()
                            }
                        }
                        VStack {
                            Text("Off-screen window -- candidate").font(.caption2).foregroundStyle(.secondary)
                            if let img = viewModel.offscreenCandidateImage {
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

                Text(viewModel.log)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding()
        }
        .frame(minWidth: 1000, minHeight: 900)
    }
}
