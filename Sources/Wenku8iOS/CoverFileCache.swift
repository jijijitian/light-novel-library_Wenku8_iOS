import Foundation
import UIKit

/// Cover images, kept on disk so a book's cover is downloaded once and then shown from the
/// device forever.
///
/// `AsyncImage` was enough to display them but not to keep them: it leans on the shared
/// `URLCache`, which the system is free to purge and which a fresh install starts empty. The
/// result was a handful of covers spinning again after every update, for images that had
/// already been downloaded many times.
///
/// Files live under Application Support rather than Caches for the same reason: Caches is
/// exactly what the system empties when space is short.
final class CoverFileCache: @unchecked Sendable {
    static let shared = CoverFileCache()

    private let directory: URL
    private let memory = NSCache<NSString, UIImage>()
    private let session: URLSession
    /// URLs that failed, so a broken cover is asked for once per launch and not on every
    /// appearance.
    private var failed: Set<String> = []
    private let lock = NSLock()

    private init() {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = base.appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: configuration)

        memory.countLimit = 240
    }

    /// The image for a cover URL, from memory, from disk, or from the network in that order.
    func image(for url: URL) async -> UIImage? {
        let key = url.absoluteString as NSString
        if let cached = memory.object(forKey: key) { return cached }

        if failed.contains(url.absoluteString) { return nil }

        let file = directory.appendingPathComponent(Self.fileName(for: url))
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            memory.setObject(image, forKey: key)
            return image
        }

        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let image = UIImage(data: data) else {
            lock.lock()
            failed.insert(url.absoluteString)
            lock.unlock()
            return nil
        }

        try? data.write(to: file, options: .atomic)
        memory.setObject(image, forKey: key)
        return image
    }

    /// Keeps the file name stable per URL and safe for the file system.
    private static func fileName(for url: URL) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in url.absoluteString.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
        return String(hash, radix: 16) + "." + ext
    }
}
