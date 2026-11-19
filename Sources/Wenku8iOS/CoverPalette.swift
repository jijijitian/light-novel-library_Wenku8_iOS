import SwiftUI
import Wenku8Core
import UIKit

/// A colour pair drawn from a book's cover.
///
/// The idea is Novella's: a book's page should carry the mood of its cover rather than the
/// app's fixed accent. Novella builds a full Material tonal scheme from a seed colour; this
/// takes the two colours the page actually needs — a vivid tint and a deeper companion for
/// the gradient beneath the type.
struct CoverPalette: Equatable {
    var tint: Color
    var deep: Color

    /// Whether the reader wants pages tinted by their covers.
    static let storageKey = "appearance.coverTint"

    private static let cache = NSCache<NSString, CacheBox>()

    private final class CacheBox {
        let palette: CoverPalette
        init(_ palette: CoverPalette) { self.palette = palette }
    }

    /// Extracts the palette for a book, reading the stored cover when there is one.
    static func palette(for novelID: Int, remoteURL: URL?) async -> CoverPalette? {
        let key = "\(novelID)" as NSString
        if let box = cache.object(forKey: key) { return box.palette }

        var data: Data?
        if let local = await OfflineStore.shared.storedCoverURL(for: novelID) {
            data = try? Data(contentsOf: local)
        } else if let remoteURL {
            data = try? await URLSession.shared.data(from: remoteURL).0
        }
        guard let data, let image = UIImage(data: data)?.cgImage,
              let palette = palette(from: image) else { return nil }
        cache.setObject(CacheBox(palette), forKey: key)
        return palette
    }

    #if DEBUG
    /// Number of extractions performed, so the cache can be shown to work.
    nonisolated(unsafe) static var extractions = 0
    #endif

    /// Finds the cover's dominant hue and builds a usable pair from it.
    ///
    /// A straight average of a cover is usually grey mud, because artwork is mostly
    /// background and skin tones. Weighting each pixel by how saturated it is, and grouping
    /// by hue, picks the colour a person would name if asked what the cover looks like.
    static func palette(from image: CGImage) -> CoverPalette? {
        #if DEBUG
        extractions += 1
        #endif

        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        // Hue buckets, each accumulating a saturation-weighted running average.
        var weight = [CGFloat](repeating: 0, count: 24)
        var sumR = [CGFloat](repeating: 0, count: 24)
        var sumG = [CGFloat](repeating: 0, count: 24)
        var sumB = [CGFloat](repeating: 0, count: 24)

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = CGFloat(pixels[index]) / 255
            let g = CGFloat(pixels[index + 1]) / 255
            let b = CGFloat(pixels[index + 2]) / 255
            let hsb = Self.hsb(r: r, g: g, b: b)
            // Near-grey, near-black and near-white pixels say nothing about the cover's
            // colour; including them is what turns a vivid cover into a grey average.
            guard hsb.s > 0.18, hsb.b > 0.15, hsb.b < 0.97 else { continue }
            let w = hsb.s * (1 - abs(hsb.b - 0.55))
            let bucket = min(23, max(0, Int(hsb.h * 24)))
            weight[bucket] += w
            sumR[bucket] += r * w
            sumG[bucket] += g * w
            sumB[bucket] += b * w
        }

        guard let best = weight.indices.max(by: { weight[$0] < weight[$1] }),
              weight[best] > 0 else { return nil }

        let total = weight[best]
        let r = sumR[best] / total
        let g = sumG[best] / total
        let b = sumB[best] / total
        var hsb = Self.hsb(r: r, g: g, b: b)

        // Push the colour to something that reads as a deliberate tint rather than a wash.
        // Averaging inside a hue bucket pulls a cover's colour towards grey, so the floor
        // matters more than the multiplier.
        hsb.s = min(1, max(0.52, hsb.s * 1.25))
        hsb.b = min(0.80, max(0.44, hsb.b))

        let tint = Color(hue: hsb.h, saturation: hsb.s, brightness: hsb.b)
        let deep = Color(hue: hsb.h, saturation: min(1, hsb.s * 1.05), brightness: hsb.b * 0.45)
        return CoverPalette(tint: tint, deep: deep)
    }

    private static func hsb(r: CGFloat, g: CGFloat, b: CGFloat) -> (h: CGFloat, s: CGFloat, b: CGFloat) {
        let maxValue = max(r, g, b)
        let minValue = min(r, g, b)
        let delta = maxValue - minValue
        var hue: CGFloat = 0
        if delta > 0 {
            if maxValue == r {
                hue = (g - b) / delta
            } else if maxValue == g {
                hue = 2 + (b - r) / delta
            } else {
                hue = 4 + (r - g) / delta
            }
            hue = (hue / 6).truncatingRemainder(dividingBy: 1)
            if hue < 0 { hue += 1 }
        }
        let saturation = maxValue == 0 ? 0 : delta / maxValue
        return (hue, saturation, maxValue)
    }
}

/// The detail page's backdrop, tinted by the cover when the reader asked for it.
struct TintedBackground: View {
    var palette: CoverPalette?

    var body: some View {
        ZStack {
            AppBackground()
            if let palette {
                // A full-height wash, so the whole page carries the cover's colour instead
                // of a single corner glowing and everything below it staying white.
                LinearGradient(
                    stops: [
                        .init(color: palette.tint.opacity(0.42), location: 0),
                        .init(color: palette.tint.opacity(0.20), location: 0.45),
                        .init(color: palette.deep.opacity(0.26), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                // A brighter bloom behind the cover, which is where the colour comes from.
                RadialGradient(
                    colors: [palette.tint.opacity(0.45), palette.tint.opacity(0)],
                    center: .topLeading,
                    startRadius: 20,
                    endRadius: 900
                )
                // And a deeper one at the far corner, so the wash has depth rather than
                // reading as a flat overlay.
                RadialGradient(
                    colors: [palette.deep.opacity(0.35), palette.deep.opacity(0)],
                    center: .bottomTrailing,
                    startRadius: 20,
                    endRadius: 900
                )
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.45), value: palette)
    }
}
