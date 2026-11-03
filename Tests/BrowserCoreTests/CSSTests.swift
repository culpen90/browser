import XCTest
@testable import BrowserCore

final class CSSTests: XCTestCase {
    func testSpecificitySourceOrderAndInlineStyles() throws {
        let document = HTMLParser().parse("<p class='notice' id='target'>hello</p><p class='notice' style='color: green'>inline</p>")
        let nodes = document.root.descendants(tag: "p")
        let sheet = StyleSheet(css: "#target { color: red; } .notice { color: blue; } p { color: black; } .notice { font-size: 20px; } .notice { font-size: 21px; }")
        XCTAssertEqual(sheet.style(for: nodes[0]).color, "red")
        XCTAssertEqual(sheet.style(for: nodes[0]).fontSize, 21)
        XCTAssertEqual(sheet.style(for: nodes[1]).color, "green")
    }

    func testImportantDeclarationsBeatInlineNormalAndKeepOrder() {
        let document = HTMLParser().parse("<p id='target' style='color: green; font-size: 18px !important'>hello</p>")
        let node = document.root.descendants(tag: "p")[0]
        let sheet = StyleSheet(css: "p {color: blue !important; color: orange; font-size: 24px !important} #target { color: red !important; }")
        let style = sheet.style(for: node)
        XCTAssertEqual(style.color, "red")
        XCTAssertEqual(style.fontSize, 18)
    }

    func testInheritedPropertiesAndNoninheritedBoxValues() {
        let document = HTMLParser().parse("<div><span>text</span></div>")
        let parent = document.root.descendants(tag: "div")[0]
        let child = document.root.descendants(tag: "span")[0]
        let sheet = StyleSheet(css: "div { color: red; font-size: 20px; font-weight: bold; background: blue; margin: 12px; padding: 8px } span { font-size: 1.5em }")
        let parentStyle = sheet.style(for: parent)
        let childStyle = sheet.style(for: child, inheriting: parentStyle)
        XCTAssertEqual(childStyle.fontSize, 30)
        XCTAssertEqual(childStyle.color, "red")
        XCTAssertTrue(childStyle.bold)
        XCTAssertNil(childStyle.backgroundColor)
        XCTAssertEqual(childStyle.padding, 0)
        XCTAssertEqual(childStyle.marginTop, 0)
        XCTAssertEqual(childStyle.display, "inline")
    }

    func testDescendantChildAndCompoundSelectors() {
        let document = HTMLParser().parse("<div class='outer'><section><a class='action selected'>deep</a></section><a class='action'>direct</a></div>")
        let links = document.root.descendants(tag: "a")
        let sheet = StyleSheet(css: ".outer a.action { color: red } .outer > a.action { color: green } a.action.selected { font-weight: bold }")
        XCTAssertEqual(sheet.style(for: links[0]).color, "red")
        XCTAssertEqual(sheet.style(for: links[1]).color, "green")
        XCTAssertTrue(sheet.style(for: links[0]).bold)
        XCTAssertFalse(sheet.style(for: links[1]).bold)
    }

    func testDefaultsAndHiddenContent() {
        let document = HTMLParser().parse("<h1>Heading</h1><p>text <strong>bold</strong></p><script>bad()</script><div hidden>hidden</div><a href='next'>link</a><pre>spaces</pre>")
        let sheet = StyleSheet(css: "")
        XCTAssertEqual(sheet.style(for: document.root.descendants(tag: "h1")[0]).fontSize, 32)
        XCTAssertEqual(sheet.style(for: document.root.descendants(tag: "script")[0]).display, "none")
        XCTAssertEqual(sheet.style(for: document.root.descendants(tag: "div")[0]).display, "none")
        XCTAssertTrue(sheet.style(for: document.root.descendants(tag: "a")[0]).underline)
        XCTAssertTrue(sheet.style(for: document.root.descendants(tag: "pre")[0]).preformatted)
    }

    func testDescendantMatchingRetriesAncestorsForEarlierChildRelation() {
        let document = HTMLParser().parse("<div class='outer'><div class='mid'><div><div class='mid'><p class='leaf'>match</p></div></div></div></div><div class='outer'><div><div class='mid'><p class='leaf'>no match</p></div></div></div>")
        let leaves = document.root.descendants(tag: "p")
        let sheet = StyleSheet(css: ".outer > .mid .leaf {color: red}")
        XCTAssertEqual(sheet.style(for: leaves[0]).color, "red")
        XCTAssertEqual(sheet.style(for: leaves[1]).color, "#202124")
    }

    func testCommentsQuotedSemicolonsUnknownSelectorsAndAtRules() {
        let document = HTMLParser().parse("<p class='target'>hello</p>")
        let node = document.root.descendants(tag: "p")[0]
        let sheet = StyleSheet(css: "/* p {color: blue} */ @media print { p { color: red } } p:hover { color: red } .target { font-family: 'thing;other', monospace; color: rgb(1, 2, 3); margin: 10px 0 20px; } p {padding: 4px}")
        let style = sheet.style(for: node)
        XCTAssertEqual(style.color, "rgb(1, 2, 3)")
        XCTAssertTrue(style.monospace)
        XCTAssertEqual(style.marginTop, 10)
        XCTAssertEqual(style.marginBottom, 20)
        XCTAssertEqual(style.padding, 4)
    }

    func testInvalidValuesDoNotPoisonComputedStyle() {
        let document = HTMLParser().parse("<p>text</p>")
        let node = document.root.descendants(tag: "p")[0]
        let sheet = StyleSheet(css: "p {font-size: nanpx; color: totally-invalid; margin: bogus; padding: -20px}")
        let style = sheet.style(for: node)
        XCTAssertEqual(style.fontSize, 16)
        XCTAssertEqual(style.color, "#202124")
        XCTAssertEqual(style.marginTop, 12)
        XCTAssertEqual(style.padding, 0)
    }
}
