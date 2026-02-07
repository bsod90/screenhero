import Foundation

/// Manages the pairing flow between host and viewer
public actor PairingManager {
    /// Current pairing code (host side)
    private var currentPairingCode: PairingCode?

    /// Token generator (host side)
    private var tokenGenerator: TokenGenerator?

    /// Known host tokens (viewer side)
    private var hostTokens: [UUID: AuthToken] = [:]

    /// Pairing timeout
    public static let defaultPairingTimeout: TimeInterval = 300 // 5 minutes

    public init() {}

    // MARK: - Host Side

    /// Initialize as host with a token generator
    public func initializeAsHost(hostId: UUID, secretKey: Data? = nil) {
        tokenGenerator = TokenGenerator(hostId: hostId, secretKey: secretKey)
    }

    /// Generate a new pairing code (host side)
    public func generatePairingCode(validFor duration: TimeInterval = defaultPairingTimeout) -> PairingCode? {
        guard let generator = tokenGenerator else {
            return nil
        }

        let code = PairingCode.generate(
            hostId: generator.currentHostId,
            validFor: duration
        )
        currentPairingCode = code
        return code
    }

    /// Validate a pairing code and generate a token (host side)
    public func validatePairingCode(
        _ code: String,
        viewerId: UUID
    ) async -> PairingResult {
        guard let currentCode = currentPairingCode else {
            return .failure(.noPendingPairing)
        }

        // Check expiration
        if currentCode.isExpired {
            currentPairingCode = nil
            return .failure(.codeExpired)
        }

        // Normalize and compare codes
        let normalizedInput = code.uppercased().replacingOccurrences(of: " ", with: "")
        let normalizedCode = currentCode.code.uppercased().replacingOccurrences(of: "-", with: "")
        let normalizedInputNoDash = normalizedInput.replacingOccurrences(of: "-", with: "")

        if normalizedInputNoDash != normalizedCode {
            return .failure(.invalidCode)
        }

        // Generate token
        guard let generator = tokenGenerator else {
            return .failure(.noPendingPairing)
        }

        let token = await generator.generate(for: viewerId)

        // Clear pairing code after successful use
        currentPairingCode = nil

        return .success(token)
    }

    /// Get current pairing code info (for display)
    public var pairingCodeInfo: (code: String, expiresIn: TimeInterval)? {
        guard let code = currentPairingCode, !code.isExpired else {
            return nil
        }

        let expiresIn = code.expiresAt.timeIntervalSinceNow
        return (code.code, expiresIn)
    }

    // MARK: - Viewer Side

    /// Store a received token (viewer side)
    public func storeHostToken(_ token: AuthToken) {
        hostTokens[token.hostId] = token
    }

    /// Get token for a host (viewer side)
    public func getHostToken(_ hostId: UUID) -> AuthToken? {
        guard let token = hostTokens[hostId], !token.isExpired else {
            hostTokens.removeValue(forKey: hostId)
            return nil
        }
        return token
    }

    /// Check if paired with a host (viewer side)
    public func isPaired(with hostId: UUID) -> Bool {
        getHostToken(hostId) != nil
    }

    /// Remove pairing with a host (viewer side)
    public func unpair(from hostId: UUID) {
        hostTokens.removeValue(forKey: hostId)
    }

    /// Clear all pairings (viewer side)
    public func clearAllPairings() {
        hostTokens.removeAll()
    }

    // MARK: - Token Validation (Host Side)

    /// Validate a token for an incoming connection (host side)
    public func validateToken(_ token: AuthToken) async -> TokenValidationResult {
        guard let generator = tokenGenerator else {
            return .invalidHost
        }
        return await generator.validate(token)
    }
}

/// Result of a pairing attempt
public enum PairingResult: Sendable {
    case success(AuthToken)
    case failure(PairingError)
}

/// Errors that can occur during pairing
public enum PairingError: Error, Sendable {
    case noPendingPairing
    case codeExpired
    case invalidCode
    case hostNotFound
}
