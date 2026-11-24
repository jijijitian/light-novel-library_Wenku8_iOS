import Foundation

/// Where illustration addresses come from for books the site no longer serves.
///
/// A delisted book keeps its catalogue but loses every reading page, so its illustration chapter
/// has no page to read addresses from. The addresses are fetched from a small service that caches
/// them per chapter.
public enum IllustrationService {
    /// The service's base address.
    ///
    /// Set `WENKU8_ILLUSTRATION_SERVICE` to point elsewhere — a local instance, or an address that
    /// changes without a new build. When unset the deployed service is used.
    public static var baseURL: URL? {
        if let raw = ProcessInfo.processInfo.environment["WENKU8_ILLUSTRATION_SERVICE"],
           !raw.isEmpty {
            return URL(string: raw)
        }
        return URL(string: "http://47.110.95.241:8080")
    }
}

/// The service's reply for one chapter.
struct IllustrationReply: Decodable {
    var cid: Int
    var aid: Int
    var images: [String]
}
