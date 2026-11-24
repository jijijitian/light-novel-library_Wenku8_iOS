import Foundation

/// Where illustration addresses come from for books the site no longer serves.
///
/// A delisted book keeps its catalogue but loses every reading page, so its illustration chapter
/// has no page to read addresses from. The addresses come from a small service that caches the
/// picture ids per chapter, and the address itself is built here.
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

/// How an illustration picture's address is laid out.
public enum IllustrationURL {
    /// The picture host. Pictures are served from the same place the website uses.
    public static let host = "https://pic.777743.xyz"

    /// The address of one picture.
    ///
    /// The host arranges them by book group, book, chapter and picture id:
    /// `<host>/<aid / 1000>/<aid>/<cid>/<pid>.jpg`.
    public static func address(aid: Int, cid: Int, pid: String) -> URL? {
        URL(string: "\(host)/\(aid / 1000)/\(aid)/\(cid)/\(pid).jpg")
    }
}

/// The service's reply for one chapter.
struct IllustrationReply: Decodable {
    var cid: Int
    var aid: Int
    var pids: [String]
}
