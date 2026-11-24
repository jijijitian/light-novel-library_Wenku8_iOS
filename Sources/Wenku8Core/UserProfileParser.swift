import Foundation

/// The account details the site prints on its own profile page.
///
/// The page is a two-column table — a label cell and its value — so it is read as a list of
/// pairs rather than by looking for each field in turn. Fields the site adds later then appear
/// without a parser change, and a field it drops simply goes missing.
public struct UserProfile: Sendable, Hashable, Codable {
    /// The avatar the site shows, if the account has set one.
    public var avatarURL: URL?
    /// Label/value pairs in the order the page prints them.
    ///
    /// A list of pairs rather than a fixed set of properties: the page prints whatever fields the
    /// site has, and a shape that names them would drop anything added later.
    public var fields: [Field]

    /// One label and its value.
    public struct Field: Sendable, Hashable, Codable, Identifiable {
        public var label: String
        public var value: String
        public var id: String { label }

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public var userID: String? { value("用户ID") }
    public var userName: String? { value("用户名") }
    public var nickname: String? { value("昵称") }
    public var rank: String? { value("等级") }
    public var title: String? { value("头衔") }
    public var registeredAt: String? { value("注册日期") }
    public var experience: String? { value("经验值") }
    public var points: String? { value("现有积分") }

    public func value(_ label: String) -> String? {
        let wanted = label.trimmingCharacters(in: .whitespaces)
        return fields.first { $0.label == wanted || $0.label == wanted + "：" }?.value
    }
}

public enum UserProfileParser {
    /// Reads the profile table.
    ///
    /// Every row is `<td class="odd">label</td><td class="even">value</td>`; the label keeps its
    /// trailing colon, which is stripped.
    public static func parse(_ html: String) -> UserProfile? {
        // Comments are removed before anything is read: the page keeps rows the site has retired
        // inside `<!-- -->`, and a parser that ignores the markers reports fields the site no
        // longer shows.
        let html = unprotectEmails(html.replacingOccurrences(
            of: "<!--[\\s\\S]*?-->",
            with: "",
            options: .regularExpression
        ))
        guard let regex = try? NSRegularExpression(
            pattern: #"<td[^>]*class="odd"[^>]*>(.*?)</td>\s*<td[^>]*class="even"[^>]*>(.*?)</td>"#,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else { return nil }
        let ns = html as NSString
        var fields: [UserProfile.Field] = []
        var seen = Set<String>()
        let range = NSRange(location: 0, length: ns.length)
        // Labels the account left blank are dropped rather than shown as empty rows: this
        // account has no MSN, website or signature, and a row of nothing says only that.
        let blankLabels: Set<String> = ["MSN", "网站", "用户签名", "推广链接"]
        for match in regex.matches(in: html, range: range) {
            let label = clean(ns.substring(with: match.range(at: 1)))
                .trimmingCharacters(in: CharacterSet(charactersIn: "：:"))
            let value = clean(ns.substring(with: match.range(at: 2)))
            guard !label.isEmpty, !value.isEmpty, !blankLabels.contains(label),
                  seen.insert(label).inserted else { continue }
            fields.append(UserProfile.Field(label: label, value: value))
        }
        guard !fields.isEmpty else { return nil }

        var avatar: URL?
        if let avatarRegex = try? NSRegularExpression(
            pattern: #"<img[^>]*class="avatar"[^>]*src="([^"]+)""#,
            options: [.caseInsensitive]
        ), let found = avatarRegex.firstMatch(in: html, range: range),
           let src = Range(found.range(at: 1), in: html) {
            let raw = String(html[src])
            avatar = URL(string: raw.hasPrefix("//") ? "https:" + raw : raw)
        }
        return UserProfile(avatarURL: avatar, fields: fields)
    }

    /// Decodes Cloudflare's address obfuscation.
    ///
    /// The site puts a mail address through Cloudflare's protection, which leaves
    /// `<span class="__cf_email__" data-cfemail="…">[email&#160;protected]</span>` in the markup
    /// and fills the real address in with a script. The hex is the address itself: the first byte
    /// is a key, and every following byte is the character XORed with it.
    static func decodeCloudflareEmail(_ hex: String) -> String? {
        let bytes = stride(from: 0, to: hex.count, by: 2).compactMap { offset -> UInt8? in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            guard let end = hex.index(start, offsetBy: 2, limitedBy: hex.endIndex) else { return nil }
            return UInt8(hex[start..<end], radix: 16)
        }
        guard let key = bytes.first, bytes.count > 1 else { return nil }
        return String(bytes.dropFirst().map { Character(UnicodeScalar($0 ^ key)) })
    }

    /// Replaces every protected address with the address it stands for.
    private static func unprotectEmails(_ html: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"<span[^>]*class="__cf_email__"[^>]*data-cfemail="([0-9a-fA-F]+)"[^>]*>.*?</span>"#,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else { return html }
        let ns = html as NSString
        var result = html
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).reversed() {
            let hex = ns.substring(with: match.range(at: 1))
            guard let address = decodeCloudflareEmail(hex),
                  let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: address)
        }
        return result
    }

    /// Strips tags and collapses whitespace, so a cell holding `<b>推广链接：</b>` reads as text.
    private static func clean(_ raw: String) -> String {
        let withoutTags = raw.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )
        let decoded = Markup.decodeEntities(withoutTags)
        return decoded
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
