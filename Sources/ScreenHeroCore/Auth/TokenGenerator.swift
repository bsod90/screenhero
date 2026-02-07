import Foundation
import CryptoKit

/// Generates and signs session tokens for authenticated streaming
public actor TokenGenerator {
    private let secretKey: SymmetricKey
    private let hostId: UUID

    /// Default token validity duration (24 hours)
    public static let defaultTokenDuration: TimeInterval = 24 * 60 * 60

    public init(hostId: UUID = UUID(), secretKey: Data? = nil) {
        self.hostId = hostId

        if let key = secretKey {
            self.secretKey = SymmetricKey(data: key)
        } else {
            // Generate a random 256-bit key
            self.secretKey = SymmetricKey(size: .bits256)
        }
    }

    /// Generate a session token for a viewer
    public func generate(
        for viewerId: UUID,
        duration: TimeInterval = TokenGenerator.defaultTokenDuration
    ) -> AuthToken {
        let now = Date()
        let expiresAt = now.addingTimeInterval(duration)

        let tokenId = UUID()

        // Create token without signature first
        var tokenData = Data()
        tokenData.append(contentsOf: tokenId.uuidString.utf8)
        tokenData.append(contentsOf: hostId.uuidString.utf8)
        tokenData.append(contentsOf: viewerId.uuidString.utf8)
        tokenData.append(contentsOf: String(format: "%.0f", now.timeIntervalSince1970).utf8)
        tokenData.append(contentsOf: String(format: "%.0f", expiresAt.timeIntervalSince1970).utf8)

        // Sign with HMAC-SHA256
        let signature = HMAC<SHA256>.authenticationCode(for: tokenData, using: secretKey)
        let signatureData = Data(signature)

        return AuthToken(
            id: tokenId,
            hostId: hostId,
            viewerId: viewerId,
            createdAt: now,
            expiresAt: expiresAt,
            signature: signatureData
        )
    }

    /// Validate a session token
    public func validate(_ token: AuthToken) -> TokenValidationResult {
        // Check expiration
        if token.isExpired {
            return .expired
        }

        // Check host ID
        if token.hostId != hostId {
            return .invalidHost
        }

        // Verify signature
        var tokenData = Data()
        tokenData.append(contentsOf: token.id.uuidString.utf8)
        tokenData.append(contentsOf: token.hostId.uuidString.utf8)
        tokenData.append(contentsOf: token.viewerId.uuidString.utf8)
        tokenData.append(contentsOf: String(format: "%.0f", token.createdAt.timeIntervalSince1970).utf8)
        tokenData.append(contentsOf: String(format: "%.0f", token.expiresAt.timeIntervalSince1970).utf8)

        let expectedSignature = HMAC<SHA256>.authenticationCode(for: tokenData, using: secretKey)

        if !token.signature.elementsEqual(Data(expectedSignature)) {
            return .invalidSignature
        }

        return .valid
    }

    /// Export the secret key (for persistence)
    public func exportSecretKey() -> Data {
        secretKey.withUnsafeBytes { Data($0) }
    }

    /// Get the host ID
    public nonisolated var currentHostId: UUID {
        hostId
    }
}

/// Result of token validation
public enum TokenValidationResult: Equatable, Sendable {
    case valid
    case expired
    case invalidHost
    case invalidSignature
}
