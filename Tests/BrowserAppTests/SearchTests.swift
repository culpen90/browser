import AppKit
import BrowserCore
import XCTest
@testable import BrowserApp

final class SearchTests: XCTestCase {
    @MainActor
    func testAddressBarSearchAndHistoryKeepProviderOutOfNavigation() async throws {
        let server = try CompatibilityFixtureServer()
        defer { server.stop() }
        _ = NSApplication.shared
        let destination = server.url("/second")
        var queries: [String] = []
        let browser = BrowserWindowController { query in
            queries.append(query)
            if query == "source failure test" { throw WebSearchError.sourcesUnavailable }
            return [.init(url: destination, title: "Sample <result>", snippet: "One & two")]
        }
        defer { browser.close() }

        submit("C++ & café", in: browser)
        let results = try await browser.observeForAgent()
        XCTAssertEqual(browser.addressField.stringValue, "C++ & café")
        XCTAssertEqual(browser.currentURL.scheme, "browser")
        XCTAssertTrue(results.text.contains("Browser Search"))
        XCTAssertTrue(results.text.contains("Sample <result>"))
        XCTAssertTrue(results.text.contains("One & two"))
        let result = try XCTUnwrap(results.elements.first { $0.url == destination.absoluteString })
        try await browser.performAgentAction(.click(result.id), on: results)
        _ = try await browser.observeForAgent()
        XCTAssertEqual(browser.addressField.stringValue, destination.absoluteString)

        browser.goBack(nil)
        let restored = try await browser.observeForAgent()
        XCTAssertEqual(browser.addressField.stringValue, "C++ & café")
        XCTAssertEqual(restored.text, results.text)
        XCTAssertEqual(queries, ["C++ & café"])

        browser.goForward(nil)
        _ = try await browser.observeForAgent()
        XCTAssertEqual(browser.addressField.stringValue, destination.absoluteString)
        submit("source failure test", in: browser)
        let limited = try await browser.observeForAgent()
        XCTAssertTrue(limited.text.contains("selected sources"))
        submit(destination.absoluteString, in: browser)
        let site = try await browser.observeForAgent()
        try await browser.performAgentAction(.back, on: site)
        let uncached = try await browser.observeForAgent()
        XCTAssertTrue(uncached.text.contains("Reload to run this search again"))
        XCTAssertEqual(queries, ["C++ & café", "source failure test"])
    }

    @MainActor
    func testSearchSettingsIsAnInternalPageAndPreferencesPersist() throws {
        _ = NSApplication.shared
        let name = "BrowserSearchFixture-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let service = LocalSearchService(resources: nil, defaults: defaults)
        let browser = BrowserWindowController(searchService: service)
        defer { browser.close() }
        XCTAssertEqual(service.snapshot.selected, ["brave", "duckduckgo"])
        XCTAssertEqual(service.snapshot.safeSearch, 1)
        browser.goHome(nil)
        browser.openSearchSettings(nil)
        XCTAssertEqual(browser.currentURL.absoluteString, "browser:search-settings")
        XCTAssertEqual(browser.window?.title, "Search Settings — Browser")
        service.update(.init(selected: ["bing"], safeSearch: 2))
        let restored = LocalSearchService(resources: nil, defaults: defaults)
        XCTAssertEqual(restored.snapshot.selected, ["bing"])
        XCTAssertEqual(restored.snapshot.safeSearch, 2)
        browser.goBack(nil)
        XCTAssertEqual(browser.currentURL.absoluteString, "browser:home")
        browser.goForward(nil)
        XCTAssertEqual(browser.currentURL.absoluteString, "browser:search-settings")
    }

    @MainActor
    func testLiveSearchFromAddressBar() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["BROWSER_TEST_LIVE_SEARCH"] == "1")
        let resources = try XCTUnwrap(environment["BROWSER_TEST_SEARCH_RESOURCES"] ?? Bundle.main.resourceURL?.path)
        _ = NSApplication.shared
        let name = "BrowserLiveSearchFixture-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let service = LocalSearchService(resources: URL(fileURLWithPath: resources, isDirectory: true), defaults: defaults)
        service.start()
        let browser = BrowserWindowController(searchService: service)
        defer {
            browser.close()
            service.stop()
            defaults.removePersistentDomain(forName: name)
        }
        let query = "swift programming language"
        submit(query, in: browser)
        let results = try await browser.observeForAgent()
        XCTAssertEqual(browser.addressField.stringValue, query)
        XCTAssertEqual(browser.currentURL.scheme, "browser")
        XCTAssertTrue(results.text.contains("Browser Search"))
        guard case .ready = service.snapshot.status else {
            return XCTFail("Bundled SearXNG did not start: \(service.snapshot.status)")
        }
        XCTAssertTrue(results.elements.contains { $0.url.flatMap(URL.init(string:))?.host == "www.swift.org"
            || $0.url.flatMap(URL.init(string:))?.host == "swift.org" })
        if let path = environment["BROWSER_TEST_SEARCH_PREVIEW"] {
            try capture(browser, at: path)
        }
        browser.openSearchSettings(nil)
        XCTAssertEqual(browser.window?.title, "Search Settings — Browser")
        if let path = environment["BROWSER_TEST_SEARCH_SETTINGS_PREVIEW"] {
            try capture(browser, at: path)
        }
        service.update(.init(selected: ["bing"], safeSearch: 2))
        guard case .starting = service.snapshot.status else { return XCTFail("Source changes should restart SearXNG") }
        let bingResults = try await service.search(query)
        XCTAssertFalse(bingResults.isEmpty)
        service.stop()
        do {
            _ = try await service.search(query)
            XCTFail("Stopped search unexpectedly submitted a query")
        } catch LocalSearchError.stopped {}
    }

    @MainActor
    private func capture(_ browser: BrowserWindowController, at path: String) throws {
        let content = try XCTUnwrap(browser.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: image)
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }

    @MainActor
    private func submit(_ input: String, in browser: BrowserWindowController) {
        let field = browser.addressField
        field.stringValue = input
        XCTAssertTrue(field.sendAction(field.action, to: field.target))
    }
}
