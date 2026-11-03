import Foundation

/// The computed properties supported by the current layout engine.
public struct CSSStyle {
    public var display = "inline"
    public var fontSize: Double = 16
    public var bold = false
    public var italic = false
    public var monospace = false
    public var color = "#202124"
    public var backgroundColor: String?
    public var marginTop: Double = 0
    public var marginBottom: Double = 0
    public var padding: Double = 0
    public var preformatted = false
    public var underline = false

    public init() {}
}

public struct StyleSheet {
    private var rules: [CSSRule]

    public init(css: String) { rules = CSSReader.rules(in: css) }

    public func style(for node: HTMLNode, inheriting parent: CSSStyle? = nil) -> CSSStyle {
        var style = CSSStyle()
        if let parent = parent {
            style.fontSize = parent.fontSize
            style.bold = parent.bold
            style.italic = parent.italic
            style.monospace = parent.monospace
            style.color = parent.color
            style.preformatted = parent.preformatted
            style.underline = parent.underline
        }
        applyDefaults(to: &style, node: node)
        let matched = rules.filter { $0.selector.matches(node) }.sorted {
            if $0.selector.specificity != $1.selector.specificity { return $0.selector.specificity < $1.selector.specificity }
            return $0.order < $1.order
        }
        let inline = CSSReader.declarations(in: node.attributes["style"] ?? "")
        let inheritedFontSize = parent?.fontSize ?? 16
        for important in [false, true] {
            for rule in matched {
                for declaration in rule.declarations where declaration.important == important {
                    apply(declaration, to: &style, parentSize: inheritedFontSize)
                }
            }
            for declaration in inline where declaration.important == important {
                apply(declaration, to: &style, parentSize: inheritedFontSize)
            }
        }
        return style
    }

    private func applyDefaults(to style: inout CSSStyle, node: HTMLNode) {
        guard let tag = node.tagName else {
            if case .document = node.kind { style.display = "block" }
            return
        }
        let blocks: Set<String> = ["html", "body", "address", "article", "aside", "blockquote", "center", "details", "dialog", "div", "dl", "dt", "dd", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup", "hr", "li", "main", "nav", "ol", "p", "pre", "section", "summary", "table", "thead", "tbody", "tfoot", "tr", "ul"]
        style.display = blocks.contains(tag) ? "block" : "inline"
        if ["head", "title", "base", "meta", "link", "style", "script", "template", "noscript", "source", "track", "param"].contains(tag) || node.attributes["hidden"] != nil { style.display = "none" }
        if ["strong", "b", "th"].contains(tag) { style.bold = true }
        if ["em", "i", "cite", "dfn", "var", "address"].contains(tag) { style.italic = true }
        if ["code", "pre", "kbd", "samp", "tt"].contains(tag) { style.monospace = true }
        if tag == "pre" { style.preformatted = true }
        if ["u", "ins"].contains(tag) { style.underline = true }
        if tag == "a", node.attributes["href"] != nil { style.color = "#245ac7"; style.underline = true }
        if ["p", "blockquote", "pre", "ul", "ol", "dl", "figure"].contains(tag) { style.marginTop = 12; style.marginBottom = 12 }
        if let level = Int(tag.dropFirst()), tag.first == "h", (1...6).contains(level) {
            let multiplier: [Double] = [2, 1.5, 1.17, 1, 0.83, 0.67]
            style.fontSize *= multiplier[level - 1]
            style.bold = true
            style.marginTop = 18
            style.marginBottom = 10
        }
        if tag == "small" { style.fontSize *= 0.83 }
        if tag == "big" { style.fontSize *= 1.2 }
        if tag == "hr" { style.marginTop = 14; style.marginBottom = 14 }
    }

    private func apply(_ declaration: CSSDeclaration, to style: inout CSSStyle, parentSize: Double) {
        let value = declaration.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = value.lowercased()
        switch declaration.name {
        case "display":
            if ["none", "inline", "block", "inline-block", "list-item", "table", "table-row", "table-cell", "flex", "grid"].contains(lower) {
                style.display = ["none", "inline"].contains(lower) ? lower : "block"
            }
        case "font-size":
            let keywords: [String: Double] = ["xx-small": 9, "x-small": 10, "small": 13, "medium": 16, "large": 18, "x-large": 24, "xx-large": 32]
            if let size = keywords[lower] ?? length(lower, relativeTo: parentSize) { style.fontSize = min(144, max(6, size)) }
            else if lower == "smaller" { style.fontSize = max(6, parentSize * 0.83) }
            else if lower == "larger" { style.fontSize = min(144, parentSize * 1.2) }
        case "font-weight":
            if ["bold", "bolder"].contains(lower) { style.bold = true }
            else if ["normal", "lighter"].contains(lower) { style.bold = false }
            else if let weight = Int(lower), (1...1000).contains(weight) { style.bold = weight >= 600 }
        case "font-style":
            if ["normal", "italic", "oblique"].contains(lower) { style.italic = lower != "normal" }
        case "font-family": style.monospace = ["monospace", "courier", "menlo", "monaco"].contains(where: lower.contains)
        case "color":
            if isColor(lower) { style.color = value }
        case "background-color", "background":
            if isColor(lower) { style.backgroundColor = value }
            if lower == "transparent" { style.backgroundColor = nil }
        case "margin-top":
            if let size = length(lower, relativeTo: style.fontSize) { style.marginTop = min(1000, max(-100, size)) }
        case "margin-bottom":
            if let size = length(lower, relativeTo: style.fontSize) { style.marginBottom = min(1000, max(-100, size)) }
        case "margin":
            let components = lower.split(whereSeparator: \.isWhitespace).map(String.init)
            if (1...4).contains(components.count) {
                if let top = length(components[0], relativeTo: style.fontSize) { style.marginTop = min(1000, max(-100, top)) }
                if let bottom = length(components.count > 2 ? components[2] : components[0], relativeTo: style.fontSize) { style.marginBottom = min(1000, max(-100, bottom)) }
            }
        case "padding":
            // This engine currently has one uniform inset rather than four independent sides.
            if let component = lower.split(whereSeparator: \.isWhitespace).first,
               let size = length(String(component), relativeTo: style.fontSize) { style.padding = min(300, max(0, size)) }
        case "white-space":
            if ["pre", "pre-wrap", "break-spaces"].contains(lower) { style.preformatted = true }
            else if ["normal", "nowrap", "pre-line"].contains(lower) { style.preformatted = false }
        case "text-decoration", "text-decoration-line":
            if lower == "none" { style.underline = false }
            else if lower.contains("underline") { style.underline = true }
        default: break
        }
    }

    private func length(_ value: String, relativeTo size: Double) -> Double? {
        let units: [(String, Double)] = [("rem", 16), ("em", size), ("px", 1), ("pt", 4.0 / 3), ("%", size / 100)]
        for (suffix, scale) in units where value.hasSuffix(suffix) {
            guard let number = Double(value.dropLast(suffix.count)), number.isFinite else { return nil }
            return number * scale
        }
        if let number = Double(value), number.isFinite, number == 0 { return 0 }
        return nil
    }

    private func isColor(_ value: String) -> Bool {
        if value.hasPrefix("#") {
            return [4, 5, 7, 9].contains(value.count) && value.dropFirst().allSatisfy(\.isHexDigit)
        }
        if value.hasPrefix("rgb(") || value.hasPrefix("rgba(") { return value.hasSuffix(")") }
        let names: Set<String> = ["black", "white", "red", "green", "blue", "gray", "grey", "silver", "maroon", "purple", "fuchsia", "lime", "olive", "yellow", "navy", "teal", "aqua", "orange", "transparent", "rebeccapurple", "darkgray", "darkgrey", "lightgray", "lightgrey"]
        return names.contains(value)
    }
}

private struct CSSDeclaration {
    let name: String
    let value: String
    let important: Bool
}

private struct CSSRule {
    let selector: CSSSelector
    let declarations: [CSSDeclaration]
    let order: Int
}

private struct CSSSpecificity: Comparable {
    var ids = 0
    var classes = 0
    var tags = 0
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.ids != rhs.ids { return lhs.ids < rhs.ids }
        if lhs.classes != rhs.classes { return lhs.classes < rhs.classes }
        return lhs.tags < rhs.tags
    }
}

private struct CSSCompound {
    var tag: String?
    var ids: [String] = []
    var classes: [String] = []
    var root = false
    var link = false

    func matches(_ node: HTMLNode) -> Bool {
        guard let name = node.tagName else { return false }
        if let tag = tag, tag != name { return false }
        if !ids.allSatisfy({ node.attributes["id"] == $0 }) { return false }
        let actualClasses = Set((node.attributes["class"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
        if !classes.allSatisfy(actualClasses.contains) { return false }
        if root, node.parent?.tagName != nil { return false }
        if link, name != "a" || node.attributes["href"] == nil { return false }
        return true
    }
}

private struct CSSSelector {
    var compounds: [CSSCompound]
    // A true entry means the preceding compound must match the immediate parent.
    var childRelations: [Bool]
    var specificity: CSSSpecificity

    init?(_ source: String) {
        let input = Array(source.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !input.isEmpty, input.count < 1000 else { return nil }
        var cursor = 0
        var parts: [CSSCompound] = []
        var relations: [Bool] = []
        var priority = CSSSpecificity()
        while cursor < input.count {
            var part = CSSCompound()
            var recognized = false
            if input[cursor] == "*" { cursor += 1; recognized = true }
            else if input[cursor].isLetter || input[cursor] == "_" || input[cursor] == "-" {
                let start = cursor
                while cursor < input.count && Self.isName(input[cursor]) { cursor += 1 }
                part.tag = String(input[start..<cursor]).lowercased()
                priority.tags += 1
                recognized = true
            }
            while cursor < input.count && [".", "#", ":"].contains(input[cursor]) {
                let prefix = input[cursor]
                cursor += 1
                let start = cursor
                while cursor < input.count && Self.isName(input[cursor]) { cursor += 1 }
                guard start < cursor else { return nil }
                let name = String(input[start..<cursor])
                switch prefix {
                case ".": part.classes.append(name); priority.classes += 1
                case "#": part.ids.append(name); priority.ids += 1
                default:
                    if name == "root" { part.root = true }
                    else if ["link", "any-link"].contains(name) { part.link = true }
                    else { return nil }
                    priority.classes += 1
                }
                recognized = true
            }
            guard recognized else { return nil }
            parts.append(part)
            let beforeWhitespace = cursor
            while cursor < input.count && input[cursor].isWhitespace { cursor += 1 }
            if cursor == input.count { break }
            if input[cursor] == ">" {
                relations.append(true)
                cursor += 1
                while cursor < input.count && input[cursor].isWhitespace { cursor += 1 }
                if cursor == input.count { return nil }
            } else if cursor > beforeWhitespace { relations.append(false) }
            else { return nil }
        }
        guard parts.count == relations.count + 1 else { return nil }
        compounds = parts
        childRelations = relations
        specificity = priority
    }

    func matches(_ node: HTMLNode) -> Bool {
        struct MatchKey: Hashable {
            let position: Int
            let node: ObjectIdentifier
            let maySkip: Bool
        }
        var memo: [MatchKey: Bool] = [:]
        func match(_ position: Int, _ candidate: HTMLNode?, maySkip: Bool) -> Bool {
            guard let candidate = candidate else { return false }
            let key = MatchKey(position: position, node: ObjectIdentifier(candidate), maySkip: maySkip)
            if let cached = memo[key] { return cached }
            var matched = false
            if compounds[position].matches(candidate) {
                matched = position == 0 || match(position - 1, candidate.parent, maySkip: !childRelations[position - 1])
            }
            // A descendant relation can choose a more distant ancestor when the
            // closest matching compound does not satisfy the rest of the selector.
            if !matched && maySkip { matched = match(position, candidate.parent, maySkip: true) }
            memo[key] = matched
            return matched
        }
        return match(compounds.count - 1, node, maySkip: false)
    }

    private static func isName(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "-"
    }
}

private enum CSSReader {
    static func rules(in source: String) -> [CSSRule] {
        let input = Array(removingComments(String(source.prefix(500_000))))
        var cursor = 0
        var output: [CSSRule] = []
        while cursor < input.count && output.count < 5000 {
            while cursor < input.count && input[cursor].isWhitespace { cursor += 1 }
            let start = cursor
            var quote: Character?
            while cursor < input.count {
                let character = input[cursor]
                if character == "\\" { cursor = min(cursor + 2, input.count); continue }
                if let current = quote { if current == character { quote = nil } }
                else if character == "\"" || character == "'" { quote = character }
                else if character == "{" || character == ";" { break }
                cursor += 1
            }
            guard cursor < input.count else { break }
            if input[cursor] == ";" { cursor += 1; continue }
            let selector = String(input[start..<cursor]).trimmingCharacters(in: .whitespacesAndNewlines)
            cursor += 1
            let bodyStart = cursor
            var depth = 1
            quote = nil
            while cursor < input.count && depth > 0 {
                let character = input[cursor]
                if character == "\\" { cursor = min(cursor + 2, input.count); continue }
                if let current = quote { if current == character { quote = nil } }
                else if character == "\"" || character == "'" { quote = character }
                else if character == "{" { depth += 1 }
                else if character == "}" { depth -= 1; if depth == 0 { break } }
                cursor += 1
            }
            let body = String(input[bodyStart..<cursor])
            if cursor < input.count { cursor += 1 }
            // At-rules need their own evaluation model; do not accidentally apply their nested rules.
            if selector.hasPrefix("@") { continue }
            let properties = declarations(in: body)
            for candidate in selector.split(separator: ",") {
                if let parsed = CSSSelector(String(candidate)) {
                    output.append(CSSRule(selector: parsed, declarations: properties, order: output.count))
                }
            }
        }
        return output
    }

    static func declarations(in source: String) -> [CSSDeclaration] {
        let input = Array(removingComments(String(source.prefix(100_000))))
        var pieces: [String] = []
        var start = 0
        var cursor = 0
        var quote: Character?
        var parentheses = 0
        while cursor < input.count {
            let character = input[cursor]
            if character == "\\" { cursor = min(cursor + 2, input.count); continue }
            if let current = quote { if current == character { quote = nil } }
            else if character == "\"" || character == "'" { quote = character }
            else if character == "(" { parentheses += 1 }
            else if character == ")" { parentheses = max(0, parentheses - 1) }
            else if character == ";" && parentheses == 0 {
                pieces.append(String(input[start..<cursor]))
                start = cursor + 1
            }
            cursor += 1
        }
        pieces.append(String(input[start..<input.count]))
        return pieces.compactMap { piece in
            guard let separator = piece.firstIndex(of: ":") else { return nil }
            let name = piece[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = piece[piece.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            let important = value.lowercased().hasSuffix("!important")
            if important { value = String(value.dropLast(10)).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !name.isEmpty && !value.isEmpty else { return nil }
            return CSSDeclaration(name: name, value: value, important: important)
        }
    }

    private static func removingComments(_ source: String) -> String {
        let input = Array(source)
        var result = ""
        var cursor = 0
        var quote: Character?
        while cursor < input.count {
            let character = input[cursor]
            if character == "\\", cursor + 1 < input.count {
                result.append(character)
                result.append(input[cursor + 1])
                cursor += 2
                continue
            }
            if let current = quote {
                if character == current { quote = nil }
            } else if character == "\"" || character == "'" { quote = character }
            else if character == "/", cursor + 1 < input.count, input[cursor + 1] == "*" {
                cursor += 2
                while cursor + 1 < input.count && !(input[cursor] == "*" && input[cursor + 1] == "/") { cursor += 1 }
                cursor = min(cursor + 2, input.count)
                result.append(" ")
                continue
            }
            result.append(character)
            cursor += 1
        }
        return result
    }
}
