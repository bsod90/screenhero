import Foundation
import CryptoKit

/// Validates session tokens on the viewer side
public actor TokenValidator {
    private var knownTokens: [UUID: AuthToken] = [:]

    public init() {}

    /// Store a token received from a host
    public func store(_ token: AuthToken) {
        knownTokens[token.hostId] = token
    }

    /// Get a token for a specific host
    public func getToken(for hostId: UUID) -> AuthToken? {
        guard let token = knownTokens[hostId] else {
            return nil
        }

        // Don't return expired tokens
        if token.isExpired {
            knownTokens.removeValue(forKey: hostId)
            return nil
        }

        return token
    }

    /// Remove a token for a host
    public func removeToken(for hostId: UUID) {
        knownTokens.removeValue(forKey: hostId)
    }

    /// Check if we have a valid token for a host
    public func hasValidToken(for hostId: UUID) -> Bool {
        getToken(for: hostId) != nil
    }

    /// Remove all expired tokens
    public func pruneExpiredTokens() {
        let now = Date()
        knownTokens = knownTokens.filter { !$0.value.isExpired }
    }

    /// Clear all tokens
    public func clearAll() {
        knownTokens.removeAll()
    }
}
