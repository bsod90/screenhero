import SwiftUI
import ScreenHeroCore

@available(macOS 13.0, *)
public struct HostMainView: View {
    @StateObject private var viewModel = HostViewModel()

    public init() {}

    public var body: some View {
        VStack(spacing: 20) {
            headerSection

            if !viewModel.isStreaming {
                configurationSection
            }

            streamingControls

            if let code = viewModel.currentPairingCode {
                pairingCodeSection(code: code)
            }

            if let error = viewModel.errorMessage {
                errorSection(error: error)
            }

            Spacer()
        }
        .padding()
        .frame(minWidth: 400, minHeight: 500)
        .task {
            await viewModel.initialize()
        }
    }

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "display")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("ScreenHero Host")
                .font(.title)
                .fontWeight(.bold)

            if viewModel.isStreaming {
                VStack(spacing: 4) {
                    Label("Streaming", systemImage: "antenna.radiowaves.left.and.right")
                        .foregroundColor(.green)

                    Text("Multicast: \(MulticastConfig.groupAddress):\(MulticastConfig.defaultPort)")
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var configurationSection: some View {
        GroupBox("Configuration") {
            VStack(alignment: .leading, spacing: 12) {
                // Display picker
                if !viewModel.availableDisplays.isEmpty {
                    Picker("Display", selection: $viewModel.selectedDisplayIndex) {
                        ForEach(Array(viewModel.availableDisplays.enumerated()), id: \.offset) { index, display in
                            Text("Display \(index + 1) (\(display.width)x\(display.height))")
                                .tag(index)
                        }
                    }
                }

                // Resolution preset picker
                Picker("Quality", selection: Binding(
                    get: { viewModel.streamConfig.codec == .hevc ? 1 : 0 },
                    set: { viewModel.streamConfig = $0 == 1 ? .uhd4k60 : .hd1080p60 }
                )) {
                    Text("1080p60 (H.264)").tag(0)
                    Text("4K60 (HEVC)").tag(1)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var streamingControls: some View {
        HStack(spacing: 16) {
            if viewModel.isStreaming {
                Button(action: {
                    Task { await viewModel.stopStreaming() }
                }) {
                    Label("Stop Streaming", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button(action: {
                    Task { await viewModel.startStreaming() }
                }) {
                    Label("Start Streaming", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            }

            if viewModel.isStreaming && viewModel.currentPairingCode == nil {
                Button(action: {
                    Task { await viewModel.generatePairingCode() }
                }) {
                    Label("Generate Pairing Code", systemImage: "qrcode")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func pairingCodeSection(code: String) -> some View {
        GroupBox("Pairing Code") {
            VStack(spacing: 8) {
                Text(code)
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                    .foregroundColor(.accentColor)

                Text("Enter this code on the viewer to connect")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
        }
    }

    private func errorSection(error: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
            Text(error)
                .foregroundColor(.red)
        }
        .padding()
        .background(Color.red.opacity(0.1))
        .cornerRadius(8)
    }
}
