import Foundation
import ScreenHeroCore
import SwiftUI
import CoreVideo

/// View model for the viewer application
@MainActor
public class ViewerViewModel: ObservableObject {
    @Published public var isConnected = false
    @Published public var isSearching = false
    @Published public var discoveredHosts: [BonjourService.DiscoveredHost] = []
    @Published public var selectedHost: BonjourService.DiscoveredHost?
    @Published public var pairingCode: String = ""
    @Published public var errorMessage: String?
    @Published public var currentFrame: CGImage?
    @Published public var statistics: ReceiveStatistics?

    private let bonjourService = BonjourService()
    private let pairingManager = PairingManager()
    private let viewerId = UUID()
    private var pipeline: ReceivingPipeline?
    private var searchTask: Task<Void, Never>?

    public init() {}

    public func startSearching() async {
        guard !isSearching else { return }
        isSearching = true
        discoveredHosts = []

        do {
            let hosts = try await bonjourService.startBrowsing()

            searchTask = Task {
                for await hostList in hosts {
                    await MainActor.run {
                        self.discoveredHosts = hostList
                    }
                }
            }
        } catch {
            errorMessage = "Failed to search for hosts: \(error.localizedDescription)"
            isSearching = false
        }
    }

    public func stopSearching() async {
        searchTask?.cancel()
        searchTask = nil
        await bonjourService.stopBrowsing()
        isSearching = false
    }

    public func connect(to host: BonjourService.DiscoveredHost) async {
        selectedHost = host

        do {
            // Resolve host to get connection details (for metadata)
            let resolved = try await bonjourService.resolve(host)

            // Create stream config from host metadata
            let config = StreamConfig.hd1080p60 // TODO: Get from host metadata

            // Create multicast receiver - listens on multicast group
            let receiver = UDPReceiver(
                port: resolved.port,
                multicastGroup: MulticastConfig.groupAddress
            )
            let decoder = VideoToolboxDecoder()

            pipeline = ReceivingPipeline(
                receiver: receiver,
                decoder: decoder,
                config: config
            )

            // Set up frame handler
            await pipeline?.setFrameHandler { [weak self] pixelBuffer in
                await self?.handleFrame(pixelBuffer)
            }

            // Start receiving
            try await pipeline?.start()
            isConnected = true

            // Stop searching
            await stopSearching()

        } catch {
            errorMessage = "Failed to connect: \(error.localizedDescription)"
        }
    }

    private func handleFrame(_ pixelBuffer: CVPixelBuffer) async {
        // Convert pixel buffer to CGImage for display
        if let image = createCGImage(from: pixelBuffer) {
            await MainActor.run {
                self.currentFrame = image
            }
        }

        // Update statistics
        if let stats = await pipeline?.statistics {
            await MainActor.run {
                self.statistics = stats
            }
        }
    }

    private func createCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        return context.createCGImage(ciImage, from: ciImage.extent)
    }

    public func disconnect() async {
        await pipeline?.stop()
        pipeline = nil
        isConnected = false
        selectedHost = nil
        currentFrame = nil
        statistics = nil
    }

    /// Connect directly to multicast stream without host discovery
    /// Useful for testing on same machine or when host is known
    public func connectDirect(port: UInt16 = MulticastConfig.defaultPort) async {
        print("[Viewer] Connecting to multicast \(MulticastConfig.groupAddress):\(port)...")
        do {
            let config = StreamConfig.hd1080p60

            // Create multicast receiver
            let receiver = UDPReceiver(
                port: port,
                multicastGroup: MulticastConfig.groupAddress
            )
            let decoder = VideoToolboxDecoder()

            pipeline = ReceivingPipeline(
                receiver: receiver,
                decoder: decoder,
                config: config
            )

            // Set up frame handler
            await pipeline?.setFrameHandler { [weak self] pixelBuffer in
                await self?.handleFrame(pixelBuffer)
            }

            // Start receiving
            try await pipeline?.start()
            print("[Viewer] Connected to multicast stream")
            isConnected = true

            // Stop searching if active
            await stopSearching()

        } catch {
            let err = "Failed to connect: \(error)"
            print("[Viewer] ERROR: \(err)")
            errorMessage = err
        }
    }

    /// Connect to a specific host IP and port using unicast UDP
    public func connectToHost(host: String, port: UInt16) async {
        print("[Viewer] Connecting to \(host):\(port)...")
        do {
            let config = StreamConfig.hd1080p60

            // Create unicast receiver listening on the specified port
            let receiver = UDPReceiver(
                port: port,
                multicastGroup: host  // For unicast, this is the host we expect to receive from
            )
            let decoder = VideoToolboxDecoder()

            pipeline = ReceivingPipeline(
                receiver: receiver,
                decoder: decoder,
                config: config
            )

            // Set up frame handler
            await pipeline?.setFrameHandler { [weak self] pixelBuffer in
                await self?.handleFrame(pixelBuffer)
            }

            // Start receiving
            try await pipeline?.start()
            print("[Viewer] Connected to \(host):\(port)")
            isConnected = true

            // Stop searching if active
            await stopSearching()

        } catch {
            let err = "Failed to connect to \(host):\(port): \(error)"
            print("[Viewer] ERROR: \(err)")
            errorMessage = err
        }
    }

    public func submitPairingCode() async {
        guard let host = selectedHost else { return }

        // TODO: Implement pairing code submission to host
        // This would require establishing a connection to the host first
        // and exchanging the pairing code for a token
    }
}
