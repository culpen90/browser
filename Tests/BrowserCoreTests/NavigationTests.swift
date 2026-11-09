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

    func testTypedSearchKeepsAddressesAndRoundTripsQuery() {
        for input in ["pizza", "pizza?", "node.js tutorial", "  C++ & español?  ", "東京"] {
            let location = Address.resolveInput(input)
            XCTAssertEqual(location?.scheme, "browser")
            XCTAssertEqual(location.flatMap(WebSearch.query(in:)), input.trimmingCharacters(in: .whitespaces))
        }
        for input in ["example.com/search", "https://example.com/a b", "localhost", "server:8080",
                      "[::1]:8000/", "/tmp/page.html", "browser:home", "intranet/reports?token=abc"] {
            XCTAssertEqual(Address.resolveInput(input), Address.resolve(input), input)
        }
        for input in ["", "https://", "ssh://host", "https://user:secret@example.com",
                      "file://other-computer/page.html", "browser:search?q=test&extra=data", "javascript:alert(1)",
                      String(repeating: "é", count: 201)] {
            XCTAssertNil(Address.resolveInput(input), input)
        }
        let request = WebSearch.request(for: "C++ & café?", port: 12345, token: "fixture", safeSearch: 2)
        var form = URLComponents()
        form.percentEncodedQuery = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        XCTAssertEqual(form.queryItems?.first?.value, "C++ & café?")
        XCTAssertTrue(form.percentEncodedQuery?.contains("C%2B%2B") == true)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:12345/search")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Browser-Search-Token"), "fixture")
        XCTAssertTrue(form.queryItems?.contains(URLQueryItem(name: "safesearch", value: "2")) == true)
        XCTAssertEqual(Address.resolveInput("browser:search?q=a%2Fb"), WebSearch.location(for: "a/b"))
    }

    func testSearchResultsRequireWebDestinationsAndKeepPlainText() throws {
        let response = #"""
        {"results":[
            {"url":"https://example.com/page?q=1&next=2","title":"<Sample> & more","content":"A \"quoted\" result"},
            {"url":"https://example.com/page?q=1&next=2","title":"Duplicate"},
            {"url":"http://example.org/","title":""},
            {"url":"https://user:password@example.com/"},
            {"url":"javascript:alert(1)"},
            {"url":"file:///tmp/private"},
            {"url":"browser:search?q=hidden"},
            {"url":null}
        ]}
        """#
        let results = try WebSearch.decode(Data(response.utf8))
        XCTAssertEqual(results.map { $0.url.absoluteString }, ["https://example.com/page?q=1&next=2", "http://example.org/"])
        XCTAssertEqual(results.map(\.title), ["<Sample> & more", "example.org"])
        XCTAssertEqual(results.first?.snippet, "A \"quoted\" result")
        XCTAssertTrue(try WebSearch.decode(Data(#"{"results":[]}"#.utf8)).isEmpty)
        XCTAssertThrowsError(try WebSearch.decode(Data(#"{"results":[],"unresponsive_engines":[["brave","timeout"]]}"#.utf8))) {
            guard case WebSearchError.sourcesUnavailable = $0 else { return XCTFail("Unexpected search error") }
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
