import AppKit
import XCTest
import BrowserCore
@testable import BrowserApp

final class RenderingTests: XCTestCase {
    func testWordsWrapWithinTheViewportAndReflowOnResize() async {
        await MainActor.run {
            let source = "<p>alpha beta gamma delta epsilon zeta eta theta</p>"
            let narrow = render(source, width: 240)
            let wide = render(source, width: 800)
            let narrowText = textBoxes(narrow)
            let wideText = textBoxes(wide)
            XCTAssertEqual(narrowText.map(\.text), wideText.map(\.text))
            XCTAssertGreaterThan(Set(narrowText.map { $0.rect.minY }).count,
                                 Set(wideText.map { $0.rect.minY }).count)
            for item in narrowText {
                XCTAssertGreaterThanOrEqual(item.rect.minX, 28)
                XCTAssertLessThanOrEqual(item.rect.maxX, 212.1)
            }

            let longWord = textBoxes(render("<p>" + String(repeating: "W", count: 100) + "</p>", width: 240))
            XCTAssertGreaterThan(Set(longWord.map { $0.rect.minY }).count, 1)
            XCTAssertTrue(longWord.allSatisfy { $0.rect.maxX <= 212.1 })
        }
    }

    func testNestedInlineTextRetainsResolvedLinkTargets() async {
        await MainActor.run {
            let page = render("<p>before <a href='../next.html#part'><strong>linked</strong> words</a> after</p>")
            let text = textBoxes(page)
            XCTAssertEqual(text.map(\.text), ["before", "linked", "words", "after"])
            let target = URL(string: "https://example.org/next.html#part")!
            XCTAssertEqual(text.filter { $0.link != nil }.map(\.text), ["linked", "words"])
            XCTAssertTrue(text.filter { $0.link != nil }.allSatisfy { $0.link == target })
            XCTAssertNil(text.first?.link)
            XCTAssertNil(text.last?.link)
        }
    }

    func testMetadataScriptsAndHiddenSubtreesAreNotPainted() async {
        await MainActor.run {
            let page = render("""
            <html><head><title>metadata</title><style>p {color: red}</style></head><body>
            <p>Visible <span hidden>hidden</span></p><script>secret script</script>
            <div style='display: none'><a href='/hidden'>hidden link</a></div><p>End</p>
            </body></html>
            """)
            XCTAssertEqual(textBoxes(page).map(\.text), ["Visible", "End"])
            XCTAssertTrue(page.items.allSatisfy { $0.link == nil })
        }
    }

    func testDescendantBackgroundDoesNotExpandToCoverItsAncestors() async throws {
        try await MainActor.run {
            let page = render("<html><body><div><p style='background: red'>red-only</p><p>white</p></div></body></html>")
            let backgrounds: [NSRect] = page.items.compactMap {
                if case .fill(let rect, _) = $0 { return rect }
                return nil
            }
            XCTAssertEqual(backgrounds.count, 1)
            let background = try XCTUnwrap(backgrounds.first)
            let text = textBoxes(page)
            let red = try XCTUnwrap(text.first(where: { $0.text == "red-only" }))
            let white = try XCTUnwrap(text.first(where: { $0.text == "white" }))
            XCTAssertTrue(background.contains(red.rect))
            XCTAssertLessThan(background.maxY, white.rect.minY)
        }
    }

    func testImagesScaleToTheViewportAndRetainTheirLink() async throws {
        try await MainActor.run {
            let imageURL = URL(string: "https://example.org/docs/photo.png")!
            let image = NSImage(size: NSSize(width: 900, height: 450))
            let page = render("<figure><a href='/photo'><img src='photo.png' alt='photo'></a></figure><p>below</p>",
                              width: 360, images: [imageURL: image])
            let imageItems: [(NSRect, URL?)] = page.items.compactMap {
                if case .image(_, let rect, let link) = $0 { return (rect, link) }
                return nil
            }
            XCTAssertEqual(imageItems.count, 1)
            let item = try XCTUnwrap(imageItems.first)
            XCTAssertEqual(item.0.width, 304, accuracy: 0.1)
            XCTAssertEqual(item.0.height, 152, accuracy: 0.1)
            XCTAssertEqual(item.1?.absoluteString, "https://example.org/photo")
            let below = try XCTUnwrap(textBoxes(page).first(where: { $0.text == "below" }))
            XCTAssertGreaterThanOrEqual(below.rect.minY, item.0.maxY)

            let missing = render("<p><img src='missing.png' alt='Portrait unavailable'></p>")
            XCTAssertEqual(textBoxes(missing).map(\.text).joined(separator: " "), "[Portrait unavailable]")
        }
    }

    func testCSSColorsAcceptedByTheCascadeCanBePainted() async throws {
        try await MainActor.run {
            let short = try XCTUnwrap(NSColor.css("#0f08")?.usingColorSpace(.sRGB))
            XCTAssertEqual(short.greenComponent, 1, accuracy: 0.001)
            XCTAssertEqual(short.alphaComponent, 136.0 / 255, accuracy: 0.001)
            let long = try XCTUnwrap(NSColor.css("#11223344")?.usingColorSpace(.sRGB))
            XCTAssertEqual(long.redComponent, 17.0 / 255, accuracy: 0.001)
            XCTAssertEqual(long.alphaComponent, 68.0 / 255, accuracy: 0.001)
            let function = try XCTUnwrap(NSColor.css("rgba(100%, 0%, 50%, 25%)")?.usingColorSpace(.sRGB))
            XCTAssertEqual(function.redComponent, 1, accuracy: 0.001)
            XCTAssertEqual(function.blueComponent, 0.5, accuracy: 0.001)
            XCTAssertEqual(function.alphaComponent, 0.25, accuracy: 0.001)
            for name in ["maroon", "fuchsia", "lime", "olive", "aqua", "darkgray", "darkgrey", "lightgray", "lightgrey"] {
                XCTAssertNotNil(NSColor.css(name), name)
            }
            XCTAssertNil(NSColor.css("not-a-color"))
        }
    }

    func testRemotePagesCannotReadLocalFileResources() async {
        await MainActor.run {
            let remote = URL(string: "https://example.org/")!
            let local = URL(fileURLWithPath: "/tmp/page.html")
            XCTAssertFalse(BrowserWindowController.resourceAllowed(local, from: remote))
            XCTAssertTrue(BrowserWindowController.resourceAllowed(local, from: local))
            XCTAssertTrue(BrowserWindowController.resourceAllowed(remote, from: local))
            XCTAssertTrue(BrowserWindowController.resourceAllowed(URL(string: "http://example.org/image.png")!, from: remote))
            for address in ["javascript:alert(1)", "data:text/html,hello", "ftp://example.org/a"] {
                XCTAssertFalse(BrowserWindowController.resourceAllowed(URL(string: address)!, from: remote))
            }
        }
    }
}

@MainActor
private func render(_ source: String, width: CGFloat = 800, images: [URL: NSImage] = [:]) -> PageLayout {
    let document = HTMLParser().parse(source)
    return CanvasLayouter(width: width, sheet: StyleSheet(css: document.embeddedStyles),
                          baseURL: URL(string: "https://example.org/docs/index.html")!, images: images).layout(document)
}

private struct TextBox {
    let text: String
    let rect: NSRect
    let link: URL?
}

private func textBoxes(_ layout: PageLayout) -> [TextBox] {
    layout.items.compactMap {
        if case .text(let text, let rect, let link) = $0 { return TextBox(text: text.string, rect: rect, link: link) }
        return nil
    }
}
