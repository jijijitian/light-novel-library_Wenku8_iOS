import Foundation

/// Seals and hands off requests for the relay's v2 endpoint.
///
/// The service accepts only an envelope produced by the official Android client: a
/// clear 17-byte header (format tag, flavor, nonce) followed by the ciphertext of the
/// action string. The key schedule is recovered in `RelayV2KeySchedule`; this type
/// covers the parts around it — the bundled table, the nonce, and the header.
///
/// **Status.** The key derivation below reproduces the official client's session key
/// byte-for-byte, and the envelope framing is known exactly. The cipher stage itself is
/// not implemented, so `seal` throws rather than emitting an envelope the service would
/// reject. See `docs/relay-v2-envelope-findings.md` — the service currently answers
/// `403 ENVELOPE_INVALID` even to envelopes built with the correct key, so shipping a
/// working-looking sealer would only produce misleading failures.
public struct RelayV2Transport: Sendable {
    /// The sealing stage is not available.
    public enum Failure: Error, Sendable, Equatable {
        /// The 2048-byte table that the key schedule consumes is missing.
        case missingKeyTable
        /// No envelope was produced.
        case sealUnavailable
        /// The body length is outside what the format allows.
        case unacceptableBodyLength(Int)
    }

    /// Bodies are capped by the format's own guard: `len - 1 <= 0x7FFF`.
    public static let maximumBodyLength = 32_768

    /// The header byte the official direct-download build reports.
    public static let defaultFlavor: UInt8 = 2

    /// The `X-WK8-Proto` value the envelope is built for.
    public static let protocolHeaderName = "X-WK8-Proto"
    public static let protocolHeaderValue = "2"
    public static let contentType = "application/octet-stream"

    private let lut: [UInt8]
    private let seed: [UInt8]

    /// Builds a transport from the bundled table and the app's derived seed.
    public init(
        seed: [UInt8] = RelayV2Seed.derived(),
        lut: [UInt8] = RelayV2Transport.bundledKeyTable()
    ) {
        self.seed = seed
        self.lut = lut
    }

    /// The session key the official client holds after initialising.
    ///
    /// Exposed so the unit tests can assert it against the value recovered from the
    /// native library, which is the only way to prove the schedule is right.
    public func sessionKey(flavor: UInt8 = RelayV2Transport.defaultFlavor) -> [UInt8]? {
        guard seed.count == 32, lut.count == 2048 else { return nil }
        return RelayV2KeySchedule.sessionKey(lut: lut, seed: seed, flavor: flavor)
    }

    public var isAvailable: Bool { seed.count == 32 && lut.count == 2048 }

    /// Seals one request body.
    ///
    /// - Parameters:
    ///   - body: the action string, UTF-8, exactly as the legacy protocol sends it.
    ///   - extra: the `Cookie` header value that will accompany the request, or empty.
    ///     The official client binds the session into the envelope this way.
    ///   - counter: milliseconds of clock correction, added to `now` by the sealer.
    ///   - now: this device's wall clock, injected so tests are reproducible.
    public func seal(
        body: [UInt8],
        extra: [UInt8] = [],
        counter: Int64 = 0,
        now: Date = Date()
    ) throws -> [UInt8] {
        guard !body.isEmpty, body.count <= Self.maximumBodyLength else {
            throw Failure.unacceptableBodyLength(body.count)
        }
        guard isAvailable else { throw Failure.missingKeyTable }
        // The cipher stage is deliberately unimplemented; see the type's documentation.
        throw Failure.sealUnavailable
    }

    /// The 2048-byte table the key schedule mixes in, from the module's resources.
    ///
    /// It is the same `wk8_lut.bin` the Android app ships. Without it the derived key
    /// is wrong, so a missing file is reported rather than silently substituted.
    public static func bundledKeyTable() -> [UInt8] {
        guard let url = CoreResources.bundle.url(forResource: "wk8-lut", withExtension: "bin"),
              let data = try? Data(contentsOf: url)
        else { return [] }
        return Array(data)
    }
}

/// The 32-byte seed the official client derives from two obfuscated constant arrays.
///
/// `NativeEnvelopeBridge.c()` computes, for `i` in `0..<32`:
///
///     seed[i] = ((C[i] & 0xFF) - ((i * 19 + 7) & 0xFF) & 0xFF) ^ (D[i] & 0xFF)
///
/// where `C` and `D` are the `lv1.C` / `lv1.D` byte arrays in the Android app. They
/// are reproduced here because nothing in the app generates them.
public enum RelayV2Seed {
    /// `lv1.C`, as signed bytes from the decompiled source.
    static let constantC: [Int8] = [
        -120, -87, -84, 91, -83, -111, -51, 2, -126, -52, -76, 65, -92, -43, -35, 42,
        30, 120, 98, -112, 63, -103, -122, -52, 13, 107, -70, -33, -53, -28, 25, -95,
    ]

    /// `lv1.D`, as signed bytes.
    static let constantD: [Int8] = [
        -58, 76, -82, -29, 23, -68, 72, -60, -60, -110, 105, -42, -7, -87, -29, -126,
        -61, 113, -75, 122, 18, 56, -23, -15, 63, -52, -4, 125, -65, -107, 106, -128,
    ]

    /// The 32 bytes the native `init` expects.
    public static func derived() -> [UInt8] {
        (0..<32).map { index in
            let c = UInt8(bitPattern: constantC[index])
            let d = UInt8(bitPattern: constantD[index])
            let offset = UInt8(truncatingIfNeeded: index * 19 + 7)
            return ((c &- offset) ^ d)
        }
    }
}
