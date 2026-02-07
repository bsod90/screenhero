import SwiftUI
import ScreenHeroCore

public struct ViewerMainView: View {
    @StateObject private var viewModel = ViewerViewModel()
    @State private var showManualConnect = false
    @State private var manualHost = ""
    @State private var manualPort = "5000"

    public init() {}

    public var body: some View {
        Group {
            if viewModel.isConnected {
                streamView
            } else {
                hostBrowserView
            }
        }
        .frame(minWidth: 800, minHeight: 600)
    }

    private var streamView: some View {
        ZStack {
            Color.black

            if let frame = viewModel.currentFrame {
                Image(decorative: frame, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView("Waiting for stream...")
                    .foregroundColor(.white)
            }

            // Overlay with statistics
            VStack {
                HStack {
                    Spacer()

                    if let stats = viewModel.statistics {
                        statisticsOverlay(stats: stats)
                    }
                }
                Spacer()

                HStack {
                    Button(action: {
                        Task { await viewModel.disconnect() }
                    }) {
                        Label("Disconnect", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)

                    Spacer()
                }
                .padding()
            }
        }
    }

    private func statisticsOverlay(stats: ReceiveStatistics) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text("Frames: \(stats.framesReceived)")
            Text("Latency: \(String(format: "%.1f", stats.averageLatencyMs))ms")
            Text("Data: \(String(format: "%.1f", stats.megabytesReceived))MB")
        }
        .font(.caption.monospaced())
        .padding(8)
        .background(Color.black.opacity(0.7))
        .foregroundColor(.white)
        .cornerRadius(8)
        .padding()
    }

    private var hostBrowserView: some View {
        VStack(spacing: 20) {
            headerSection

            if viewModel.isSearching {
                searchingSection
            } else {
                startSearchButton
            }

            if !viewModel.discoveredHosts.isEmpty {
                hostListSection
            }

            if let error = viewModel.errorMessage {
                errorSection(error: error)
            }

            Spacer()
        }
        .padding()
    }

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "tv")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("ScreenHero Viewer")
                .font(.title)
                .fontWeight(.bold)

            Text("Connect to a ScreenHero host to view their screen")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var searchingSection: some View {
        VStack(spacing: 12) {
            ProgressView()

            Text("Searching for hosts on local network...")
                .foregroundColor(.secondary)

            Button("Stop Searching") {
                Task { await viewModel.stopSearching() }
            }
            .buttonStyle(.bordered)
        }
    }

    private var startSearchButton: some View {
        VStack(spacing: 12) {
            Button(action: {
                Task { await viewModel.startSearching() }
            }) {
                Label("Search for Hosts", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("or")
                .foregroundColor(.secondary)

            Button(action: {
                Task { await viewModel.connectDirect() }
            }) {
                Label("Connect to Multicast", systemImage: "antenna.radiowaves.left.and.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Text("Listens on \(MulticastConfig.groupAddress):\(String(MulticastConfig.defaultPort))")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()
                .padding(.vertical, 8)

            // Manual IP:Port connection
            Button(action: {
                showManualConnect.toggle()
            }) {
                Label("Manual Connection", systemImage: "network")
            }
            .buttonStyle(.bordered)

            if showManualConnect {
                manualConnectSection
            }
        }
    }

    private var manualConnectSection: some View {
        GroupBox("Connect to IP:Port") {
            VStack(spacing: 12) {
                HStack {
                    TextField("Host IP", text: $manualHost)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)

                    Text(":")

                    TextField("Port", text: $manualPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                }

                Button(action: {
                    if let port = UInt16(manualPort) {
                        Task { await viewModel.connectToHost(host: manualHost, port: port) }
                    }
                }) {
                    Label("Connect", systemImage: "arrow.right.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(manualHost.isEmpty)
            }
            .padding(.vertical, 8)
        }
    }

    private var hostListSection: some View {
        GroupBox("Available Hosts") {
            List(viewModel.discoveredHosts) { host in
                HStack {
                    Image(systemName: "display")
                    Text(host.name)
                    Spacer()
                    Button("Connect") {
                        Task { await viewModel.connect(to: host) }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
            }
            .frame(height: 200)
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
