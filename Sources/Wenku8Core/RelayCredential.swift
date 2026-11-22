import Foundation

/// Default `RelayAppVerProvider`: reads a credential that the user supplies from
/// their own channel, and keeps it in `UserDefaults`.
///
/// Nothing in this repository derives the credential. The relay's `appver` is the
/// anti-abuse token of a volunteer-run service, so it is treated as configuration
/// — the same way an API key would be — rather than as shipped code. Users who
/// hold a valid token can paste it in Settings; everyone else simply keeps using
/// the WAP/desktop data paths.
public final class RelayCredentialStore: RelayAppVerProvider, @unchecked Sendable {
    public static let shared = RelayCredentialStore()

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cachedVer: String?
    private var cachedWindow: Int64?

    private enum Key {
        static let appVer = "relay.appver"
        static let enabled = "relay.enabled"
        static let minimumInterval = "relay.minimumInterval"
        static let hybrid = "relay.hybrid"
        static let protocolPreference = "relay.protocol"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Relay is on unless the user turned it off.
    public var isEnabled: Bool {
        if defaults.object(forKey: Key.enabled) == nil { return true }
        return defaults.bool(forKey: Key.enabled)
    }

    /// Which relay wire protocol to speak.
    ///
    /// Defaults to `.legacy`: the new protocol is experimental, and an install that
    /// predates it must keep working the way it did.
    public var protocolPreference: RelayProtocolPreference {
        guard let raw = defaults.string(forKey: Key.protocolPreference),
              let value = RelayProtocolPreference(rawValue: raw)
        else { return .legacy }
        return value
    }

    public func setProtocolPreference(_ preference: RelayProtocolPreference) {
        defaults.set(preference.rawValue, forKey: Key.protocolPreference)
    }

    /// Whether the relay and the website are used together. Off unless the relay is on.
    public var isHybridEnabled: Bool {
        guard isEnabled else { return false }
        return defaults.bool(forKey: Key.hybrid)
    }

    public func setHybridEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.hybrid)
    }

    /// The stored credential, verbatim. Exposed so Settings can show whether one
    /// is present without printing the whole token.
    public var storedVer: String? {
        let value = defaults.string(forKey: Key.appVer)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    public var maskedVer: String? {
        guard let ver = storedVer else { return nil }
        guard ver.count > 10 else { return String(repeating: "•", count: ver.count) }
        return "\(ver.prefix(6))…\(ver.suffix(4))"
    }

    public var minimumInterval: TimeInterval {
        let stored = defaults.double(forKey: Key.minimumInterval)
        // Keep a floor: the relay has its own quota and abuse gets IPs banned.
        return stored > 0 ? max(0.5, stored) : 1.2
    }

    public func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.enabled)
    }

    public func setAppVer(_ ver: String?) {
        let trimmed = ver?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            defaults.removeObject(forKey: Key.appVer)
        } else {
            defaults.set(trimmed, forKey: Key.appVer)
        }
        invalidateSync()
    }

    public func setMinimumInterval(_ interval: TimeInterval) {
        defaults.set(max(0.5, interval), forKey: Key.minimumInterval)
    }

    // MARK: - RelayAppVerProvider

    public func appVer(for token: RelayToken) async -> String? {
        guard isEnabled, let stored = storedVer else { return nil }
        return cached(storedVer: stored, window: token.minuteWindow)
    }

    /// Synchronous cache decision, kept out of the `async` method so the lock is
    /// never taken across a suspension point.
    private func cached(storedVer: String, window: Int64) -> String {
        lock.lock()
        defer { lock.unlock() }
        // The relay windows the token to the current minute; a credential minted
        // for an earlier window is still reused until the relay rejects it,
        // because only the holder can know whether it rotates per minute.
        if let cachedVer, cachedWindow == window {
            return cachedVer
        }
        cachedVer = storedVer
        cachedWindow = window
        return storedVer
    }

    public func invalidate() async {
        invalidateSync()
    }

    private func invalidateSync() {
        lock.lock()
        cachedVer = nil
        cachedWindow = nil
        lock.unlock()
    }
}
