import Foundation

/// A node in the engine's document tree. Parsing never invokes a system HTML renderer.
public final class HTMLNode {
    public enum Kind {
        case document
        case element(String)
        case text(String)
    }

    public let kind: Kind
    public var attributes: [String: String]
    public var children: [HTMLNode]
    public weak var parent: HTMLNode?

    public init(kind: Kind, attributes: [String: String] = [:], children: [HTMLNode] = []) {
        self.kind = kind
        self.attributes = attributes
        self.children = children
        for child in children { child.parent = self }
    }

    public var tagName: String? {
        if case .element(let name) = kind { return name }
        return nil
    }

    public var textContent: String {
        if case .text(let text) = kind { return text }
        return children.map(\.textContent).joined()
    }

    public func descendants(tag: String) -> [HTMLNode] {
        let name = tag.lowercased()
        var found: [HTMLNode] = []
        var pending = Array(children.reversed())
        while let node = pending.popLast() {
            if node.tagName == name { found.append(node) }
            pending.append(contentsOf: node.children.reversed())
        }
        return found
    }
}

public struct HTMLDocument {
    public let root: HTMLNode

    public init(root: HTMLNode) { self.root = root }

    public var title: String {
        let value = root.descendants(tag: "title").first?.textContent ?? ""
        return value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    public var body: HTMLNode { root.descendants(tag: "body").first ?? root }
    public var embeddedStyles: String { root.descendants(tag: "style").map(\.textContent).joined(separator: "\n") }

    public func baseURL(relativeTo url: URL) -> URL {
        guard let href = root.descendants(tag: "base").first?.attributes["href"],
              let resolved = URL(string: href, relativeTo: url)?.absoluteURL,
              ["http", "https", "file"].contains(resolved.scheme?.lowercased() ?? "") else { return url }
        return resolved
    }
}

public struct HTMLParser {
    public init() {}

    public func parse(_ source: String) -> HTMLDocument {
        var scanner = HTMLScanner(source)
        return scanner.parse()
    }
}

private struct HTMLScanner {
    // Limits bound allocations and recursion when reading hostile or malformed pages.
    private let input: [Character]
    private var index = 0
    private var nodeCount = 1
    private let root = HTMLNode(kind: .document)
    private var stack: [HTMLNode] = []
    private let voidTags: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
    private let paragraphClosers: Set<String> = ["address", "article", "aside", "blockquote", "div", "dl", "fieldset", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "main", "nav", "ol", "p", "pre", "section", "table", "ul"]
    private let headings: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]

    init(_ source: String) {
        input = Array(source.prefix(4_000_000))
        stack = [root]
    }

    mutating func parse() -> HTMLDocument {
        while index < input.count && nodeCount < 80_000 {
            if input[index] != "<" {
                let start = index
                while index < input.count && input[index] != "<" { index += 1 }
                appendText(decodeHTMLEntities(String(input[start..<index])))
                continue
            }
            if matches("<!--") {
                index += 4
                while index < input.count && !matches("-->") { index += 1 }
                index = min(input.count, index + 3)
            } else if matches("<!") || matches("<?") {
                skipTag()
            } else if matches("</") {
                index += 2
                skipWhitespace()
                let name = readName().lowercased()
                while index < input.count && input[index] != ">" { index += 1 }
                if index < input.count { index += 1 }
                if let position = stack.lastIndex(where: { $0.tagName == name }) {
                    stack.removeSubrange(position...)
                }
            } else if index + 1 < input.count && input[index + 1].isASCIILetter {
                parseStartTag()
            } else {
                appendText("<")
                index += 1
            }
        }
        return HTMLDocument(root: root)
    }

    private mutating func parseStartTag() {
        index += 1
        let name = readName().lowercased()
        var attributes: [String: String] = [:]
        var selfClosing = false
        while index < input.count {
            skipWhitespace()
            if index >= input.count { break }
            if input[index] == ">" { index += 1; break }
            if input[index] == "/" && index + 1 < input.count && input[index + 1] == ">" {
                selfClosing = true
                index += 2
                break
            }
            let start = index
            while index < input.count && !input[index].isWhitespace && !["=", ">", "/"].contains(input[index]) { index += 1 }
            guard start < index else { index += 1; continue }
            let key = String(input[start..<index]).lowercased()
            skipWhitespace()
            var value = ""
            if index < input.count && input[index] == "=" {
                index += 1
                skipWhitespace()
                if index < input.count && (input[index] == "\"" || input[index] == "'") {
                    let quote = input[index]
                    index += 1
                    let valueStart = index
                    while index < input.count && input[index] != quote { index += 1 }
                    value = String(input[valueStart..<index])
                    if index < input.count { index += 1 }
                } else {
                    let valueStart = index
                    while index < input.count && !input[index].isWhitespace && input[index] != ">" { index += 1 }
                    value = String(input[valueStart..<index])
                }
            }
            // HTML keeps the first occurrence of duplicate attributes.
            if attributes[key] == nil { attributes[key] = decodeHTMLEntities(value) }
        }
        closeImplicitElements(before: name)
        let element = HTMLNode(kind: .element(name), attributes: attributes)
        append(element)
        if ["script", "style", "title", "textarea"].contains(name) {
            let start = index
            while index < input.count {
                if matches("</" + name, caseInsensitive: true) {
                    let following = index + name.count + 2
                    if following >= input.count || input[following].isWhitespace || input[following] == ">" { break }
                }
                index += 1
            }
            let raw = String(input[start..<index])
            let text = ["title", "textarea"].contains(name) ? decodeHTMLEntities(raw) : raw
            if !text.isEmpty {
                let child = HTMLNode(kind: .text(text))
                child.parent = element
                element.children.append(child)
                nodeCount += 1
            }
            if index < input.count { skipTag() }
        } else if !voidTags.contains(name) && !selfClosing && stack.count < 256 {
            stack.append(element)
        }
    }

    private mutating func closeImplicitElements(before tag: String) {
        if paragraphClosers.contains(tag), let open = stack.lastIndex(where: { $0.tagName == "p" }) {
            stack.removeSubrange(open...)
        }
        if tag == "li" {
            for position in stack.indices.reversed() {
                if stack[position].tagName == "li" { stack.removeSubrange(position...); break }
                if ["ul", "ol"].contains(stack[position].tagName ?? "") { break }
            }
        }
        if headings.contains(tag), headings.contains(stack.last?.tagName ?? "") { stack.removeLast() }
        if ["dt", "dd"].contains(tag), ["dt", "dd"].contains(stack.last?.tagName ?? "") { stack.removeLast() }
        if tag == "tr", stack.last?.tagName == "tr" { stack.removeLast() }
        if ["td", "th"].contains(tag), ["td", "th"].contains(stack.last?.tagName ?? "") { stack.removeLast() }
    }

    private mutating func append(_ node: HTMLNode) {
        let parent = stack.last ?? root
        node.parent = parent
        parent.children.append(node)
        nodeCount += 1
    }

    private mutating func appendText(_ text: String) {
        guard !text.isEmpty else { return }
        append(HTMLNode(kind: .text(text)))
    }

    private mutating func skipTag() {
        var quote: Character?
        while index < input.count {
            let character = input[index]
            index += 1
            if let current = quote {
                if character == current { quote = nil }
            } else if character == "\"" || character == "'" { quote = character }
            else if character == ">" { return }
        }
    }

    private mutating func skipWhitespace() {
        while index < input.count && input[index].isWhitespace { index += 1 }
    }

    private mutating func readName() -> String {
        let start = index
        while index < input.count && (input[index].isASCIILetter || input[index].isNumber || ["-", ":", "_"].contains(input[index])) { index += 1 }
        return String(input[start..<index])
    }

    private func matches(_ value: String, caseInsensitive: Bool = false) -> Bool {
        let characters = Array(value)
        guard index + characters.count <= input.count else { return false }
        for offset in characters.indices {
            let actual = input[index + offset]
            if caseInsensitive {
                if actual.lowercased() != characters[offset].lowercased() { return false }
            } else if actual != characters[offset] { return false }
        }
        return true
    }
}

private extension Character {
    var isASCIILetter: Bool {
        guard let scalar = unicodeScalars.first, unicodeScalars.count == 1 else { return false }
        return (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }
}

/// Decodes the numeric references and common named references understood by this engine.
public func decodeHTMLEntities(_ text: String) -> String {
    let named: [String: String] = [
        "amp": "&", "AMP": "&", "lt": "<", "LT": "<", "gt": ">", "GT": ">", "quot": "\"", "QUOT": "\"", "apos": "'", "nbsp": "\u{00a0}",
        "copy": "©", "reg": "®", "trade": "™", "mdash": "—", "ndash": "–", "hellip": "…", "laquo": "«", "raquo": "»", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "bull": "•", "middot": "·", "times": "×", "divide": "÷", "plusmn": "±", "deg": "°", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "sect": "§", "para": "¶", "micro": "µ", "acute": "´", "auml": "ä", "ouml": "ö", "uuml": "ü", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "szlig": "ß", "eacute": "é", "Eacute": "É", "agrave": "à", "aacute": "á", "acirc": "â", "ecirc": "ê", "egrave": "è", "ntilde": "ñ", "ccedil": "ç", "aring": "å", "oslash": "ø", "rarr": "→", "larr": "←", "uarr": "↑", "darr": "↓", "ne": "≠", "le": "≤", "ge": "≥", "infin": "∞"
    ]
    guard text.contains("&") else { return text }
    let characters = Array(text)
    var result = ""
    var cursor = 0
    while cursor < characters.count {
        guard characters[cursor] == "&" else { result.append(characters[cursor]); cursor += 1; continue }
        var end = cursor + 1
        while end < characters.count && end - cursor <= 32 && (characters[end].isLetter || characters[end].isNumber || characters[end] == "#") { end += 1 }
        let semicolon = end < characters.count && characters[end] == ";"
        let key = String(characters[(cursor + 1)..<end])
        var replacement: String?
        if key.hasPrefix("#") {
            let hex = key.hasPrefix("#x") || key.hasPrefix("#X")
            let digits = String(key.dropFirst(hex ? 2 : 1))
            if !digits.isEmpty, let number = UInt32(digits, radix: hex ? 16 : 10) {
                let substitutions: [UInt32: UInt32] = [0x80: 0x20ac, 0x82: 0x201a, 0x83: 0x0192, 0x84: 0x201e, 0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021, 0x88: 0x02c6, 0x89: 0x2030, 0x8a: 0x0160, 0x8b: 0x2039, 0x8c: 0x0152, 0x8e: 0x017d, 0x91: 0x2018, 0x92: 0x2019, 0x93: 0x201c, 0x94: 0x201d, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014, 0x98: 0x02dc, 0x99: 0x2122, 0x9a: 0x0161, 0x9b: 0x203a, 0x9c: 0x0153, 0x9e: 0x017e, 0x9f: 0x0178]
                let scalar = substitutions[number] ?? number
                replacement = scalar == 0 ? "�" : UnicodeScalar(scalar).map(String.init) ?? "�"
            }
        } else if semicolon || ["amp", "lt", "gt", "quot", "nbsp"].contains(key) {
            replacement = named[key]
        }
        if let value = replacement {
            result += value
            cursor = end + (semicolon ? 1 : 0)
        } else {
            result.append("&")
            cursor += 1
        }
    }
    return result
}
