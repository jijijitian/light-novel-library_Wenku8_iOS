import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Which mirror the app talks to.
///
/// `net` and `cc` serve the same content; users in some networks reach one but
/// not the other, so the choice is exposed in Settings.
public enum SiteDomain: String, CaseIterable, Identifiable, Sendable {
    case net
    case cc

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .net: return "wenku8.net"
        case .cc: return "wenku8.cc"
        }
    }

    public var host: String {
        switch self {
        case .net: return "https://www.wenku8.net"
        case .cc: return "https://www.wenku8.cc"
        }
    }

    /// Where the site is stored in preferences.
    public static let storageKey = "site.domain"

    /// The mirror the app is currently pointed at, for links that leave the app.
    ///
    /// Web sheets must follow it: a hard-coded host sent a reader who had chosen one mirror
    /// to the other.
    public static var current: SiteDomain {
        SiteDomain(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "")
            ?? .net
    }

    /// A link on the site, in this mirror.
    public func webURL(_ path: String) -> URL {
        URL(string: host + path) ?? URL(string: host)!
    }
}

public struct SiteEndpoints: Sendable {
    public var hosts: [String]
    public var wapHosts: [String]

    public init(
        hosts: [String] = ["https://www.wenku8.net", "https://www.wenku8.com"],
        wapHosts: [String] = ["https://www.wenku8.net/wap", "https://www.wenku8.com/wap"]
    ) {
        self.hosts = hosts
        self.wapHosts = wapHosts
    }

    /// Primary domain first, then the other one as a fallback.
    public init(domain: SiteDomain) {
        let other: SiteDomain = domain == .net ? .cc : .net
        self.hosts = [domain.host, other.host]
        self.wapHosts = ["\(domain.host)/wap", "\(other.host)/wap"]
    }

    public static let `default` = SiteEndpoints()

    public var primaryHost: String { hosts[0] }
    public var primaryWAP: String { wapHosts[0] }
}

public final class Wenku8Client: @unchecked Sendable {
    public static let shared = Wenku8Client()

    /// The mobile WAP site and the desktop site answer to different clients: the
    /// desktop pages (book pages, yearly rankings) reject the Android Chrome agent
    /// with a Cloudflare challenge but serve an iPhone Safari agent normally.
    static let wapUserAgent =
        "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) "
        + "Chrome/124.0.0.0 Mobile Safari/537.36"

    static let desktopUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    let session: URLSession
    let cookieStorage: HTTPCookieStorage
    public var endpoints = SiteEndpoints.default

    /// Switches the mirror used for every desktop/WAP request.
    public func use(domain: SiteDomain) {
        endpoints = SiteEndpoints(domain: domain)
    }

    public init(configuration: URLSessionConfiguration? = nil) {
        let config = configuration ?? .default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 45
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = .shared
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.httpAdditionalHeaders = ["Accept-Language": "zh-CN,zh;q=0.9"]
        self.cookieStorage = .shared
        self.session = URLSession(configuration: config)
    }

    public struct Response: Sendable {
        public var data: Data
        public var status: Int
        public var finalURL: URL?

        public var text: String { TextDecoding.decode(data) }
    }

    /// Prints every request when `WENKU8_NET_LOG` is set, so a debug launch can show which
    /// host the app is actually talking to.
    private static func logRequest(_ request: URLRequest) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["WENKU8_NET_LOG"] != nil else { return }
        let method = request.httpMethod ?? "GET"
        print("[net] \(method) \(request.url?.absoluteString ?? "-")")
        #endif
    }

    public func send(_ request: URLRequest) async throws -> Response {
        var request = request
        Self.logRequest(request)
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(Self.wapUserAgent, forHTTPHeaderField: "User-Agent")
        }
        if request.value(forHTTPHeaderField: "Accept-Language") == nil {
            request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw Wenku8Error.network("服务器没有返回有效响应")
            }
            if Self.isChallenge(data) {
                throw Wenku8Error.unavailable("文库对该页面启用了人机校验，请稍后再试")
            }
            if http.statusCode >= 400 && http.statusCode != 404 {
                throw Wenku8Error.network("服务器返回状态码 \(http.statusCode)")
            }
            return Response(data: data, status: http.statusCode, finalURL: http.url)
        } catch let error as Wenku8Error {
            throw error
        } catch {
            throw Wenku8Error.network(Self.describe(error))
        }
    }

    public func get(_ url: URL, referer: String? = nil) async throws -> Response {
        var request = URLRequest(url: url)
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        if let referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        return try await send(request)
    }

    public func post(_ url: URL, fields: [String: String], referer: String? = nil) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if let referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        let body = fields
            .sorted { $0.key < $1.key }
            .map { "\(TextDecoding.formEncode($0.key))=\(TextDecoding.formEncode($0.value))" }
            .joined(separator: "&")
        request.httpBody = Data(body.utf8)
        return try await send(request)
    }

    /// Fetches a WAP page, retrying the mirror host when the primary one fails.
    public func wap(_ path: String, referer: String? = nil) async throws -> String {
        try await withHostFallback(endpoints.wapHosts, path: path, referer: referer, desktop: false)
    }

    public func desktop(_ path: String, referer: String? = nil) async throws -> String {
        try await withHostFallback(endpoints.hosts, path: path, referer: referer, desktop: true)
    }

    /// POSTs an HTML form to the desktop site. Login and bookcase mutations live
    /// there: `login.php?do=submit` answers with an error page on bad credentials
    /// and a redirect on success, so the caller compares cookies afterwards.
    /// Fetches the login captcha image, plus the cookies that go with it.
    ///
    /// The captcha is bound to the session cookie it is issued with, so the same client must
    /// fetch the image and submit the answer — otherwise the code is checked against a
    /// different session and always fails.
    public func captchaImage() async throws -> Data {
        var lastError: Error?
        for host in endpoints.hosts {
            guard let url = URL(string: host + "/checkcode.php") else { continue }
            do {
                var request = URLRequest(url: url)
                request.setValue(Self.desktopUserAgent, forHTTPHeaderField: "User-Agent")
                request.setValue("image/png,image/*;q=0.8", forHTTPHeaderField: "Accept")
                let response = try await send(request)
                guard response.status == 200, !response.data.isEmpty else {
                    throw Wenku8Error.unavailable("验证码图片为空")
                }
                return response.data
            } catch {
                lastError = error
            }
        }
        throw lastError ?? Wenku8Error.unavailable("无法获取验证码")
    }

    /// POSTs a WML form to the mobile site, trying each mirror in turn.
    public func wapPost(_ path: String, fields: [String: String]) async throws -> String {
        var lastError: Error?
        for host in endpoints.wapHosts {
            guard let url = URL(string: host + path) else { continue }
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.setValue(Self.wapUserAgent, forHTTPHeaderField: "User-Agent")
                let body = fields
                    .map { "\(TextDecoding.formEncode($0.key))=\(TextDecoding.formEncode($0.value))" }
                    .joined(separator: "&")
                request.httpBody = Data(body.utf8)
                let response = try await send(request)
                return TextDecoding.decode(response.data)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? Wenku8Error.unavailable("无法连接文库站点")
    }

    /// POSTs the desktop login form, which is guarded by an image captcha.
    ///
    /// Separate from `desktopPost` only in what it returns on failure: the caller needs the
    /// page to read the site's own message, not a thrown error.
    public func desktopLoginPost(
        username: String,
        password: String,
        captcha: String
    ) async throws -> String {
        var lastError: Error?
        for host in endpoints.hosts {
            guard let url = URL(string: host + "/login.php?do=submit") else { continue }
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.setValue(
                    "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                    forHTTPHeaderField: "Accept"
                )
                request.setValue(Self.desktopUserAgent, forHTTPHeaderField: "User-Agent")
                request.setValue(host + "/login.php", forHTTPHeaderField: "Referer")
                let fields = [
                    "action": "login",
                    "usecookie": "315360000",
                    "username": username,
                    "password": password,
                    "checkcode": captcha,
                ]
                request.httpBody = Data(fields
                    .sorted { $0.key < $1.key }
                    .map { "\(TextDecoding.formEncode($0.key))=\(TextDecoding.formEncode($0.value))" }
                    .joined(separator: "&").utf8)
                let response = try await send(request)
                return TextDecoding.decode(response.data)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? Wenku8Error.unavailable("无法连接文库站点")
    }

    public func desktopPost(_ path: String, fields: [String: String]) async throws -> String {
        var lastError: Error?
        for host in endpoints.hosts {
            guard let url = URL(string: host + path) else { continue }
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.setValue(
                    "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                    forHTTPHeaderField: "Accept"
                )
                request.setValue(Self.desktopUserAgent, forHTTPHeaderField: "User-Agent")
                request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
                let body = fields
                    .map { "\(TextDecoding.formEncode($0.key))=\(TextDecoding.formEncode($0.value))" }
                    .joined(separator: "&")
                request.httpBody = Data(body.utf8)
                let response = try await send(request)
                return response.text
            } catch {
                lastError = error
            }
        }
        throw lastError ?? Wenku8Error.network("网络不可用")
    }

    private func withHostFallback(
        _ hosts: [String],
        path: String,
        referer: String?,
        desktop: Bool
    ) async throws -> String {
        var lastError: Error?
        for host in hosts {
            guard let url = URL(string: host + path) else { continue }
            do {
                var request = URLRequest(url: url)
                request.setValue(
                    "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                    forHTTPHeaderField: "Accept"
                )
                request.setValue(
                    desktop ? Self.desktopUserAgent : Self.wapUserAgent,
                    forHTTPHeaderField: "User-Agent"
                )
                if let referer {
                    request.setValue(referer, forHTTPHeaderField: "Referer")
                }
                let response = try await send(request)
                return response.text
            } catch {
                lastError = error
            }
        }
        throw lastError ?? Wenku8Error.network("网络不可用")
    }

    /// The site authenticates with `jieqiUserInfo`, **not** `PHPSESSID`.
    ///
    /// `PHPSESSID` is issued to anonymous visitors too, so treating it as the
    /// session made every visitor look signed in. Only the `jieqi*` cookies carry
    /// the account, and only they disappear on sign-out.
    public func sessionCookieValue() -> String? {
        let cookies = cookieStorage.cookies ?? []
        return cookies.first { $0.name == "jieqiUserInfo" }?.value
    }

    public func hasSession() -> Bool {
        !(sessionCookieValue() ?? "").isEmpty
    }

    /// Account name encoded in the `jieqiUserInfo` cookie, when present.
    public func sessionUserName() -> String? {
        guard let value = sessionCookieValue() else { return nil }
        return AccountParser.sessionUserName(fromCookie: value)
    }

    /// The site identifies a signed-in user purely by PHPSESSID, so signing out
    /// means dropping every cookie it issued for the wenku8 hosts.
    public func clearSessionCookies() {
        for cookie in cookieStorage.cookies ?? [] where cookie.domain.contains("wenku8") {
            cookieStorage.deleteCookie(cookie)
        }
    }

    static func isChallenge(_ data: Data) -> Bool {
        let probe = data.prefix(2048)
        guard let text = String(data: probe, encoding: .isoLatin1) else { return false }
        return text.contains("Just a moment") || text.contains("cf-mitigated")
    }

    public static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        switch nsError.code {
        case NSURLErrorNotConnectedToInternet:
            return "网络未连接，请检查网络设置"
        case NSURLErrorTimedOut:
            return "请求超时，请稍后重试"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "无法解析文库域名"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            return "安全连接失败，请检查网络环境"
        case NSURLErrorCancelled:
            return "请求已取消"
        default:
            return "网络异常：\(nsError.localizedDescription)"
        }
    }
}
