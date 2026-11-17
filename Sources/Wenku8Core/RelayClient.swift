import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Supplies the `appver` triple the relay expects: `"<version>-<magic>-<sig8>"`.
///
/// The relay derives this value from a signed payload that is computed inside the
/// official Android client's native library. The repository deliberately does not
/// ship that derivation: it is the anti-abuse credential of a third-party
/// volunteer service, and committing a working copy would turn this public repo
/// into a scraping tool. Callers therefore inject a provider at runtime — see
/// `RelayConfiguration.keychainProvider` for the supported local workflow.
public protocol RelayAppVerProvider: Sendable {
    /// Returns the current `appver` string, or `nil` when no valid credential is
    /// configured. Implementations should return a cached value and refresh it
    /// only when the relay rejects it.
    func appVer(for token: RelayToken) async -> String?
    /// Called when the relay rejected the credential, so the provider can drop
    /// its cache and compute a fresh value next time.
    func invalidate() async
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
    /// Whether relay requests should be attempted at all. `false` keeps the app on
    /// the WAP/desktop paths, which is the default until a credential is supplied.
    public var isEnabled: Bool

    public init(
        baseURL: URL = URL(string: "https://wenku8-relay.mewx.org/")!,
        isEnabled: Bool = false
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
    private var provider: RelayAppVerProvider?

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
        // The relay issues its own cookies for bookcase/login actions.
        config.httpCookieStorage = .shared
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        self.session = URLSession(configuration: config)
    }

    public func configure(_ configuration: RelayConfiguration, provider: RelayAppVerProvider?) {
        self.configuration = configuration
        self.provider = provider
    }

    public var isAvailable: Bool {
        configuration.isEnabled && provider != nil
    }

    public func setMinimumInterval(_ interval: TimeInterval) async {
        await throttle.setMinimumInterval(interval)
    }

    /// Sends one relay action and returns the raw body.
    ///
    /// `request` must already be the composed action string, for example
    /// `"action=book&do=info&aid=1305&t=0"`.
    public func send(_ request: String) async throws -> Data {
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
        urlRequest.setValue("Wenku8/iOS", forHTTPHeaderField: "User-Agent")
        urlRequest.httpBody = Data(body.utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw RelayError.http(Wenku8Client.describe(error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw RelayError.http("中转服务没有返回有效响应")
        }
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

    public static func login(username: String, password: String) -> String {
        "action=login&username=\(username)&password=\(password)"
    }

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
