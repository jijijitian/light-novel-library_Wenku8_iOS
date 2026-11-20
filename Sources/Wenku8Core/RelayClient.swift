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
        RelayAppVer.token(unixSeconds: token.timestampMilliseconds / 1000)
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

public struct RelayConfiguration: Sendable {
    public var baseURL: URL
    /// Whether relay requests should be attempted at all. Relay is the only path
    /// that serves real rankings anonymously, so it is on by default; every call
    /// still falls back to the WAP/desktop paths when it fails.
    public var isEnabled: Bool

    public init(
        baseURL: URL = URL(string: "https://wenku8-relay.mewx.org/")!,
        isEnabled: Bool = true
    ) {
        self.baseURL = baseURL
        self.isEnabled = isEnabled
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

    /// The relay rejects a plain python/URLSession client behind Cloudflare unless
    /// it looks like the Android app, so requests carry that agent.
    static let userAgent = "okhttp/4.12.0"

    public func setMinimumInterval(_ interval: TimeInterval) async {
        await throttle.setMinimumInterval(interval)
    }

    /// Sends one relay action and returns the raw body.
    ///
    /// `request` must already be the composed action string, for example
    /// `"action=book&do=info&aid=1305&t=0"`.
    public func send(_ request: String) async throws -> Data {
        #if DEBUG
        if ProcessInfo.processInfo.environment["WENKU8_NET_LOG"] != nil {
            let action = request.split(separator: "&").first.map(String.init) ?? request
            print("[net] RELAY \(action)")
        }
        #endif
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
        case 429:
            throw RelayError.rateLimited
        default:
            throw RelayError.server(http.statusCode)
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

    public static func sorts() -> String {
        "action=xml&item=sort&t=0"
    }
}
