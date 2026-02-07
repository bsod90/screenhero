import Foundation
import ScreenHeroCore
import SwiftUI

/// View model for the host application
@available(macOS 13.0, *)
@MainActor
public class HostViewModel: ObservableObject {
    @Published public var isStreaming = false
    @Published public var currentPairingCode: String?
    @Published public var connectedViewers: [UUID] = []
    @Published public var selectedDisplayIndex = 0
    @Published public var availableDisplays: [DisplayInfo] = []
    @Published public var streamConfig: StreamConfig = .hd1080p60
    @Published public var errorMessage: String?

    private var pipeline: StreamingPipeline?
    private let pairingManager = PairingManager()
    private let bonjourService = BonjourService()
    private let hostId = UUID()

    public init() {}

    public func initialize() async {
        do {
            // Load available displays
            availableDisplays = try await ScreenCaptureKitSource.availableDisplays()

            // Initialize pairing manager
            await pairingManager.initializeAsHost(hostId: hostId)

        } catch {
            errorMessage = "Failed to initialize: \(error.localizedDescription)"
        }
    }

    public func generatePairingCode() async {
        guard let code = await pairingManager.generatePairingCode() else {
            errorMessage = "Failed to generate pairing code"
            return
        }
        currentPairingCode = code.code
    }

    public func startStreaming(port: UInt16 = MulticastConfig.defaultPort) async {
        guard !isStreaming else { return }

        do {
            // Get selected display
            let displayID: CGDirectDisplayID?
            if selectedDisplayIndex < availableDisplays.count {
                displayID = availableDisplays[selectedDisplayIndex].displayID
            } else {
                displayID = nil
            }

            // Create components
            let source = ScreenCaptureKitSource(config: streamConfig, displayID: displayID)
            let encoder = VideoToolboxEncoder()
            let sender = UDPSender(host: MulticastConfig.groupAddress, port: port)

            pipeline = StreamingPipeline(
                source: source,
                encoder: encoder,
                sender: sender,
                config: streamConfig
            )

            // Start advertising on Bonjour
            try await bonjourService.startAdvertising(
                name: Host.current().localizedName ?? "ScreenHero Host",
                port: port,
                metadata: [
                    "hostId": hostId.uuidString,
                    "width": String(streamConfig.width),
                    "height": String(streamConfig.height),
                    "fps": String(streamConfig.fps),
                    "codec": streamConfig.codec.rawValue
                ]
            )

            // Start streaming
            try await pipeline?.start()
            isStreaming = true

        } catch {
            errorMessage = "Failed to start streaming: \(error.localizedDescription)"
        }
    }

    public func stopStreaming() async {
        guard isStreaming else { return }

        await pipeline?.stop()
        await bonjourService.stopAdvertising()
        pipeline = nil
        isStreaming = false
    }

    public func getStatistics() async -> PipelineStatistics? {
        await pipeline?.statistics
    }

    public func validatePairingCode(_ code: String, viewerId: UUID) async -> AuthToken? {
        let result = await pairingManager.validatePairingCode(code, viewerId: viewerId)

        switch result {
        case .success(let token):
            connectedViewers.append(viewerId)
            return token
        case .failure:
            return nil
        }
    }
}
