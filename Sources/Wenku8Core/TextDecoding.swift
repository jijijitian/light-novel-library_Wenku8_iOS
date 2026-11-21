import Foundation

public enum TextDecoding {
    public static func decode(_ data: Data) -> String {
        if data.isEmpty { return "" }

        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: data.dropFirst(3), as: UTF8.self)
        }

        if let text = String(data: data, encoding: .utf8), !text.contains("\u{FFFD}") {
            return text
        }

        if declaresGBK(data) {
            return decodeGBK(data)
        }

        let decoded = decodeGBK(data)
        if decoded.contains(where: { $0 != "\u{FFFD}" }) {
            return decoded
        }
        return String(decoding: data, as: UTF8.self)
    }

    public static func declaresGBK(_ data: Data) -> Bool {
        let probe = data.prefix(2048)
        guard let ascii = String(data: probe, encoding: .isoLatin1) else { return false }
        let lowered = ascii.lowercased()
        return lowered.contains("charset=gbk")
            || lowered.contains("charset=\"gbk\"")
            || lowered.contains("charset=gb2312")
            || lowered.contains("charset=\"gb2312\"")
    }

    /// Percent-encodes a string in GBK, for the parts of the site that still require it.
    ///
    /// The tag pages take their argument in GBK: the same tag sent as UTF-8 comes back as an
    /// empty list with a garbled heading, which is easy to mistake for "no such tag".
    /// Returns nil when a character has no GBK form.
    public static func formEncodeGBK(_ value: String) -> String? {
        var output = ""
        for scalar in value.unicodeScalars {
            if scalar.isASCII {
                guard let byte = String(scalar).addingPercentEncoding(
                    withAllowedCharacters: .alphanumerics
                ) else { return nil }
                output += byte
                continue
            }
            guard let bytes = GBKTable.bytes(for: scalar) else { return nil }
            output += bytes.map { String(format: "%%%02X", $0) }.joined()
        }
        return output
    }

    public static func decodeGBK(_ data: Data) -> String {
        let table = GBKTable.scalars
        guard !table.isEmpty else {
            return String(data: data, encoding: .utf8) ?? ""
        }

        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(data.count)
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte < 0x80 {
                scalars.append(Unicode.Scalar(byte))
                index += 1
                continue
            }
            guard index + 1 < bytes.count else {
                scalars.append("\u{FFFD}")
                break
            }
            let trail = Int(bytes[index + 1])
            let offset = trail < 0x7F ? trail - 0x40 : trail - 0x41
            let tableIndex = (Int(byte) - 0x81) * GBKTable.columns + offset
            if trail >= 0x40, trail <= 0xFE, trail != 0x7F,
               tableIndex >= 0, tableIndex < table.count,
               table[tableIndex] != 0,
               let scalar = Unicode.Scalar(UInt32(table[tableIndex])) {
                scalars.append(scalar)
            } else {
                scalars.append("\u{FFFD}")
            }
            index += 2
        }
        return String(String.UnicodeScalarView(scalars))
    }

    public static func formEncode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return value
        }
        return encoded
    }
}

/// Resource lookup that works in all three build shapes: SwiftPM (`Bundle.module`,
/// the CI and test path), the Xcode framework target (resources land in the
/// framework bundle), and a flattened app bundle.
enum CoreResources {
    #if SWIFT_PACKAGE
    static var bundle: Bundle { .module }
    #else
    static var bundle: Bundle {
        let name = "Wenku8Core.bundle"
        let candidates = [
            Bundle.main.url(forResource: "gbk-table", withExtension: "bin") != nil ? Bundle.main : nil,
            Bundle(for: BundleToken.self),
        ]
        for candidate in candidates {
            if let candidate,
               candidate.url(forResource: "gbk-table", withExtension: "bin") != nil {
                return candidate
            }
        }
        if let url = Bundle.main.url(forResource: name, withExtension: nil),
           let nested = Bundle(url: url),
           nested.url(forResource: "gbk-table", withExtension: "bin") != nil {
            return nested
        }
        return .main
    }
    #endif
}

private final class BundleToken {}

enum GBKTable {
    static let columns = 190

    /// scalar → its two GBK bytes, built once by walking the decode table.
    private static let encoding: [UInt32: (UInt8, UInt8)] = {
        var map: [UInt32: (UInt8, UInt8)] = [:]
        for (index, scalar) in scalars.enumerated() where scalar != 0 {
            let lead = 0x81 + index / columns
            let offset = index % columns
            guard lead <= 0xFE, offset < columns else { continue }
            let trail = offset < 0x3F ? 0x40 + offset : 0x41 + offset
            guard trail <= 0xFE else { continue }
            map[UInt32(scalar)] = (UInt8(lead), UInt8(trail))
        }
        return map
    }()

    static func bytes(for scalar: Unicode.Scalar) -> [UInt8]? {
        guard let pair = encoding[scalar.value] else { return nil }
        return [pair.0, pair.1]
    }

    static let scalars: [UInt16] = {
        guard let url = CoreResources.bundle.url(forResource: "gbk-table", withExtension: "bin"),
              let data = try? Data(contentsOf: url),
              data.count % 2 == 0 else {
            return []
        }
        var table = [UInt16](repeating: 0, count: data.count / 2)
        data.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt16.self)
            for index in table.indices {
                table[index] = UInt16(littleEndian: base[index])
            }
        }
        return table
    }()
}
