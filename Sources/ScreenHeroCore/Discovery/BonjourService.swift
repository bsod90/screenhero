import Foundation
import Network

/// Bonjour service for LAN discovery of ScreenHero hosts
public actor BonjourService {
    /// Service type for ScreenHero
    public static let serviceType = "_screenhero._udp."

    /// Service domain
    public static let serviceDomain = "local."

    private var browser: NWBrowser?
    private var listener: NWListener?
    private var advertiser: NWListener?
    private let queue = DispatchQueue(label: "com.screenhero.bonjour")

    private var discoveredHosts: [DiscoveredHost] = []
    private var hostsContinuation: AsyncStream<[DiscoveredHost]>.Continuation?

    public init() {}

    // MARK: - Host Discovery (Viewer Side)

    /// Start browsing for available hosts
    public func startBrowsing() async throws -> AsyncStream<[DiscoveredHost]> {
        let descriptor = NWBrowser.Descriptor.bonjour(type: Self.serviceType, domain: Self.serviceDomain)
        let params = NWParameters()
        params.includePeerToPeer = true

        browser = NWBrowser(for: descriptor, using: params)

        let stream = AsyncStream<[DiscoveredHost]> { continuation in
            self.hostsContinuation = continuation
        }

        browser?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            Task {
                switch state {
                case .ready:
                    break
                case .failed(let error):
                    print("Browser failed: \(error)")
                default:
                    break
                }
            }
        }

        browser?.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self = self else { return }
            Task {
                await self.handleBrowseResults(results)
            }
        }

        browser?.start(queue: queue)

        return stream
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) async {
        var hosts: [DiscoveredHost] = []

        for result in results {
            if case .service(let name, let type, let domain, _) = result.endpoint {
                let host = DiscoveredHost(
                    id: name,
                    name: name,
                    serviceType: type,
                    domain: domain,
                    endpoint: result.endpoint
                )
                hosts.append(host)
            }
        }

        discoveredHosts = hosts
        hostsContinuation?.yield(hosts)
    }

    /// Stop browsing for hosts
    public func stopBrowsing() async {
        browser?.cancel()
        browser = nil
        hostsContinuation?.finish()
        hostsContinuation = nil
    }

    /// Resolve a discovered host to get connection details
    public func resolve(_ host: DiscoveredHost) async throws -> ResolvedHost {
        let connection = NWConnection(to: host.endpoint, using: .udp)

        return try await withCheckedThrowingContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let endpoint = connection.currentPath?.remoteEndpoint,
                       case .hostPort(let resolvedHost, let port) = endpoint {
                        let resolved = ResolvedHost(
                            name: host.name,
                            host: resolvedHost.debugDescription,
                            port: port.rawValue
                        )
                        connection.cancel()
                        continuation.resume(returning: resolved)
                    } else {
                        connection.cancel()
                        continuation.resume(throwing: NetworkTransportError.connectionFailed("Could not resolve endpoint"))
                    }
                case .failed(let error):
                    connection.cancel()
                    continuation.resume(throwing: NetworkTransportError.connectionFailed(error.localizedDescription))
                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }

    // MARK: - Service Advertising (Host Side)

    /// Start advertising this host
    public func startAdvertising(name: String, port: UInt16, metadata: [String: String] = [:]) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NetworkTransportError.invalidAddress
        }

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        advertiser = try NWListener(using: params, on: nwPort)

        // Set up TXT record with metadata
        var txtRecord = NWTXTRecord()
        for (key, value) in metadata {
            txtRecord[key] = value
        }

        let service = NWListener.Service(
            name: name,
            type: Self.serviceType,
            domain: Self.serviceDomain,
            txtRecord: txtRecord
        )

        advertiser?.service = service

        return try await withCheckedThrowingContinuation { continuation in
            advertiser?.stateUpdateHandler = { [weak self] state in
                guard self != nil else { return }

                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: NetworkTransportError.connectionFailed(error.localizedDescription))
                default:
                    break
                }
            }

            advertiser?.start(queue: queue)
        }
    }

    /// Update the advertised metadata
    public func updateMetadata(_ metadata: [String: String]) async {
        var txtRecord = NWTXTRecord()
        for (key, value) in metadata {
            txtRecord[key] = value
        }

        if let service = advertiser?.service {
            advertiser?.service = NWListener.Service(
                name: service.name,
                type: service.type,
                domain: service.domain,
                txtRecord: txtRecord
            )
        }
    }

    /// Stop advertising
    public func stopAdvertising() async {
        advertiser?.cancel()
        advertiser = nil
    }

    // MARK: - Types

    /// A discovered host on the network
    public struct DiscoveredHost: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let serviceType: String
        public let domain: String
        public let endpoint: NWEndpoint

        public init(id: String, name: String, serviceType: String, domain: String, endpoint: NWEndpoint) {
            self.id = id
            self.name = name
            self.serviceType = serviceType
            self.domain = domain
            self.endpoint = endpoint
        }
    }

    /// A resolved host with connection details
    public struct ResolvedHost: Sendable {
        public let name: String
        public let host: String
        public let port: UInt16

        public init(name: String, host: String, port: UInt16) {
            self.name = name
            self.host = host
            self.port = port
        }
    }
}
