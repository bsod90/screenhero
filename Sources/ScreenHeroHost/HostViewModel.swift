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

    // CLI configuration
    private let targetHost: String?
    private let port: UInt16

    public init(targetHost: String? = nil, port: UInt16 = 5000) {
        self.targetHost = targetHost
        self.port = port
    }

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

    public func startStreaming() async {
        guard !isStreaming else { return }

        do {
            let streamPort = port
            let streamTarget = targetHost ?? MulticastConfig.groupAddress

            print("[HostViewModel] Starting streaming to \(streamTarget):\(streamPort)...")

            // Get selected display
            let displayID: CGDirectDisplayID?
            if selectedDisplayIndex < availableDisplays.count {
                displayID = availableDisplays[selectedDisplayIndex].displayID
                print("[HostViewModel] Using display \(displayID!) (\(availableDisplays[selectedDisplayIndex].width)x\(availableDisplays[selectedDisplayIndex].height))")
            } else {
                displayID = nil
                print("[HostViewModel] Using default display")
            }

            // Create components
            print("[HostViewModel] Creating screen capture source...")
            let source = ScreenCaptureKitSource(config: streamConfig, displayID: displayID)

            print("[HostViewModel] Creating encoder...")
            let encoder = VideoToolboxEncoder()

            print("[HostViewModel] Creating UDP sender to \(streamTarget):\(streamPort)...")
            let sender = UDPSender(host: streamTarget, port: streamPort)

            pipeline = StreamingPipeline(
                source: source,
                encoder: encoder,
                sender: sender,
                config: streamConfig
            )

            // Start advertising on Bonjour (skip if unicast mode)
            if targetHost == nil {
                print("[HostViewModel] Starting Bonjour advertising...")
                try await bonjourService.startAdvertising(
                    name: Host.current().localizedName ?? "ScreenHero Host",
                    port: streamPort,
                    metadata: [
                        "hostId": hostId.uuidString,
                        "width": String(streamConfig.width),
                        "height": String(streamConfig.height),
                        "fps": String(streamConfig.fps),
                        "codec": streamConfig.codec.rawValue
                    ]
                )
                print("[HostViewModel] Bonjour advertising started")
            } else {
                print("[HostViewModel] Unicast mode - skipping Bonjour")
            }

            // Start streaming
            print("[HostViewModel] Starting pipeline...")
            try await pipeline?.start()
            print("[HostViewModel] Pipeline started successfully!")
            isStreaming = true

        } catch {
            let errorDesc = "Failed to start streaming: \(error)"
            print("[HostViewModel] ERROR: \(errorDesc)")
            errorMessage = errorDesc
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
