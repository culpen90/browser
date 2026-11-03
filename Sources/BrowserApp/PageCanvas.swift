import AppKit
import BrowserCore

/// A display list produced by our layout engine. AppKit only draws the primitives.
enum PaintItem {
    case text(NSAttributedString, NSRect, URL?)
    case fill(NSRect, NSColor)
    case rule(NSRect)
    case image(NSImage, NSRect, URL?)

    var rect: NSRect {
        switch self {
        case .text(_, let rect, _), .fill(let rect, _), .rule(let rect), .image(_, let rect, _): return rect
        }
    }
    var link: URL? {
        switch self { case .text(_, _, let url), .image(_, _, let url): return url; default: return nil }
    }
}

struct PageLayout {
    var items: [PaintItem] = []
    var anchors: [String: CGFloat] = [:]
    var height: CGFloat = 0
    var background: NSColor = .white
}

final class PageCanvas: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var onNavigate: ((URL) -> Void)?
    var onHover: ((String?) -> Void)?
    private var document: HTMLDocument?
    private var sheet = StyleSheet(css: "")
    private var baseURL = URL(string: "browser:home")!
    private var images: [URL: NSImage] = [:]
    private(set) var pageLayout = PageLayout()
    private var tracking: NSTrackingArea?
    private var lastWidth: CGFloat = 0
    private var focusedLink: Int?
    private var accessibilityElements: [NSAccessibilityElement] = []
    var textContent: String {
        var text = ""
        var previous: NSRect?
        for item in pageLayout.items {
            guard case .text(let value, let rect, _) = item else { continue }
            if let previous {
                if abs(previous.minY - rect.minY) > 1 { text += "\n" }
                else if rect.minX - previous.maxX > 0.5 { text += " " }
            }
            text += value.string
            previous = rect
        }
        return text
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Web page")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(document: HTMLDocument, css: String, baseURL: URL, images: [URL: NSImage] = [:]) {
        self.document = document
        self.sheet = StyleSheet(css: css)
        self.baseURL = baseURL
        self.images = images
        focusedLink = nil
        relayout()
    }

    func relayout() {
        guard let document else { return }
        let width = max(240, enclosingScrollView?.contentSize.width ?? bounds.width)
        lastWidth = width
        pageLayout = CanvasLayouter(width: width, sheet: sheet, baseURL: baseURL, images: images).layout(document)
        setFrameSize(NSSize(width: width, height: max(pageLayout.height, enclosingScrollView?.contentSize.height ?? 600)))
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        if abs((enclosingScrollView?.contentSize.width ?? bounds.width) - lastWidth) > 1 { relayout() }
    }

    override func draw(_ dirtyRect: NSRect) {
        pageLayout.background.setFill()
        dirtyRect.fill()
        for item in pageLayout.items where item.rect.intersects(dirtyRect) {
            switch item {
            case .text(let text, let rect, _): text.draw(at: rect.origin)
            case .fill(let rect, let color): color.setFill(); rect.fill()
            case .rule(let rect): NSColor(white: 0.82, alpha: 1).setFill(); rect.fill()
            case .image(let image, let rect, _):
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        if let focusedLink, linkItems.indices.contains(focusedLink) {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            NSBezierPath(roundedRect: linkItems[focusedLink].rect.insetBy(dx: -2, dy: -1), xRadius: 2, yRadius: 2).stroke()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    private func link(at point: NSPoint) -> URL? {
        pageLayout.items.reversed().first(where: { $0.rect.contains(point) && $0.link != nil })?.link
    }
    override func mouseMoved(with event: NSEvent) {
        let url = link(at: convert(event.locationInWindow, from: nil))
        (url == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
        onHover?(url?.absoluteString)
    }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set(); onHover?(nil) }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if let url = link(at: convert(event.locationInWindow, from: nil)) { onNavigate?(url) }
    }
    private var linkItems: [PaintItem] {
        var seen: Set<URL> = []
        return pageLayout.items.filter { item in
            guard let url = item.link else { return false }
            return seen.insert(url).inserted
        }
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 48:
            let items = linkItems
            guard !items.isEmpty else { return }
            let reverse = event.modifierFlags.contains(.shift)
            focusedLink = ((focusedLink ?? (reverse ? 0 : -1)) + (reverse ? -1 : 1) + items.count) % items.count
            scrollToVisible(items[focusedLink!].rect.insetBy(dx: -8, dy: -8)); needsDisplay = true
        case 36, 76:
            if let focusedLink, linkItems.indices.contains(focusedLink), let url = linkItems[focusedLink].link { onNavigate?(url) }
        case 125: scroll(NSPoint(x: 0, y: min(max(0, bounds.height - visibleRect.height), visibleRect.minY + 40)))
        case 126: scroll(NSPoint(x: 0, y: max(0, visibleRect.minY - 40)))
        case 121, 49: scroll(NSPoint(x: 0, y: min(max(0, bounds.height - visibleRect.height), visibleRect.minY + visibleRect.height * 0.85)))
        case 116: scroll(NSPoint(x: 0, y: max(0, visibleRect.minY - visibleRect.height * 0.85)))
        default: super.keyDown(with: event)
        }
    }
    override func accessibilityChildren() -> [Any]? {
        var segments: [(label: String, rect: NSRect, link: URL?)] = []
        for item in pageLayout.items.prefix(10_000) {
            let label: String
            switch item {
            case .text(let text, _, _): label = text.string
            case .image(_, _, _): label = "Image"
            default: continue
            }
            if let last = segments.last, last.link == item.link, abs(last.rect.minY - item.rect.minY) < 1 {
                segments[segments.count - 1] = (last.label + (item.rect.minX - last.rect.maxX > 0.5 ? " " : "") + label,
                                                last.rect.union(item.rect), item.link)
            } else { segments.append((label, item.rect, item.link)) }
        }
        var children: [NSAccessibilityElement] = []
        // Expose the custom display list as readable text and actionable links.
        for item in segments {
            let element = CanvasAccessibilityElement()
            element.setAccessibilityElement(true)
            element.setAccessibilityEnabled(true)
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(item.link == nil ? .staticText : .link)
            element.setAccessibilityLabel(item.label)
            if let window { element.setAccessibilityFrame(window.convertToScreen(convert(item.rect, to: nil))) }
            if let url = item.link { element.onPress = { [weak self] in self?.onNavigate?(url) } }
            children.append(element)
        }
        accessibilityElements = children
        return accessibilityElements
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        if let url = link(at: convert(event.locationInWindow, from: nil)) {
            let item = menu.addItem(withTitle: "Copy Link", action: #selector(copyLink(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
        }
        let copy = menu.addItem(withTitle: "Copy Page Text", action: #selector(copyPageText(_:)), keyEquivalent: "")
        copy.target = self
        return menu
    }
    @objc private func copyLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
    @objc func copyPageText(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textContent, forType: .string)
    }
    func scrollToAnchor(_ fragment: String?) {
        let position = fragment.flatMap { pageLayout.anchors[$0.removingPercentEncoding ?? $0] } ?? 0
        scroll(NSPoint(x: 0, y: position))
    }
}

private final class CanvasAccessibilityElement: NSAccessibilityElement {
    var onPress: (() -> Void)?
    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress(); return true
    }
}

/// Block flow, inline whitespace collapsing, word wrapping, and a drawable display list.
/// No system HTML importer, web view, or third-party layout engine is involved.
final class CanvasLayouter {
    private let width: CGFloat
    private let sheet: StyleSheet
    private let baseURL: URL
    private let images: [URL: NSImage]
    private var result = PageLayout()
    private var left: CGFloat = 28
    private var right: CGFloat
    private var x: CGFloat = 28
    private var y: CGFloat = 24
    private var lineHeight: CGFloat = 0
    private var pendingSpace = false
    private var listCounters: [Int?] = []

    init(width: CGFloat, sheet: StyleSheet, baseURL: URL, images: [URL: NSImage]) {
        self.width = width; self.sheet = sheet; self.baseURL = baseURL; self.images = images
        right = max(212, width - 28)
    }

    func layout(_ document: HTMLDocument) -> PageLayout {
        let rootStyle = sheet.style(for: document.root, inheriting: nil)
        if let html = document.root.children.first(where: { $0.tagName == "html" }) {
            visit(html, inherited: rootStyle, link: nil)
        } else {
            visit(document.body, inherited: rootStyle, link: nil)
        }
        flushLine()
        result.height = y + 28
        return result
    }

    private func visit(_ node: HTMLNode, inherited: CSSStyle, link: URL?) {
        guard result.items.count < 40_000 else { return }
        if case .text(let text) = node.kind { addText(text, style: inherited, link: link); return }
        let style = sheet.style(for: node, inheriting: inherited)
        guard style.display != "none" else { return }
        let tag = node.tagName ?? ""
        if let id = node.attributes["id"] ?? node.attributes["name"] { result.anchors[id] = y }
        var activeLink = link
        if tag == "a", let href = node.attributes["href"] { activeLink = URL(string: href, relativeTo: baseURL)?.absoluteURL }
        if tag == "br" { flushLine(force: true, minimum: CGFloat(style.fontSize) * 1.4); return }
        if tag == "hr" {
            flushLine(); y += 12
            result.items.append(.rule(NSRect(x: left, y: y, width: right - left, height: 1)))
            y += 14; return
        }
        if tag == "img" { addImage(node, style: style, link: activeLink); return }
        let block = style.display == "block"
        let oldLeft = left, oldRight = right
        if block { flushLine(); y += CGFloat(style.marginTop) }
        let startY = y
        var backgroundIndex: Int?
        if tag == "body", let color = style.backgroundColor.flatMap(NSColor.css) { result.background = color }
        if block, let color = style.backgroundColor.flatMap(NSColor.css), tag != "body" {
            backgroundIndex = result.items.count
            result.items.append(.fill(.zero, color))
        }
        if block {
            left += min(CGFloat(style.padding), max(0, (right - left) / 4))
            right -= min(CGFloat(style.padding), max(0, (right - left) / 4))
            y += CGFloat(style.padding); x = left
        }
        if tag == "ul" || tag == "ol" { listCounters.append(tag == "ol" ? 1 : nil); left += 22; x = left }
        if tag == "li" {
            let marker: String
            if let count = listCounters.last ?? nil {
                marker = "\(count)."; listCounters[listCounters.count - 1] = count + 1
            } else { marker = "•" }
            let text = attributed(marker, style: style, link: nil)
            result.items.append(.text(text, NSRect(x: left - 20, y: y, width: 18, height: text.size().height), nil))
        }
        for child in node.children { visit(child, inherited: style, link: activeLink) }
        if tag == "ul" || tag == "ol" { _ = listCounters.popLast() }
        if block {
            flushLine()
            y += CGFloat(style.padding)
            if let backgroundIndex, backgroundIndex < result.items.count,
               case .fill(_, let color) = result.items[backgroundIndex] {
                result.items[backgroundIndex] = .fill(NSRect(x: oldLeft, y: startY, width: oldRight - oldLeft, height: max(0, y - startY)), color)
            }
            left = oldLeft; right = oldRight; x = left
            y += CGFloat(style.marginBottom)
        }
    }

    private func attributed(_ text: String, style: CSSStyle, link: URL?) -> NSAttributedString {
        let size = CGFloat(min(96, max(8, style.fontSize)))
        var font = style.monospace ? NSFont.monospacedSystemFont(ofSize: size, weight: style.bold ? .bold : .regular)
                                  : NSFont.systemFont(ofSize: size, weight: style.bold ? .bold : .regular)
        if style.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.css(style.color) ?? .black]
        if style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return NSAttributedString(string: text, attributes: attributes)
    }

    private func addText(_ text: String, style: CSSStyle, link: URL?) {
        if style.preformatted {
            for character in text.replacingOccurrences(of: "\r\n", with: "\n") {
                guard result.items.count < 40_000 else { return }
                if character == "\n" { flushLine(force: true, minimum: CGFloat(style.fontSize) * 1.4) }
                else { addWord(character == "\t" ? "    " : String(character), style: style, link: link, allowBreak: true) }
            }
        } else {
            var word = ""
            for character in text {
                guard result.items.count < 40_000 else { return }
                if character.isWhitespace {
                    if !word.isEmpty { addWord(word, style: style, link: link); word = "" }
                    pendingSpace = true
                } else { word.append(character) }
            }
            if !word.isEmpty { addWord(word, style: style, link: link) }
        }
    }

    private func addWord(_ word: String, style: CSSStyle, link: URL?, allowBreak: Bool = false) {
        guard result.items.count < 40_000 else { return }
        let value = attributed(word, style: style, link: link)
        let size = value.size()
        let space = pendingSpace && x > left ? attributed(" ", style: style, link: nil).size().width : 0
        if x > left && x + space + size.width > right { flushLine() }
        else { x += space }
        pendingSpace = false
        if size.width > right - left && !allowBreak && word.count > 1 {
            for character in word { addWord(String(character), style: style, link: link, allowBreak: true) }
            return
        }
        result.items.append(.text(value, NSRect(x: x, y: y, width: size.width, height: size.height), link))
        x += size.width
        lineHeight = max(lineHeight, ceil(size.height * 1.22))
    }

    private func flushLine(force: Bool = false, minimum: CGFloat = 0) {
        if lineHeight > 0 || force { y += max(lineHeight, minimum); lineHeight = 0 }
        x = left; pendingSpace = false
    }

    private func addImage(_ node: HTMLNode, style: CSSStyle, link: URL?) {
        guard let src = node.attributes["src"], let url = URL(string: src, relativeTo: baseURL)?.absoluteURL,
              let image = images[url], image.size.width > 0, image.size.height > 0 else {
            addText("[\(node.attributes["alt"] ?? "Image")]", style: style, link: link); return
        }
        var size = image.size
        if let raw = node.attributes["width"], let value = Double(raw), value > 0 { size.width = CGFloat(min(4096, value)); size.height = image.size.height * size.width / image.size.width }
        if let raw = node.attributes["height"], let value = Double(raw), value > 0 { size.height = CGFloat(min(4096, value)) }
        if size.width > right - left { let ratio = (right - left) / size.width; size.width *= ratio; size.height *= ratio }
        size.height = min(4096, size.height)
        flushLine()
        result.items.append(.image(image, NSRect(origin: NSPoint(x: left, y: y), size: size), link))
        y += size.height + 8
    }
}

extension NSColor {
    static func css(_ raw: String) -> NSColor? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let named: [String: String] = ["black":"#000000", "white":"#ffffff", "red":"#ff0000", "green":"#008000", "blue":"#0000ff", "gray":"#808080", "grey":"#808080", "silver":"#c0c0c0", "navy":"#000080", "teal":"#008080", "purple":"#800080", "orange":"#ffa500", "yellow":"#ffff00", "rebeccapurple":"#663399", "maroon":"#800000", "fuchsia":"#ff00ff", "lime":"#00ff00", "olive":"#808000", "aqua":"#00ffff", "darkgray":"#a9a9a9", "darkgrey":"#a9a9a9", "lightgray":"#d3d3d3", "lightgrey":"#d3d3d3"]
        if value == "transparent" { return .clear }
        let hex = named[value] ?? value
        if hex.hasPrefix("#") {
            var digits = String(hex.dropFirst())
            if digits.count == 3 || digits.count == 4 { digits = digits.map { "\($0)\($0)" }.joined() }
            if digits.count == 6 { digits += "ff" }
            guard digits.count == 8, let number = UInt32(digits, radix: 16) else { return nil }
            return NSColor(srgbRed: CGFloat((number >> 24) & 255) / 255, green: CGFloat((number >> 16) & 255) / 255, blue: CGFloat((number >> 8) & 255) / 255, alpha: CGFloat(number & 255) / 255)
        }
        if (value.hasPrefix("rgb(") || value.hasPrefix("rgba(")), value.hasSuffix(")") {
            let alpha = value.hasPrefix("rgba(")
            let components = value.dropFirst(alpha ? 5 : 4).dropLast().split(separator: ",")
            guard components.count == (alpha ? 4 : 3) else { return nil }
            var parts: [CGFloat] = []
            for (index, component) in components.enumerated() {
                let part = component.trimmingCharacters(in: .whitespaces)
                let percent = part.hasSuffix("%")
                guard let number = Double(percent ? String(part.dropLast()) : part), number.isFinite else { return nil }
                let divisor: Double = percent ? 100 : (index == 3 ? 1 : 255)
                parts.append(CGFloat(min(1, max(0, number / divisor))))
            }
            return NSColor(srgbRed: parts[0], green: parts[1], blue: parts[2], alpha: alpha ? parts[3] : 1)
        }
        return nil
    }
}
