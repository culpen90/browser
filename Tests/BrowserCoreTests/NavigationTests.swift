import XCTest
@testable import BrowserCore

final class NavigationTests: XCTestCase {
    func testAddressResolutionAndAllowedSchemes() {
        XCTAssertEqual(Address.resolve(" example.com/a?q=b ")?.absoluteString, "https://example.com/a?q=b")
        XCTAssertEqual(Address.resolve("localhost:8080/next")?.absoluteString, "http://localhost:8080/next")
        XCTAssertEqual(Address.resolve("127.0.0.1:9000/")?.scheme, "http")
        XCTAssertEqual(Address.resolve("[::1]:8000/")?.scheme, "http")
        XCTAssertEqual(Address.resolve("https://example.com/a b")?.path, "/a b")
        XCTAssertEqual(Address.resolve("browser:home")?.absoluteString, "browser:home")
        XCTAssertTrue(Address.resolve("/tmp/page.html")?.isFileURL == true)
        XCTAssertTrue(Address.resolve("file:///tmp/page.html")?.isFileURL == true)
        for input in ["", "hello world", "https://", "javascript:alert(1)", "javascript:1234", "data:text/html,hello", "mailto:person@example.com", "browser:settings", "https://user:password@example.com", "example.com:99999", "file://other-computer/a.html", "ftp://example.com"] {
            XCTAssertNil(Address.resolve(input), input)
        }
    }

    func testHistoryTraversalAndBranching() {
        let a = URL(string: "https://a.example/")!, b = URL(string: "https://b.example/")!, c = URL(string: "https://c.example/")!
        var history = NavigationHistory()
        XCTAssertNil(history.current)
        XCTAssertNil(history.back())
        history.push(a)
        history.push(b)
        history.push(b)
        XCTAssertEqual(history.entries.count, 2)
        XCTAssertEqual(history.back(), a)
        XCTAssertTrue(history.canGoForward)
        XCTAssertEqual(history.forward(), b)
        XCTAssertEqual(history.back(), a)
        history.push(c)
        XCTAssertEqual(history.entries, [a, c])
        XCTAssertFalse(history.canGoForward)
        history.replaceCurrent(b)
        XCTAssertEqual(history.current, b)
        XCTAssertEqual(history.index, 1)
    }
}
