import XCTest
@testable import Wenku8Core

/// Covers the relay v2 envelope's recovered key schedule and the client's protocol
/// handling.
///
/// The key derivation is the part that has to be exactly right: it was recovered by
/// emulating the official Android client's native library, and every intermediate value
/// below was read out of that library's own memory. If any constant or ordering here
/// drifts, `testSessionKeyMatchesNativeLibrary` fails, which is the point.
///
/// The cipher stage is not covered because it is not implemented — see
/// `RelayV2Transport` and `docs/relay-v2-envelope-findings.md` for why.
final class RelayV2Tests: XCTestCase {
    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func bytes(_ hex: String) -> [UInt8] {
        var out = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    // MARK: - Seed

    /// The seed the Android client derives from its two constant arrays.
    func testSeedDerivationMatchesAndroid() {
        XCTAssertEqual(
            hex(RelayV2Seed.derived()),
            "47c3d1f84d971cb2278886bf407e2f84245fb05aae3b34e1014539aa0f23b2cd"
        )
    }

    // MARK: - Key schedule

    /// The two mixed constant blocks, whose values were read from the library's `.rodata`.
    func testConstantBlocks() {
        XCTAssertEqual(
            hex(RelayV2KeySchedule.messagePrefix()),
            "2bce9e441d282b4699396e417b4ee223f5ecb6e2d3529a6c2e78cbca40a59533"
        )
        XCTAssertEqual(
            hex(RelayV2KeySchedule.keyPrefix()),
            "81b9bf048177fca3ce53cb4fb48ce0f32d5ccb1ffaeddc22dfd9193c514ce125"
        )
    }

    /// The working key, which the native library keeps at `.bss+0x29`.
    func testWorkingKeyMatchesNativeLibrary() {
        XCTAssertEqual(
            hex(RelayV2KeySchedule.workingKey()),
            "0f179bb94b65f0ea3f8fba1c5e030bc0f0ff89063b6919c002d8eb7a67b121ee"
        )
    }

    /// The full HKDF, producing the per-install session key.
    ///
    /// The expected value is what the emulated library holds in `.bss+0x29` after a
    /// successful `init()` with the default flavor.
    func testSessionKeyMatchesNativeLibrary() throws {
        let transport = RelayV2Transport()
        XCTAssertTrue(transport.isAvailable, "the bundled key table is missing")
        let key = try XCTUnwrap(transport.sessionKey())
        XCTAssertEqual(
            hex(key),
            "6ba3d50704d5c101ca0493f2048bdd42e9bb4d7129a1d5cfabb842b540b45019"
        )
    }

    /// A different bundle identity must derive a different key: the process name is
    /// part of the material, which is why this cannot be hard-coded.
    func testDifferentProcessIdentityChangesKey() {
        let key = RelayV2KeySchedule.workingKey(
            processIdentity: Array("org.mewx.wenku8.v1".utf8) + [0]
        )
        XCTAssertNotEqual(
            hex(key),
            "0f179bb94b65f0ea3f8fba1c5e030bc0f0ff89063b6919c002d8eb7a67b121ee"
        )
    }

    /// The flavor byte is baked into both the header and the label, so the two builds
    /// derive different session keys.
    func testFlavorChangesSessionKey() throws {
        let transport = RelayV2Transport()
        let direct = try XCTUnwrap(transport.sessionKey(flavor: 2))
        let playStore = try XCTUnwrap(transport.sessionKey(flavor: 1))
        XCTAssertNotEqual(direct, playStore)
    }

    // MARK: - Envelope constraints

    /// The format refuses an empty body and anything past its own 32 KiB guard.
    func testSealRejectsUnacceptableBodyLengths() {
        let transport = RelayV2Transport()
        XCTAssertThrowsError(try transport.seal(body: []))
        let tooLong = [UInt8](repeating: 0x41, count: RelayV2Transport.maximumBodyLength + 1)
        XCTAssertThrowsError(try transport.seal(body: tooLong))
    }

    // MARK: - Protocol selection

    func testProtocolDefaultsToLegacy() {
        // An install that predates the new protocol must keep behaving as it did.
        XCTAssertEqual(RelayConfiguration().protocolPreference, .legacy)
        XCTAssertEqual(
            RelayProtocolPreference(rawValue: "automatic"),
            .automatic
        )
    }

    func testProtocolPreferenceRoundTrips() {
        let defaults = UserDefaults(suiteName: "RelayV2Tests")!
        defaults.removePersistentDomain(forName: "RelayV2Tests")
        let store = RelayCredentialStore(defaults: defaults)
        XCTAssertEqual(store.protocolPreference, .legacy)
        store.setProtocolPreference(.sealed)
        XCTAssertEqual(store.protocolPreference, .sealed)
        store.setProtocolPreference(.automatic)
        XCTAssertEqual(store.protocolPreference, .automatic)
    }

    // MARK: - Version gating

    /// An upgrade demand is terminal: retrying the same request cannot help.
    func testUpgradeRequiredIsNotRetriable() {
        let error = Wenku8Error.upgradeRequired("需要版本 2.1")
        XCTAssertFalse(error.isRetriable)
        XCTAssertEqual(error.errorDescription, "中转服务要求升级客户端：需要版本 2.1")
        // Other failures stay retriable so views keep offering a refresh.
        XCTAssertTrue(Wenku8Error.network("超时").isRetriable)
    }

    /// The service reports its clock in a skew reply; the correction is what the next
    /// attempt folds into the envelope's counter.
    func testClockSkewIsParsedFromResponseBody() {
        let serverNow = Int64(Date().timeIntervalSince1970 * 1000) + 5_000
        let body = Data(#"{"error":"CLOCK_SKEW","serverTimeMs":\#(serverNow)}"#.utf8)
        let correction = RelayClient.clockSkew(from: body)
        let unwrapped = try? XCTUnwrap(correction)
        XCTAssertNotNil(unwrapped)
        // Allow for the wall clock advancing between the two reads.
        XCTAssertEqual(Double(unwrapped ?? 0), 5_000, accuracy: 200)
    }

    /// Anything that is not a skew reply must not be mistaken for one.
    func testClockSkewIgnoresOtherBodies() {
        XCTAssertNil(RelayClient.clockSkew(from: Data(#"{"error":"BAD_REQUEST"}"#.utf8)))
        XCTAssertNil(RelayClient.clockSkew(from: Data("4".utf8)))
        XCTAssertNil(RelayClient.clockSkew(from: Data()))
    }

    /// The 426 body names the version the service wants.
    func testUpgradeHintReadsMinimumVersion() {
        let body = Data(#"{"minVersionCode":105,"minVersionName":"2.1.0"}"#.utf8)
        XCTAssertEqual(RelayClient.upgradeHint(from: body), "需要版本 2.1.0")
        let codeOnly = Data(#"{"minVersionCode":106}"#.utf8)
        XCTAssertEqual(RelayClient.upgradeHint(from: codeOnly), "需要版本 106")
        XCTAssertNil(RelayClient.upgradeHint(from: Data("nonsense".utf8)))
    }

    /// An envelope refusal must not be mistaken for a rejected password: the two share
    /// status 403 but need different guidance.
    func testEnvelopeRejectionIsDistinguishedFromAuthFailure() {
        XCTAssertTrue(RelayClient.isEnvelopeRejection(Data(#"{"error":"ENVELOPE_INVALID"}"#.utf8)))
        XCTAssertTrue(RelayClient.isEnvelopeRejection(Data(#"{"error":"CLOCK_SKEW"}"#.utf8)))
        XCTAssertFalse(RelayClient.isEnvelopeRejection(Data(#"{"error":"BAD_PASSWORD"}"#.utf8)))
        XCTAssertFalse(RelayClient.isEnvelopeRejection(Data()))
    }

    // MARK: - Vectors

    /// The recorded vector set is the reference for the (not yet implemented) cipher.
    /// Asserting its shape keeps the generated fixture honest.
    func testVectorFixtureShape() {
        XCTAssertEqual(RelayV2Vectors.all.count, 42)
        // The last vector deliberately records an empty body, for which the library
        // returns no envelope at all.
        let envelopeVectors = RelayV2Vectors.all.filter { !$0.body.isEmpty }
        XCTAssertEqual(envelopeVectors.count, 41)
        for vector in envelopeVectors {
            XCTAssertEqual(vector.sealed.prefix(3), [0x01, 0x00, 0xC9], vector.name)
            // Header is 17 bytes, then a ciphertext of at least 66 bytes.
            XCTAssertGreaterThan(vector.sealed.count, 17 + 66, vector.name)
            // The nonce echoes the entropy source's first twelve bytes.
            XCTAssertEqual(
                Array(vector.sealed[5..<17]),
                Array(RelayV2Vectors.entropy[0..<12]),
                vector.name
            )
        }
        let empty = RelayV2Vectors.all.first { $0.body.isEmpty }
        XCTAssertEqual(empty?.sealed, [])
    }
}
