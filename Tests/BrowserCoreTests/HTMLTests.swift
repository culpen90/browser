import XCTest
@testable import BrowserCore

final class HTMLTests: XCTestCase {
    func testQuotedAttributesEntitiesAndCaseInsensitiveMarkup() throws {
        let document = HTMLParser().parse("<!doctype html><HTML><HEAD><TITLE> A &amp; B </TITLE></HEAD><BODY><A HREF='next?a=1&amp;b=2' title=hello data-value=\"1 > 0\">Go &#x1F680;</A><br>tail</BODY></HTML>")
        XCTAssertEqual(document.title, "A & B")
        let link = try XCTUnwrap(document.body.descendants(tag: "a").first)
        XCTAssertEqual(link.attributes["href"], "next?a=1&b=2")
        XCTAssertEqual(link.attributes["data-value"], "1 > 0")
        XCTAssertEqual(link.textContent, "Go 🚀")
        XCTAssertEqual(document.body.children.last?.textContent, "tail")
        XCTAssertTrue(link.parent === document.body)
    }

    func testRawTextDoesNotCreateMarkupAndDecodesTitleOnly() {
        let document = HTMLParser().parse("<title>A &lt; B</title><style>p::before { content: '<b>&amp;'; }</style><script>if (a < b) x = '<div>value</div>';</script><p>visible</p>")
        XCTAssertEqual(document.title, "A < B")
        XCTAssertTrue(document.embeddedStyles.contains("<b>&amp;"))
        XCTAssertTrue(document.root.descendants(tag: "div").isEmpty)
        XCTAssertEqual(document.root.descendants(tag: "p").first?.textContent, "visible")
    }

    func testCommentsAndMalformedTagsDoNotEatSubsequentContent() {
        let document = HTMLParser().parse("<!-- <p>hidden</p> --><p>1 < 2 &amp; 3</p><div DATA-X='a' data-x='b'>end</div>")
        XCTAssertEqual(document.root.descendants(tag: "p").count, 1)
        XCTAssertEqual(document.root.descendants(tag: "p").first?.textContent, "1 < 2 & 3")
        XCTAssertEqual(document.root.descendants(tag: "div").first?.attributes["data-x"], "a")
    }

    func testOptionalParagraphAndListEndTags() throws {
        let document = HTMLParser().parse("<p>first<p>second<ul><li>one<li>two</ul><p>last")
        XCTAssertEqual(document.root.descendants(tag: "p").map(\.textContent), ["first", "second", "last"])
        let list = try XCTUnwrap(document.root.descendants(tag: "ul").first)
        XCTAssertEqual(list.children.compactMap(\.tagName), ["li", "li"])
        XCTAssertEqual(list.children.map(\.textContent), ["one", "two"])
    }

    func testBaseURLAndFallback() {
        let original = URL(string: "https://example.org/docs/index.html")!
        let document = HTMLParser().parse("<base href='../assets/'><a href='photo.png'>photo</a>")
        XCTAssertEqual(document.baseURL(relativeTo: original).absoluteString, "https://example.org/assets/")
        let invalid = HTMLParser().parse("<base href='javascript:alert(1)'>")
        XCTAssertEqual(invalid.baseURL(relativeTo: original), original)
    }

    func testNumericEntitiesAndUnknownEntities() {
        XCTAssertEqual(decodeHTMLEntities("&#65; &#x41; &#0; &#xD800; &#128; &unknown; &copy;"), "A A � � € &unknown; ©")
        XCTAssertEqual(decodeHTMLEntities("a &amp b &lt c"), "a & b < c")
    }

    func testExtremeNestingIsBounded() {
        let document = HTMLParser().parse(String(repeating: "<div>", count: 1500) + "content" + String(repeating: "</div>", count: 1500))
        var deepest = 0
        var pending: [(HTMLNode, Int)] = [(document.root, 0)]
        while let (node, depth) = pending.popLast() {
            deepest = max(deepest, depth)
            pending.append(contentsOf: node.children.map { ($0, depth + 1) })
        }
        XCTAssertLessThanOrEqual(deepest, 256)
        XCTAssertTrue(document.root.textContent.contains("content"))
    }
}
