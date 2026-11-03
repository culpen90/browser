import XCTest
@testable import BrowserCore

final class PageLoaderTests: XCTestCase {
    func testDeclaredMetaAndBOMEncodings() {
        let latin = Data([0x63, 0x61, 0x66, 0xE9])
        XCTAssertEqual(PageLoader.decode(latin, declaredEncoding: "iso-8859-1"), "café")
        var meta = Data("<meta charset='windows-1252'><p>".utf8)
        meta.append(latin)
        XCTAssertTrue(PageLoader.decode(meta, declaredEncoding: nil).contains("café"))
        let utf16 = Data([0xFF, 0xFE, 0x48, 0x00, 0x69, 0x00])
        XCTAssertEqual(PageLoader.decode(utf16, declaredEncoding: "windows-1252"), "Hi")
        XCTAssertEqual(PageLoader.decode(Data([0xEF, 0xBB, 0xBF, 0x48, 0x69]), declaredEncoding: nil), "Hi")
        XCTAssertEqual(PageLoader.decode(Data("日本語".utf8), declaredEncoding: nil), "日本語")
    }

    func testLocalHTMLAndTextAndLimits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let html = directory.appendingPathComponent("page.html")
        let text = directory.appendingPathComponent("page.txt")
        try Data("<title>Local</title><p>Hello</p>".utf8).write(to: html)
        try Data("<This is text>".utf8).write(to: text)
        let loader = PageLoader()
        let page = try await loader.load(html)
        XCTAssertEqual(page.url, html)
        XCTAssertFalse(page.isPlainText)
        XCTAssertTrue(page.html.contains("Hello"))
        let plain = try await loader.load(text)
        XCTAssertTrue(plain.isPlainText)
        XCTAssertEqual(plain.html, "<This is text>")
        do {
            _ = try await loader.resource(html, maxBytes: 4)
            XCTFail("Expected a bounded file load")
        } catch PageLoadError.tooLarge(let limit) { XCTAssertEqual(limit, 4) }
        do {
            _ = try await loader.load(directory)
            XCTFail("Expected directory rejection")
        } catch PageLoadError.notAFile {}
        do {
            _ = try await loader.load(URL(string: "javascript:alert(1)")!)
            XCTFail("Expected scheme rejection")
        } catch PageLoadError.unsupportedScheme {}
    }

    func testHTTPStatusMIMEAndStreamLimits() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let loader = PageLoader(session: URLSession(configuration: configuration))
        let page = try await loader.load(URL(string: "https://fixture.test/missing")!)
        XCTAssertEqual(page.statusCode, 404)
        XCTAssertTrue(page.html.contains("Missing"))
        do {
            _ = try await loader.resource(URL(string: "https://fixture.test/missing")!)
            XCTFail("Expected resource status rejection")
        } catch PageLoadError.resourceStatus(let status) { XCTAssertEqual(status, 404) }
        do {
            _ = try await loader.load(URL(string: "https://fixture.test/image")!)
            XCTFail("Expected binary document rejection")
        } catch PageLoadError.unsupportedContent(let type) { XCTAssertEqual(type, "image/png") }
        do {
            _ = try await loader.resource(URL(string: "https://fixture.test/chunked")!, maxBytes: 5)
            XCTFail("Expected streaming size rejection without Content-Length")
        } catch PageLoadError.tooLarge(let limit) { XCTAssertEqual(limit, 5) }
    }
}

private final class FixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let image = url.path == "/image"
        let missing = url.path == "/missing"
        let response = HTTPURLResponse(url: url, statusCode: missing ? 404 : 200,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": image ? "image/png" : "text/html; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((missing ? "<h1>Missing</h1>" : "1234567890").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
