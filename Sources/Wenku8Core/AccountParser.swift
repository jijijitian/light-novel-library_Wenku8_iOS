import Foundation

/// Login and bookcase responses on wenku8 are plain HTML/WML pages whose meaning
/// has to be read from the surrounding text:
///
/// - `login.php?do=submit` (desktop) answers with a "出现错误！/错误原因：…" page on
///   failure and a redirect on success (verified against the live site).
/// - `/wap/article/bookcase.php`, `addbookcase.php` and the bookcase mutations
///   answer with a login card when the session is missing.
public enum AccountParser {
    /// Extracts the human-readable reason from the desktop login error page.
    public static func loginErrorMessage(_ html: String) -> String? {
        guard html.contains("错误原因") || html.contains("出现错误") else { return nil }
        if let raw = firstMatch(#"错误原因：([^<]+)<"#, in: html) {
            return Markup.normalize(Markup.decodeEntities(raw))
        }
        return "登录失败，请检查账号与密码"
    }

    /// The WAP login flow uses a `msgwin` card with the message as bare text.
    public static func wapLoginMessage(_ html: String) -> String? {
        guard html.contains(#"<card id="msgwin""#) else { return nil }
        if let bullet = firstMatch(#"新书</a><br/>\s*(.+?)<br/>\s*<p align="center">"#, in: html) {
            let text = Markup.normalize(Markup.decodeEntities(bullet))
            if !text.isEmpty { return text }
        }
        return "登录失败，请检查账号与密码"
    }

    /// True when the page is the "please log in" card rather than real content.
    public static func isLoginGate(_ html: String) -> Bool {
        WAPParser.requiresLogin(html)
    }

    /// The account name shown in the WAP header (`您好!游客,` for anonymous users).
    public static func accountName(_ html: String) -> String? {
        guard let raw = firstMatch(#"您好!([^,<]+),"#, in: html) else { return nil }
        let name = Markup.decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return name == "游客" ? nil : name
    }

    /// Parses the WAP bookcase listing into the same summary shape the rest of the
    /// app uses, so a signed-in shelf can be merged with the local one.
    public static func bookcaseNovels(_ html: String) -> [NovelSummary] {
        WAPParser.linksIn(html)
    }

    /// The API returns a single integer result code; only the WAP/desktop surfaces
    /// are used here, so this just recognises the common success/duplicate cases.
    public static func mutationOutcome(_ html: String, novelID: Int) -> BookcaseMutationResult {
        if isLoginGate(html) { return .notSignedIn }
        if let message = firstMatch(#"新书</a><br/>\s*(.+?)<br/>\s*<p align="center">"#, in: html) {
            let text = Markup.normalize(Markup.decodeEntities(message))
            if text.contains("已在") || text.contains("已经") { return .alreadyPresent }
            if text.contains("满") { return .shelfFull }
            if text.contains("不在") { return .notPresent }
            if !text.isEmpty { return .failed(text) }
        }
        if html.contains(#"<card id="msgwin""#) {
            return .succeeded
        }
        return .succeeded
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators]
        ) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let found = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[found])
    }
}

public enum BookcaseMutationResult: Sendable, Equatable {
    case succeeded
    case alreadyPresent
    case notPresent
    case shelfFull
    case notSignedIn
    case failed(String)
}
