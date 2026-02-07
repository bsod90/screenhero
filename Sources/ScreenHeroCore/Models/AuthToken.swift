import Foundation

/// Session authentication token
public struct AuthToken: Sendable, Codable, Equatable {
    /// Unique token identifier
    public let id: UUID

    /// Host that generated this token
    public let hostId: UUID

    /// Viewer this token is issued to
    public let viewerId: UUID

    /// When the token was created
    public let createdAt: Date

    /// When the token expires
    public let expiresAt: Date

    /// HMAC signature of the token fields
    public let signature: Data

    public init(
        id: UUID = UUID(),
        hostId: UUID,
        viewerId: UUID,
        createdAt: Date = Date(),
        expiresAt: Date,
        signature: Data
    ) {
        self.id = id
        self.hostId = hostId
        self.viewerId = viewerId
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.signature = signature
    }

    /// Whether the token has expired
    public var isExpired: Bool {
        Date() > expiresAt
    }

    /// Data to sign (all fields except signature)
    public var dataToSign: Data {
        var data = Data()
        data.append(contentsOf: id.uuidString.utf8)
        data.append(contentsOf: hostId.uuidString.utf8)
        data.append(contentsOf: viewerId.uuidString.utf8)
        data.append(contentsOf: "\(createdAt.timeIntervalSince1970)".utf8)
        data.append(contentsOf: "\(expiresAt.timeIntervalSince1970)".utf8)
        return data
    }
}

/// Pairing code for initial connection
public struct PairingCode: Sendable, Equatable {
    /// The code string (e.g., "ABCD-1234")
    public let code: String

    /// When the code expires
    public let expiresAt: Date

    /// Host ID that generated this code
    public let hostId: UUID

    public init(code: String, expiresAt: Date, hostId: UUID) {
        self.code = code
        self.expiresAt = expiresAt
        self.hostId = hostId
    }

    /// Whether the code has expired
    public var isExpired: Bool {
        Date() > expiresAt
    }

    /// Generate a random pairing code
    public static func generate(hostId: UUID, validFor duration: TimeInterval = 300) -> PairingCode {
        let letters = "ABCDEFGHJKLMNPQRSTUVWXYZ"
        let numbers = "23456789"

        let letterPart = String((0..<4).map { _ in letters.randomElement()! })
        let numberPart = String((0..<4).map { _ in numbers.randomElement()! })

        return PairingCode(
            code: "\(letterPart)-\(numberPart)",
            expiresAt: Date().addingTimeInterval(duration),
            hostId: hostId
        )
    }
}
