import Foundation

/// Keeps the relay's session cookies across launches.
///
/// The app talks to two hosts with two independent sessions: `wenku8.net` for the
/// website (whose `jieqiUserInfo` cookie persists fine) and the relay host, whose
/// cookies were being lost on relaunch. The relay then answered "not signed in" for
/// every shelf call, so the shelf appeared empty until the reader signed in again.
///
/// `HTTPCookieStorage.shared` does persist, but not reliably for this host: the
/// cookies are written on a best-effort basis and can be evicted between runs. This
/// store mirrors them into `UserDefaults` whenever they change and restores them at
/// launch, which is cheap and makes the relay session deterministic.
enum SharedCookieStore {
    private static let key = "relay.cookies"

    /// Every cookie currently held for the relay host.
    private static var relayCookies: [HTTPCookie] {
        HTTPCookieStorage.shared.cookies?.filter { cookie in
            RelayHost.isRelay(cookie.domain)
        } ?? []
    }

    /// Re-installs the saved cookies. Safe to call at launch, before any request.
    static func restoreRelayCookies() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = decode(data) else { return }
        for cookie in decoded {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    /// Records the relay's cookies so the next launch can restore them.
    ///
    /// Called after a login and after any request that might have refreshed them; an
    /// empty set clears the saved copy too, so signing out leaves no credentials.
    static func persistRelayCookies() {
        let cookies = relayCookies
        guard !cookies.isEmpty else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        guard let data = encode(cookies) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Encodes cookies as a property list of their property dictionaries.
    ///
    /// `HTTPCookie` is not archivable on every platform (Linux has no `NSCoding`
    /// support for it), so the properties — which are plain strings — are stored
    /// instead. Values are coerced back to strings on the way in, because
    /// `HTTPCookie(properties:)` rejects anything else.
    static func encode(_ cookies: [HTTPCookie]) -> Data? {
        let raw: [[String: String]] = cookies.map { cookie in
            cookie.properties?.reduce(into: [String: String]()) { result, pair in
                result[pair.key.rawValue] = String(describing: pair.value)
            } ?? [:]
        }
        return try? PropertyListSerialization.data(
            fromPropertyList: raw,
            format: .binary,
            options: 0
        )
    }

    static func decode(_ data: Data) -> [HTTPCookie]? {
        guard let raw = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [[String: String]] else { return nil }
        return raw.compactMap { entry in
            let properties = entry.reduce(into: [HTTPCookiePropertyKey: Any]()) { result, pair in
                result[HTTPCookiePropertyKey(pair.key)] = pair.value
            }
            return HTTPCookie(properties: properties)
        }
    }

    /// Forgets both the live cookies and the saved copy.
    static func clearRelayCookies() {
        for cookie in relayCookies {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// Identifies the relay host from a cookie domain.
enum RelayHost {
    /// The production relay. Matched by suffix so a `RelayConfiguration` override
    /// pointing at a subdomain still gets its cookies persisted.
    static let defaultHostFragment = "mewx.org"

    static func isRelay(_ domain: String) -> Bool {
        domain.contains(defaultHostFragment) || domain.contains("wenku8-relay")
    }
}
