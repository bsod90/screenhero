import XCTest
@testable import ScreenHeroCore

final class AuthTests: XCTestCase {

    // MARK: - PairingCode Tests

    func testPairingCodeGeneration() {
        let hostId = UUID()
        let code = PairingCode.generate(hostId: hostId, validFor: 300)

        XCTAssertEqual(code.hostId, hostId)
        XCTAssertFalse(code.isExpired)
        XCTAssertEqual(code.code.count, 9) // XXXX-XXXX format
        XCTAssertTrue(code.code.contains("-"))
    }

    func testPairingCodeExpiration() {
        let hostId = UUID()
        let code = PairingCode.generate(hostId: hostId, validFor: -1) // Already expired

        XCTAssertTrue(code.isExpired)
    }

    func testPairingCodeFormat() {
        let hostId = UUID()

        // Generate many codes and verify format
        for _ in 0..<20 {
            let code = PairingCode.generate(hostId: hostId)
            let parts = code.code.split(separator: "-")

            XCTAssertEqual(parts.count, 2)
            XCTAssertEqual(parts[0].count, 4)
            XCTAssertEqual(parts[1].count, 4)

            // Verify characters are from expected sets
            let letters = CharacterSet(charactersIn: "ABCDEFGHJKLMNPQRSTUVWXYZ")
            let numbers = CharacterSet(charactersIn: "23456789")

            for char in parts[0] {
                XCTAssertTrue(letters.contains(char.unicodeScalars.first!))
            }
            for char in parts[1] {
                XCTAssertTrue(numbers.contains(char.unicodeScalars.first!))
            }
        }
    }

    // MARK: - TokenGenerator Tests

    func testTokenGeneration() async {
        let hostId = UUID()
        let viewerId = UUID()
        let generator = TokenGenerator(hostId: hostId)

        let token = await generator.generate(for: viewerId)

        XCTAssertEqual(token.hostId, hostId)
        XCTAssertEqual(token.viewerId, viewerId)
        XCTAssertFalse(token.isExpired)
        XCTAssertFalse(token.signature.isEmpty)
    }

    func testTokenValidation() async {
        let hostId = UUID()
        let viewerId = UUID()
        let generator = TokenGenerator(hostId: hostId)

        let token = await generator.generate(for: viewerId)
        let result = await generator.validate(token)

        XCTAssertEqual(result, .valid)
    }

    func testTokenValidationExpired() async {
        let hostId = UUID()
        let viewerId = UUID()
        let generator = TokenGenerator(hostId: hostId)

        // Generate with 0 duration (immediately expired)
        let token = await generator.generate(for: viewerId, duration: -1)
        let result = await generator.validate(token)

        XCTAssertEqual(result, .expired)
    }

    func testTokenValidationWrongHost() async {
        let hostId1 = UUID()
        let hostId2 = UUID()
        let viewerId = UUID()

        let generator1 = TokenGenerator(hostId: hostId1)
        let generator2 = TokenGenerator(hostId: hostId2)

        let token = await generator1.generate(for: viewerId)
        let result = await generator2.validate(token)

        XCTAssertEqual(result, .invalidHost)
    }

    func testTokenValidationTamperedSignature() async {
        let hostId = UUID()
        let viewerId = UUID()
        let generator = TokenGenerator(hostId: hostId)

        let token = await generator.generate(for: viewerId)

        // Tamper with the signature
        var tamperedSignatureData = token.signature
        tamperedSignatureData[0] ^= 0xFF

        let tamperedToken = AuthToken(
            id: token.id,
            hostId: token.hostId,
            viewerId: token.viewerId,
            createdAt: token.createdAt,
            expiresAt: token.expiresAt,
            signature: tamperedSignatureData
        )

        let result = await generator.validate(tamperedToken)
        XCTAssertEqual(result, .invalidSignature)
    }

    func testSecretKeyPersistence() async {
        let hostId = UUID()
        let viewerId = UUID()

        // Create generator and get its key
        let generator1 = TokenGenerator(hostId: hostId)
        let secretKey = await generator1.exportSecretKey()
        let token = await generator1.generate(for: viewerId)

        // Create new generator with same key
        let generator2 = TokenGenerator(hostId: hostId, secretKey: secretKey)
        let result = await generator2.validate(token)

        XCTAssertEqual(result, .valid)
    }

    // MARK: - TokenValidator Tests

    func testTokenStorage() async {
        let validator = TokenValidator()
        let hostId = UUID()
        let viewerId = UUID()

        let token = AuthToken(
            id: UUID(),
            hostId: hostId,
            viewerId: viewerId,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(3600),
            signature: Data([0x01, 0x02, 0x03])
        )

        await validator.store(token)

        let retrieved = await validator.getToken(for: hostId)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id, token.id)
    }

    func testTokenRemoval() async {
        let validator = TokenValidator()
        let hostId = UUID()

        let token = AuthToken(
            id: UUID(),
            hostId: hostId,
            viewerId: UUID(),
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(3600),
            signature: Data([0x01, 0x02, 0x03])
        )

        await validator.store(token)
        await validator.removeToken(for: hostId)

        let retrieved = await validator.getToken(for: hostId)
        XCTAssertNil(retrieved)
    }

    func testExpiredTokenNotReturned() async {
        let validator = TokenValidator()
        let hostId = UUID()

        let token = AuthToken(
            id: UUID(),
            hostId: hostId,
            viewerId: UUID(),
            createdAt: Date().addingTimeInterval(-3600),
            expiresAt: Date().addingTimeInterval(-1), // Already expired
            signature: Data([0x01, 0x02, 0x03])
        )

        await validator.store(token)

        let retrieved = await validator.getToken(for: hostId)
        XCTAssertNil(retrieved)
    }

    // MARK: - PairingManager Tests

    func testPairingFlow() async {
        let manager = PairingManager()
        let hostId = UUID()
        let viewerId = UUID()

        // Initialize as host
        await manager.initializeAsHost(hostId: hostId)

        // Generate pairing code
        let code = await manager.generatePairingCode()
        XCTAssertNotNil(code)

        // Validate code and get token
        let result = await manager.validatePairingCode(code!.code, viewerId: viewerId)

        switch result {
        case .success(let token):
            XCTAssertEqual(token.hostId, hostId)
            XCTAssertEqual(token.viewerId, viewerId)
            XCTAssertFalse(token.isExpired)
        case .failure(let error):
            XCTFail("Pairing should succeed: \(error)")
        }
    }

    func testPairingWithInvalidCode() async {
        let manager = PairingManager()
        let hostId = UUID()
        let viewerId = UUID()

        await manager.initializeAsHost(hostId: hostId)
        _ = await manager.generatePairingCode()

        let result = await manager.validatePairingCode("INVALID-CODE", viewerId: viewerId)

        switch result {
        case .success:
            XCTFail("Pairing should fail with invalid code")
        case .failure(let error):
            XCTAssertEqual(error, .invalidCode)
        }
    }

    func testPairingCodeExpiry() async {
        let manager = PairingManager()
        let hostId = UUID()
        let viewerId = UUID()

        await manager.initializeAsHost(hostId: hostId)
        _ = await manager.generatePairingCode(validFor: -1) // Already expired

        let result = await manager.validatePairingCode("XXXX-1234", viewerId: viewerId)

        switch result {
        case .success:
            XCTFail("Pairing should fail with expired code")
        case .failure(let error):
            XCTAssertEqual(error, .codeExpired)
        }
    }

    func testPairingCodeConsumed() async {
        let manager = PairingManager()
        let hostId = UUID()
        let viewerId = UUID()

        await manager.initializeAsHost(hostId: hostId)
        let code = await manager.generatePairingCode()!

        // First pairing succeeds
        let result1 = await manager.validatePairingCode(code.code, viewerId: viewerId)
        XCTAssertTrue(result1.isSuccess)

        // Second pairing with same code fails
        let result2 = await manager.validatePairingCode(code.code, viewerId: UUID())
        XCTAssertFalse(result2.isSuccess)
    }

    func testViewerTokenStorage() async {
        let manager = PairingManager()
        let hostId = UUID()
        let viewerId = UUID()

        let token = AuthToken(
            id: UUID(),
            hostId: hostId,
            viewerId: viewerId,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(3600),
            signature: Data([0x01, 0x02, 0x03])
        )

        await manager.storeHostToken(token)

        let isPaired = await manager.isPaired(with: hostId)
        XCTAssertTrue(isPaired)

        let storedToken = await manager.getHostToken(hostId)
        XCTAssertNotNil(storedToken)
    }
}

// MARK: - Helpers

extension PairingResult {
    var isSuccess: Bool {
        switch self {
        case .success: return true
        case .failure: return false
        }
    }
}
