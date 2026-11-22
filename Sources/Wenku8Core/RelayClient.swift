import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The relay authenticates every request with a short-lived `appver` token.
///
/// The derivation lives in `RelayAppVer`; it was recovered from the official
/// Android client and is reproduced here so the relay's ranking and category
/// endpoints work. It is a minute-windowed HMAC, so tokens expire on their own.
public protocol RelayAppVerProvider: Sendable {
    /// Returns the current `appver` string.
    func appVer(for token: RelayToken) async -> String?
    /// Called when the relay rejected the credential.
    func invalidate() async
}

/// Default provider: derives the token locally, with no stored secret.
public struct BuiltinAppVerProvider: RelayAppVerProvider {
    public init() {}

    public func appVer(for token: RelayToken) async -> String? {
        RelayAppVer.magicVersion(unixSeconds: token.timestampMilliseconds / 1000)
    }

    public func invalidate() async {}
}

public struct RelayToken: Sendable, Hashable {
    public var timestampMilliseconds: Int64

    public init(timestampMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        self.timestampMilliseconds = timestampMilliseconds
    }

    /// The relay windows `appver` to the current minute, matching the client.
    public var minuteWindow: Int64 { timestampMilliseconds / 60_000 }
}

public enum RelayError: LocalizedError, Sendable {
    case notConfigured
    case badRequest
    case rejectedCredential
    case rateLimited
    case server(Int)
    case http(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "尚未配置中转服务的访问凭证"
        case .badRequest:
            return "中转服务拒绝了请求参数"
        case .rejectedCredential:
            return "中转服务凭证已失效，请在设置中更新"
        case .rateLimited:
            return "请求过于频繁，请稍后再试"
        case .server(let code):
            return "中转服务异常（\(code)）"
        case .http(let message):
            return message
        }
    }
}

/// Actor-based throttle: the relay is a volunteer service with its own quota, so
/// every request goes through a serialised gate with a minimum interval between
/// calls no matter how many views ask at once.
public actor RelayThrottle {
    private var lastRequest: Date?
    private var minimumInterval: TimeInterval

    public init(minimumInterval: TimeInterval = 1.2) {
        self.minimumInterval = minimumInterval
    }

    public func setMinimumInterval(_ interval: TimeInterval) {
        minimumInterval = max(0.2, interval)
    }

    public func acquire() async {
        if let last = lastRequest {
            let elapsed = Date().timeIntervalSince(last)
            let remaining = minimumInterval - elapsed
            if remaining > 0 {
                let nanos = UInt64(remaining * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
        lastRequest = Date()
    }
}

/// Which relay wire protocol to speak.
///
/// The service is mid-migration. The legacy endpoint is a form POST whose only
/// credential is a minute-windowed `appver`; the v2 endpoint seals the request body
/// through a native envelope and negotiates its version with response headers. Both
/// must stay selectable, because either side can change independently.
public enum RelayProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    /// `POST https://wenku8-relay.mewx.org/` with a form body and a minute-windowed `appver`.
    case legacy
    /// `POST https://mewx-android.wenku8.app/v2/api` with a sealed envelope and `X-WK8-Proto`.
    case sealed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .legacy: return "旧版"
        case .sealed: return "新版（实验）"
        }
    }
}

/// How `RelayClient` chooses between `RelayProtocol` cases.
public enum RelayProtocolPreference: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Try `.sealed` first and fall back to `.legacy` when it is unavailable.
    case automatic
    case legacy
    case sealed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: return "自动"
        case .legacy: return RelayProtocol.legacy.title
        case .sealed: return RelayProtocol.sealed.title
        }
    }
}

public struct RelayConfiguration: Sendable {
    public var baseURL: URL
    /// Whether relay requests should be attempted at all. Relay is the only path
    /// that serves real rankings anonymously, so it is on by default; every call
    /// still falls back to the WAP/desktop paths when it fails.
    public var isEnabled: Bool
    /// Whether a failed relay answer may be completed from the website.
    ///
    /// Off, a source answers alone and a gap is shown as a gap. On, the two are used
    /// together: whichever can answer a piece does, so a board the relay cannot serve still
    /// appears. Requires `isEnabled`: there is nothing to mix with otherwise.
    public var isHybrid: Bool
    /// Which wire protocol to use. Defaults to `.legacy` so an existing install keeps
    /// behaving exactly as it did until the reader opts in.
    public var protocolPreference: RelayProtocolPreference

    public init(
        baseURL: URL = URL(string: "https://wenku8-relay.mewx.org/")!,
        isEnabled: Bool = true,
        isHybrid: Bool = false,
        protocolPreference: RelayProtocolPreference = .legacy
    ) {
        self.baseURL = baseURL
        self.isEnabled = isEnabled
        self.isHybrid = isHybrid
        self.protocolPreference = protocolPreference
    }

    public static let `default` = RelayConfiguration()
}

/// Thin transport for `https://wenku8-relay.mewx.org/`.
///
/// The protocol is a single form POST whose `request` field is a base64 payload
/// built by string concatenation (the relay does *not* expect it to be
/// percent-encoded a second time), plus `appver` and `timetoken`.
public final class RelayClient: @unchecked Sendable {
    public static let shared = RelayClient()

    public private(set) var configuration: RelayConfiguration
    private let session: URLSession
    private let throttle: RelayThrottle
    private var provider: RelayAppVerProvider? = BuiltinAppVerProvider()

    /// Lazily built: the sealed transport does key derivation at construction, and an
    /// install that never opts into the new protocol should not pay for it.
    private var relayV2: RelayV2Transport?
    /// Milliseconds to add to this device's clock so it matches the service's. The
    /// service reports its own time when it sees a skew; zero means "assume we agree".
    private var clockCorrection: Int64 = 0

    public init(
        configuration: RelayConfiguration = .default,
        throttle: RelayThrottle = RelayThrottle()
    ) {
        self.configuration = configuration
        self.throttle = throttle
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 45
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // The relay issues its own cookies for bookcase/login actions, and they must
        // survive a relaunch: with `.shared` alone the login was lost on restart and
        // the shelf came back empty until the reader signed in again. `SharedCookieStore`
        // additionally mirrors the relay's cookies into UserDefaults.
        config.httpCookieStorage = .shared
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        self.session = URLSession(configuration: config)
        SharedCookieStore.restoreRelayCookies()
    }

    public func configure(_ configuration: RelayConfiguration, provider: RelayAppVerProvider? = BuiltinAppVerProvider()) {
        self.configuration = configuration
        self.provider = provider
    }

    public var isAvailable: Bool {
        configuration.isEnabled && provider != nil
    }

    /// True when the relay is on and the reader asked for both sources at once.
    public var isHybrid: Bool {
        isAvailable && configuration.isHybrid
    }

    /// The relay rejects a plain python/URLSession client behind Cloudflare unless
    /// it looks like the Android app, so requests carry that agent.
    static let userAgent = "okhttp/4.12.0"

    /// The v2 endpoint. Fixed by the service; `baseURL` only describes the legacy one.
    public static let sealedURL = URL(string: "https://mewx-android.wenku8.app/v2/api")!

    public func setMinimumInterval(_ interval: TimeInterval) async {
        await throttle.setMinimumInterval(interval)
    }

    /// True once a `.sealed` call has failed for a reason that is not the service's
    /// fault, so `.automatic` can stop paying for the attempt on every request.
    private var sealedIsBroken = false

    /// Whether the next request should try the sealed protocol first.
    ///
    /// `.automatic` starts on the new protocol and drops to the old one for the rest
    /// of the session once it proves unusable — the reader should not wait for two
    /// round trips on every screen.
    var shouldAttemptSealed: Bool {
        switch configuration.protocolPreference {
        case .legacy: return false
        case .sealed: return true
        case .automatic: return !sealedIsBroken
        }
    }

    /// Sends one relay action and returns the raw body.
    ///
    /// `request` must already be the composed action string, for example
    /// `"action=book&do=info&aid=1305&t=0"`. The same string serves both protocols:
    /// the v2 endpoint seals this exact byte sequence rather than wrapping it.
    public func send(_ request: String) async throws -> Data {
        #if DEBUG
        if ProcessInfo.processInfo.environment["WENKU8_NET_LOG"] != nil {
            let action = request.split(separator: "&").first.map(String.init) ?? request
            print("[net] RELAY \(action)")
        }
        #endif
        guard configuration.isEnabled, provider != nil else {
            throw RelayError.notConfigured
        }

        var lastError: Error?
        if shouldAttemptSealed {
            do {
                return try await sendSealed(request)
            } catch let error as Wenku8Error {
                // An upgrade demand is the service describing the client, not a fault
                // to route around: surface it so the reader can act on it.
                if case .upgradeRequired = error { throw error }
                lastError = error
            } catch {
                lastError = error
            }
            // Only `.automatic` may fall back; an explicit choice is honoured so the
            // reader can see which protocol failed.
            if configuration.protocolPreference != .automatic {
                throw lastError ?? RelayError.http("中转服务不可用")
            }
            sealedIsBroken = true
        }
        do {
            return try await sendLegacy(request)
        } catch {
            // Report the sealed failure when it came first: it describes the protocol
            // the reader asked for.
            throw lastError ?? error
        }
    }

    /// Legacy protocol: a form POST whose `request` field is the base64 action.
    private func sendLegacy(_ request: String) async throws -> Data {
        guard configuration.isEnabled, let provider else {
            throw RelayError.notConfigured
        }
        await throttle.acquire()

        let token = RelayToken()
        guard let appVer = await provider.appVer(for: token) else {
            throw RelayError.notConfigured
        }

        let payload = Data(request.utf8).base64EncodedString()
        let body = "&appver=\(appVer)&request=\(payload)&timetoken=\(token.timestampMilliseconds)"

        var urlRequest = URLRequest(url: configuration.baseURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        urlRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.httpBody = Data(body.utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            #if DEBUG
            // The relay fails once in a while at launch, and without this the only
            // symptom was a section silently missing from the home page.
            print("[relay] \(request.prefix(40)) failed: \(error)")
            #endif
            throw RelayError.http(Wenku8Client.describe(error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw RelayError.http("中转服务没有返回有效响应")
        }
        // Any reply may carry an updated session (a login sets it, a later call may
        // refresh it), so the mirror is updated on every response.
        SharedCookieStore.persistRelayCookies()
        switch http.statusCode {
        case 200...299:
            return data
        case 400:
            throw RelayError.badRequest
        case 401, 403:
            await provider.invalidate()
            throw RelayError.rejectedCredential
        case 426:
            throw Wenku8Error.upgradeRequired(
                http.value(forHTTPHeaderField: "X-WK8-Update-Hint")
            )
        case 429:
            throw RelayError.rateLimited
        default:
            throw RelayError.server(http.statusCode)
        }
    }

    /// Sealed protocol: a raw envelope body with the version header, no form fields.
    ///
    /// The service validates the envelope before anything else, so every failure here
    /// is reported as a relay error rather than guessed at. A skew reply carries the
    /// service's clock, which is folded into the next attempt's `counter`.
    private func sendSealed(_ request: String) async throws -> Data {
        await throttle.acquire()

        let transport = relayV2 ?? RelayV2Transport()
        relayV2 = transport
        guard transport.isAvailable else {
            throw RelayError.http("当前版本无法使用新版中转协议")
        }

        // The service binds the session into the envelope, so the cookie that seals it
        // must be the one that accompanies it. Reading it here keeps the two identical.
        let cookie = Self.relayCookieHeader()
        let body = Array(request.utf8)
        let extra = Array(cookie.utf8)

        let sealed: [UInt8]
        do {
            sealed = try transport.seal(body: body, extra: extra, counter: clockCorrection)
        } catch {
            throw RelayError.http("无法生成新版中转请求")
        }

        var urlRequest = URLRequest(url: Self.sealedURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(RelayV2Transport.contentType, forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(
            RelayV2Transport.protocolHeaderValue,
            forHTTPHeaderField: RelayV2Transport.protocolHeaderName
        )
        urlRequest.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        urlRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if !cookie.isEmpty {
            urlRequest.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        urlRequest.httpBody = Data(sealed)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            #if DEBUG
            print("[relay/v2] \(request.prefix(40)) failed: \(error)")
            #endif
            throw RelayError.http(Wenku8Client.describe(error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw RelayError.http("中转服务没有返回有效响应")
        }
        Self.adoptSessionCookie(from: http)
        SharedCookieStore.persistRelayCookies()

        // The service asks for an upgrade on 426, and also hints at one with a header
        // on a 200. Both mean the same thing to the reader.
        if http.value(forHTTPHeaderField: "X-WK8-Update-Hint") == "1" {
            throw Wenku8Error.upgradeRequired(
                http.value(forHTTPHeaderField: "X-WK8-Min-Version").map { "需要版本 \($0)" }
            )
        }

        switch http.statusCode {
        case 200...299:
            return data
        case 401:
            // A skew reply is the service telling us its clock; anything else is a
            // rejected session.
            if let correction = Self.clockSkew(from: data) {
                clockCorrection = correction
                throw RelayError.http("已校准本机时间，请重试")
            }
            await provider?.invalidate()
            throw RelayError.rejectedCredential
        case 403 where Self.isEnvelopeRejection(data):
            // `ENVELOPE_INVALID` describes the envelope, not the account: clearing the
            // credential would be wrong, and its hint would send the reader to fix a
            // password that is fine.
            throw RelayError.http("新版中转协议被拒绝，可在设置中改用旧版或网页模式")
        case 403:
            await provider?.invalidate()
            throw RelayError.rejectedCredential
        case 426:
            throw Wenku8Error.upgradeRequired(
                Self.upgradeHint(from: data) ?? http.value(forHTTPHeaderField: "X-WK8-Update-Hint")
            )
        case 429:
            throw RelayError.rateLimited
        default:
            throw RelayError.server(http.statusCode)
        }
    }

    /// The `Cookie` header for the relay host, as one string.
    ///
    /// The envelope is sealed against exactly this value, so it is built once here
    /// rather than left to `URLSession`'s own cookie handling.
    static func relayCookieHeader() -> String {
        let cookies = HTTPCookieStorage.shared.cookies?.filter { RelayHost.isRelay($0.domain) } ?? []
        guard !cookies.isEmpty else { return "" }
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// `{"error":"CLOCK_SKEW","serverTimeMs":<int64>}` → the correction in milliseconds.
    static func clockSkew(from data: Data) -> Int64? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["error"] as? String == "CLOCK_SKEW",
              let serverTime = object["serverTimeMs"] as? NSNumber
        else { return nil }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return serverTime.int64Value - now
    }

    /// `{"minVersionCode":…,"minVersionName":"…"}` → a line the reader can act on.
    /// True when the service is rejecting the sealed envelope rather than the account.
    ///
    /// A v2 refusal names the envelope (`ENVELOPE_INVALID`); a wrong password or session
    /// does not use that word, so the two must not share a handling path.
    static func isEnvelopeRejection(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("ENVELOPE_INVALID") || text.contains("CLOCK_SKEW")
    }

    static func upgradeHint(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let name = object["minVersionName"] as? String, !name.isEmpty {
            return "需要版本 \(name)"
        }
        if let code = object["minVersionCode"] as? NSNumber {
            return "需要版本 \(code.intValue)"
        }
        return nil
    }

    /// Keeps the session the service set, under the one name it uses.
    static func adoptSessionCookie(from response: HTTPURLResponse) {
        let headers = response.allHeaderFields
        for (key, value) in headers {
            guard let name = key as? String,
                  name.caseInsensitiveCompare("Set-Cookie") == .orderedSame,
                  let raw = value as? String, raw.contains("PHPSESSID=")
            else { continue }
            let start = raw.range(of: "PHPSESSID=")!.upperBound
            let rest = raw[start...]
            let sessionId = String(rest.prefix { $0 != ";" }).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sessionId.isEmpty else { continue }
            let properties: [HTTPCookiePropertyKey: Any] = [
                .name: "PHPSESSID",
                .value: sessionId,
                .domain: "wenku8.app",
                .path: "/",
            ]
            if let cookie = HTTPCookie(properties: properties) {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
        }
    }

    /// Convenience wrapper for the plain-text replies (`1`, `2`, … return codes).
    public func sendText(_ request: String) async throws -> String {
        let data = try await send(request)
        return TextDecoding.decode(data).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum RelayAction {
    public static func cover(aid: Int) -> String {
        "action=book&do=cover&aid=\(aid)"
    }

    public static func info(aid: Int) -> String {
        "action=book&do=info&aid=\(aid)&t=0"
    }

    /// Carries the book's tags, which `meta` does not.
    public static func bookInfo(aid: Int) -> String {
        "action=book&do=bookinfo&aid=\(aid)"
    }

    public static func meta(aid: Int) -> String {
        "action=book&do=meta&aid=\(aid)&t=0"
    }

    public static func intro(aid: Int) -> String {
        "action=book&do=intro&aid=\(aid)&t=0"
    }

    public static func chapterList(aid: Int) -> String {
        "action=book&do=list&aid=\(aid)&t=0"
    }

    public static func text(aid: Int, cid: Int) -> String {
        "action=book&do=text&aid=\(aid)&cid=\(cid)&t=0"
    }

    public static func novelList(sort: String, page: Int) -> String {
        "action=novellist&sort=\(sort)&page=\(page)&t=0"
    }

    public static func articleList(sort: String, page: Int) -> String {
        "action=articlelist&sort=\(sort)&page=\(page)"
    }

    public static func search(type: String, key: String) -> String {
        "action=search&searchtype=\(type)&searchkey=\(key)&t=0"
    }

    public static func bookcaseList() -> String {
        "action=bookcase&do=list&t=0"
    }

    public static func bookcaseAdd(aid: Int) -> String {
        "action=bookcase&do=add&aid=\(aid)"
    }

    public static func bookcaseDelete(aid: Int) -> String {
        "action=bookcase&do=del&aid=\(aid)"
    }

    /// Builds the login request.
    ///
    /// The credentials are percent-encoded: a password containing `&`, `=`, `+` or a
    /// space would otherwise split or corrupt the request string, and the relay would
    /// answer with a failure that looks like wrong credentials.
    public static func login(username: String, password: String) -> String {
        let user = username.addingPercentEncoding(
            withAllowedCharacters: Self.relayAllowed
        ) ?? username
        let pass = password.addingPercentEncoding(
            withAllowedCharacters: Self.relayAllowed
        ) ?? password
        return "action=login&username=\(user)&password=\(pass)"
    }

    /// Everything except the characters that delimit or terminate the request string.
    /// Deliberately narrow: `+` and `&` must be encoded, unlike the default set.
    static let relayAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?+ #%")
        return allowed
    }()

    public static func logout() -> String {
        "action=logout"
    }

    public static func userInfo() -> String {
        "action=userinfo"
    }

    /// A book's reviews. Page one keeps the titles, the posters and the reply counts.
    public static func reviewList(aid: Int, page: Int) -> String {
        "action=review&do=list&aid=\(aid)&page=\(page)"
    }

    /// One page of a review thread's floors.
    public static func reviewThread(rid: Int, page: Int) -> String {
        "action=review&do=show&rid=\(rid)&page=\(page)&t=0"
    }

    public static func sorts() -> String {
        "action=xml&item=sort&t=0"
    }
}
