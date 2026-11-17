import Foundation

public indirect enum Node: Equatable, Sendable {
    case text(String)
    case element(Element)
}

public struct Element: Equatable, Sendable {
    public var name: String
    public var attributes: [String: String]
    public var children: [Node]

    public init(name: String, attributes: [String: String] = [:], children: [Node] = []) {
        self.name = name
        self.attributes = attributes
        self.children = children
    }

    public var textContent: String {
        var buffer = ""
        for child in children {
            switch child {
            case .text(let value):
                buffer += value
            case .element(let element):
                if element.name == "br" {
                    buffer += "\n"
                } else if element.name == "p" || element.name == "div" {
                    buffer += "\n" + element.textContent + "\n"
                } else {
                    buffer += element.textContent
                }
            }
        }
        return buffer
    }

    public var childElements: [Element] {
        children.compactMap { child in
            if case .element(let element) = child { return element }
            return nil
        }
    }

    public func descendants() -> [Element] {
        var result: [Element] = []
        for element in childElements {
            result.append(element)
            result.append(contentsOf: element.descendants())
        }
        return result
    }

    public func firstElement(named name: String) -> Element? {
        if self.name == name { return self }
        for element in childElements {
            if let found = element.firstElement(named: name) { return found }
        }
        return nil
    }

    public func elements(named name: String) -> [Element] {
        descendants().filter { $0.name == name }
    }

    public func attribute(_ key: String) -> String? {
        attributes[key] ?? attributes[key.lowercased()]
    }
}

public enum MarkupToken: Equatable, Sendable {
    case text(String)
    case startTag(name: String, attributes: [String: String], selfClosing: Bool)
    case endTag(name: String)
}

public enum Markup {
    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr", "postfield",
    ]

    private static let blockBreaks: Set<String> = ["br", "p", "div", "card", "tr", "li", "ul", "table"]

    public static func tokenize(_ source: String) -> [MarkupToken] {
        var tokens: [MarkupToken] = []
        var textBuffer = ""
        let characters = Array(source)
        var index = 0

        func flush() {
            if !textBuffer.isEmpty {
                tokens.append(.text(textBuffer))
                textBuffer = ""
            }
        }

        while index < characters.count {
            let character = characters[index]
            if character != "<" {
                textBuffer.append(character)
                index += 1
                continue
            }

            if index + 1 < characters.count, characters[index + 1] == "!" {
                if source.hasPrefixAt(characters, index, "<!--") {
                    index += 4
                    while index < characters.count && !source.hasPrefixAt(characters, index, "-->") {
                        index += 1
                    }
                    index = min(index + 3, characters.count)
                } else if source.hasPrefixAt(characters, index, "<![CDATA[") {
                    index += 9
                    var cdata = ""
                    while index < characters.count && !source.hasPrefixAt(characters, index, "]]>") {
                        cdata.append(characters[index])
                        index += 1
                    }
                    index = min(index + 3, characters.count)
                    textBuffer += cdata
                } else {
                    while index < characters.count && characters[index] != ">" { index += 1 }
                    index += 1
                }
                continue
            }

            if index + 1 < characters.count, characters[index + 1] == "?" {
                index += 2
                while index < characters.count && !source.hasPrefixAt(characters, index, "?>") {
                    index += 1
                }
                index = min(index + 2, characters.count)
                continue
            }

            if index + 1 < characters.count, characters[index + 1] == "/" {
                var cursor = index + 2
                var name = ""
                while cursor < characters.count, characters[cursor] != ">" {
                    name.append(characters[cursor])
                    cursor += 1
                }
                flush()
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !trimmed.isEmpty {
                    tokens.append(.endTag(name: trimmed))
                }
                index = min(cursor + 1, characters.count)
                continue
            }

            var cursor = index + 1
            var name = ""
            while cursor < characters.count,
                  !characters[cursor].isWhitespace,
                  characters[cursor] != ">",
                  characters[cursor] != "/" {
                name.append(characters[cursor])
                cursor += 1
            }
            var attributes: [String: String] = [:]
            var selfClosing = false
            var finished = false

            while cursor < characters.count && !finished {
                let character = characters[cursor]
                if character == ">" {
                    cursor += 1
                    finished = true
                    break
                }
                if character == "/" {
                    if cursor + 1 < characters.count, characters[cursor + 1] == ">" {
                        selfClosing = true
                        cursor += 2
                        finished = true
                        break
                    }
                    cursor += 1
                    continue
                }
                if character.isWhitespace {
                    cursor += 1
                    continue
                }
                var key = ""
                while cursor < characters.count,
                      characters[cursor] != "=",
                      characters[cursor] != ">",
                      !characters[cursor].isWhitespace,
                      characters[cursor] != "/" {
                    key.append(characters[cursor])
                    cursor += 1
                }
                if cursor < characters.count, characters[cursor] == "=" {
                    cursor += 1
                    if cursor < characters.count, characters[cursor] == "\"" || characters[cursor] == "'" {
                        let quote = characters[cursor]
                        cursor += 1
                        var value = ""
                        while cursor < characters.count, characters[cursor] != quote {
                            value.append(characters[cursor])
                            cursor += 1
                        }
                        cursor += 1
                        attributes[key.lowercased()] = decodeEntities(value)
                    } else {
                        var value = ""
                        while cursor < characters.count,
                              !characters[cursor].isWhitespace,
                              characters[cursor] != ">" {
                            value.append(characters[cursor])
                            cursor += 1
                        }
                        attributes[key.lowercased()] = decodeEntities(value)
                    }
                } else if !key.isEmpty {
                    attributes[key.lowercased()] = ""
                }
            }

            flush()
            let lowered = name.lowercased()
            if lowered.hasPrefix("!") || lowered.isEmpty {
                index = min(cursor, characters.count)
                continue
            }
            tokens.append(.startTag(name: lowered, attributes: attributes, selfClosing: selfClosing || voidElements.contains(lowered)))
            index = min(cursor, characters.count)
        }

        flush()
        return tokens
    }

    public static func parse(_ source: String) -> Element {
        let tokens = tokenize(source)
        var root = Element(name: "#root")
        var stack: [Element] = []

        func append(_ node: Node) {
            if stack.isEmpty {
                root.children.append(node)
            } else {
                stack[stack.count - 1].children.append(node)
            }
        }

        for token in tokens {
            switch token {
            case .text(let value):
                append(.text(decodeEntities(value)))
            case .startTag(let name, let attributes, let selfClosing):
                if selfClosing {
                    append(.element(Element(name: name, attributes: attributes)))
                } else {
                    if stack.isEmpty {
                        let element = Element(name: name, attributes: attributes)
                        stack.append(element)
                    } else {
                        stack.append(Element(name: name, attributes: attributes))
                    }
                }
            case .endTag(let name):
                guard let position = stack.lastIndex(where: { $0.name == name }) else { continue }
                while stack.count > position {
                    let element = stack.removeLast()
                    append(.element(element))
                }
            }
        }

        while !stack.isEmpty {
            let element = stack.removeLast()
            append(.element(element))
        }
        return root
    }

    public static func lines(from source: String) -> [String] {
        let document = parse(source)
        var raw = ""
        flatten(document, into: &raw)
        return raw
            .components(separatedBy: "\n")
            .map { normalize($0) }
            .filter { !$0.isEmpty }
    }

    private static func flatten(_ element: Element, into buffer: inout String) {
        for child in element.children {
            switch child {
            case .text(let value):
                buffer += value
            case .element(let child):
                if child.name == "br" {
                    buffer += "\n"
                } else if blockBreaks.contains(child.name) {
                    buffer += "\n"
                    flatten(child, into: &buffer)
                    buffer += "\n"
                } else {
                    flatten(child, into: &buffer)
                }
            }
        }
    }

    /// Strips tags and entities so a fragment can be shown as plain text.
    /// Used for site notices that arrive wrapped in markup.
    public static func plainText(_ html: String) -> String {
        var text = ""
        var insideTag = false
        for character in html {
            if character == "<" {
                insideTag = true
            } else if character == ">" {
                insideTag = false
                text.append(" ")
            } else if !insideTag {
                text.append(character)
            }
        }
        return normalize(decodeEntities(text))
    }

    public static func normalize(_ value: String) -> String {
        let replacements: [(String, String)] = [
            ("\u{00A0}", " "),
            ("\r", ""),
            ("\t", " "),
            ("\u{3000}", "\u{3000}"),
        ]
        var text = value
        for (from, to) in replacements {
            text = text.replacingOccurrences(of: from, with: to)
        }
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public enum Item: Equatable, Sendable {
        case text(String)
        case anchor(href: String, text: String)
        case image(src: String)
        case lineBreak
    }

    public static func items(from source: String) -> [Item] {
        let tokens = tokenize(source)
        var items: [Item] = []
        var textBuffer = ""
        var anchorHref: String?
        var anchorText = ""
        var depth = 0

        func flushText() {
            if !textBuffer.isEmpty {
                let normalized = decodeEntities(textBuffer)
                items.append(.text(normalized))
                textBuffer = ""
            }
        }

        for token in tokens {
            switch token {
            case .text(let value):
                if depth > 0 {
                    anchorText += decodeEntities(value)
                } else {
                    textBuffer += decodeEntities(value)
                }
            case .startTag(let name, let attributes, let selfClosing):
                switch name {
                case "br":
                    flushText()
                    items.append(.lineBreak)
                case "a":
                    flushText()
                    anchorHref = attributes["href"]
                    anchorText = ""
                    depth += 1
                case "img":
                    flushText()
                    if let src = attributes["src"], !src.isEmpty {
                        items.append(.image(src: src))
                    }
                case "p", "div", "card":
                    flushText()
                    items.append(.lineBreak)
                default:
                    if selfClosing && name == "postfield" {
                        continue
                    }
                }
            case .endTag(let name):
                switch name {
                case "a":
                    flushText()
                    if let href = anchorHref {
                        items.append(.anchor(href: href, text: normalize(anchorText)))
                    }
                    anchorHref = nil
                    anchorText = ""
                    if depth > 0 { depth -= 1 }
                case "p", "div", "card":
                    flushText()
                    items.append(.lineBreak)
                default:
                    break
                }
            }
        }
        flushText()
        return items
    }

    public static func decodeEntities(_ value: String) -> String {
        guard value.contains("&") else { return value }
        var result = ""
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            if character != "&" {
                result.append(character)
                index = value.index(after: index)
                continue
            }
            guard let semicolon = value[index...].firstIndex(of: ";"),
                  value.distance(from: index, to: semicolon) <= 10 else {
                result.append(character)
                index = value.index(after: index)
                continue
            }
            let body = String(value[value.index(after: index)..<semicolon])
            if let replacement = entityValue(body) {
                result += replacement
                index = value.index(after: semicolon)
            } else {
                result.append(character)
                index = value.index(after: index)
            }
        }
        return result
    }

    private static func entityValue(_ body: String) -> String? {
        switch body.lowercased() {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return "\u{00A0}"
        case "hellip": return "\u{2026}"
        case "mdash": return "\u{2014}"
        case "ndash": return "\u{2013}"
        case "ldquo": return "\u{201C}"
        case "rdquo": return "\u{201D}"
        case "lsquo": return "\u{2018}"
        case "rsquo": return "\u{2019}"
        case "middot": return "\u{00B7}"
        case "copy": return "\u{00A9}"
        case "times": return "\u{00D7}"
        default: break
        }
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            var value: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            if let value, let scalar = Unicode.Scalar(value) {
                return String(Character(scalar))
            }
        }
        return nil
    }

    public static func attribute(_ name: String, in tag: String) -> String? {
        let document = parse(tag)
        if let element = document.descendants().first(where: { $0.attributes[name] != nil }) {
            return element.attributes[name]
        }
        return nil
    }
}

private extension String {
    func hasPrefixAt(_ characters: [Character], _ index: Int, _ prefix: String) -> Bool {
        let prefixCharacters = Array(prefix)
        guard index + prefixCharacters.count <= characters.count else { return false }
        for offset in 0..<prefixCharacters.count where characters[index + offset] != prefixCharacters[offset] {
            return false
        }
        return true
    }
}
