import AppKit
import Foundation
import WebKit
import XCTest
@testable import BrowserApp

final class CompatibilityTests: XCTestCase {
    @MainActor
    func testRedditRoutingAndNavigationBoundaries() {
        for address in ["https://reddit.com/", "https://www.reddit.com/r/swift/", "http://old.reddit.com/", "https://oauth.reddit.com/", "https://redd.it/abc"] {
            XCTAssertTrue(SiteSession.requiresCompatibility(URL(string: address)!), address)
        }
        for address in ["https://example.org/", "https://notreddit.com/", "https://reddit.com.example.org/", "https://example.org/?next=https://reddit.com", "https://reddit.com@example.org/", "https://user:password@reddit.com/", "ftp://reddit.com/", "file:///tmp/reddit.com"] {
            XCTAssertFalse(SiteSession.requiresCompatibility(URL(string: address)!), address)
        }
        for address in ["https://example.org/", "http://127.0.0.1:8765/login"] {
            XCTAssertTrue(SiteSession.allowsNavigation(URL(string: address)!), address)
        }
        for address in ["file:///tmp/private.html", "javascript:alert(1)", "data:text/html,hello", "https://user:password@example.org/", "ftp://example.org/", "https://example.org:65536/"] {
            XCTAssertFalse(SiteSession.allowsNavigation(URL(string: address)!), address)
        }
    }

    @MainActor
    func testModulesShadowDOMFormsCookiesAndNativeHistory() async throws {
        let server = try CompatibilityFixtureServer()
        defer { server.stop() }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let mounted = MountedSiteSession(configuration: configuration)
        defer { mounted.close() }
        let session = mounted.session
        var observedTitles: [String] = []
        session.onChange = { observedTitles.append($0.title) }

        session.load(server.url("/start"))
        try await waitFor("module-created login form") {
            guard session.url?.path == "/login" else { return false }
            return (try? await session.webView.evaluateJavaScript("document.querySelector('fixture-login')?.shadowRoot?.querySelector('form') !== null && window.fixtureReady === true") as? Bool) == true
        }
        try await waitFor("module title observation") { session.title == "Module ready" && observedTitles.contains("Module ready") }
        XCTAssertEqual(session.title, "Module ready")
        XCTAssertTrue(observedTitles.contains("Module ready"))
        XCTAssertTrue(session.webView.backForwardList.backList.isEmpty, "A server redirect must not add an intermediate Back entry")

        _ = try await session.webView.evaluateJavaScript(#"""
        const form = document.querySelector('fixture-login').shadowRoot.querySelector('form');
        form.elements.username.value = 'fixture user & café';
        form.elements.password.value = 'test-only-+&=';
        form.requestSubmit();
        true;
        """#)
        do {
            try await waitFor("POST and cookie redirect") { session.url?.path == "/done" && !session.isLoading }
        } catch {
            let snapshot = try? await session.webView.evaluateJavaScript("JSON.stringify({url:location.href,text:document.body.innerText,form:document.querySelector('fixture-login')?.shadowRoot?.innerHTML,valid:document.querySelector('fixture-login')?.shadowRoot?.querySelector('form')?.checkValidity()})")
            let stats = try? await URLSession.shared.data(from: server.url("/stats"))
            print("Fixture failure: URL=\(session.url?.absoluteString ?? "nil"), status=\(session.status), DOM=\(String(describing: snapshot)), requests=\(stats.map { String(decoding: $0.0, as: UTF8.self) } ?? "unavailable")")
            throw error
        }
        let credentialResult = try await session.webView.evaluateJavaScript("document.querySelector('#credentials').textContent") as? String
        let cookieResult = try await session.webView.evaluateJavaScript("document.querySelector('#cookie').textContent") as? String
        let scriptCanReadCookie = try await session.webView.evaluateJavaScript("document.cookie.includes('SiteSessionFixture')") as? Bool
        XCTAssertEqual(credentialResult, "credentials-ok")
        XCTAssertEqual(cookieResult, "cookie-ok")
        XCTAssertEqual(scriptCanReadCookie, false, "HttpOnly cookies must remain inaccessible to page script")

        _ = try await session.webView.evaluateJavaScript("document.querySelector('#next').click(); true")
        try await waitFor("second page") { session.url?.path == "/second" && !session.isLoading }
        XCTAssertTrue(session.webView.canGoBack)
        session.webView.goBack()
        try await waitFor("Back to completed form") { session.url?.path == "/done" && !session.isLoading }
        session.webView.goForward()
        try await waitFor("Forward without replaying the POST") { session.url?.path == "/second" && !session.isLoading }
        let (data, _) = try await URLSession.shared.data(from: server.url("/stats"))
        let stats = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(stats["submissions"] as? Int, 1)

        _ = try await session.webView.evaluateJavaScript("history.pushState({}, '', '/second#details'); document.title = 'SPA details'")
        try await waitFor("SPA URL and title observations") { session.url?.fragment == "details" && session.title == "SPA details" && observedTitles.contains("SPA details") }
        XCTAssertTrue(observedTitles.contains("SPA details"))
    }

    @MainActor
    func testBackDuringLoadingPreservesHomeAndRestoresTheWebsiteSession() async throws {
        let server = try CompatibilityFixtureServer()
        defer { server.stop() }
        _ = NSApplication.shared
        let controller = BrowserWindowController()
        defer { controller.close() }
        let home = URL(string: "browser:home")!
        controller.navigate(home)
        controller.navigate(server.url("/slow"), compatibility: true)
        try await waitFor("committed website with a pending script") {
            controller.compatibilitySession?.title == "Slow fixture" && controller.compatibilitySession?.isLoading == true
        }
        let originalSession = try XCTUnwrap(controller.compatibilitySession)

        controller.goBack(nil)
        XCTAssertEqual(controller.currentURL, home)
        XCTAssertEqual(controller.addressField.stringValue, home.absoluteString)
        XCTAssertNil(controller.compatibilitySession)

        controller.goForward(nil)
        XCTAssertTrue(controller.compatibilitySession === originalSession)
        XCTAssertEqual(controller.currentURL.path, "/slow")
        controller.goBack(nil)
        XCTAssertEqual(controller.currentURL, home, "A stopped website callback must not replace the Home history entry")
        XCTAssertNil(controller.compatibilitySession)
    }

    @MainActor
    func testBlankWebsitePageKeepsItsOwnAddressAcrossHome() async throws {
        let server = try CompatibilityFixtureServer()
        defer { server.stop() }
        _ = NSApplication.shared
        let controller = BrowserWindowController()
        defer { controller.close() }
        let blank = URL(string: "about:blank")!
        controller.navigate(server.url("/first"), compatibility: true)
        let session = try XCTUnwrap(controller.compatibilitySession)
        try await waitFor("initial website page") { session.url?.path == "/first" && !session.isLoading }

        session.webView.load(URLRequest(url: blank))
        try await waitFor("committed blank page") { controller.currentURL == blank }
        XCTAssertEqual(controller.addressField.stringValue, blank.absoluteString)

        controller.goHome(nil)
        controller.goBack(nil)
        XCTAssertEqual(controller.currentURL, blank)
        XCTAssertTrue(controller.compatibilitySession === session)
    }

    @MainActor
    func testNativeWebsiteHistorySurvivesCrossingTheCustomEngineBoundary() async throws {
        let server = try CompatibilityFixtureServer()
        defer { server.stop() }
        _ = NSApplication.shared
        let controller = BrowserWindowController()
        defer { controller.close() }
        let home = URL(string: "browser:home")!
        controller.navigate(home)
        controller.navigate(server.url("/remember"), compatibility: true)
        try await waitFor("website history start") { controller.currentURL.path == "/remember" && controller.compatibilitySession?.isLoading == false }
        let session = try XCTUnwrap(controller.compatibilitySession)
        session.load(server.url("/second"))
        try await waitFor("website history second page") { controller.currentURL.path == "/second" && !session.isLoading }
        _ = try await session.webView.evaluateJavaScript("window.fixtureMemory = 'retained' ; true")

        controller.goBack(nil)
        try await waitFor("native website Back") { controller.currentURL.path == "/remember" && !session.isLoading }
        controller.goBack(nil)
        XCTAssertEqual(controller.currentURL, home)
        XCTAssertNil(controller.compatibilitySession)

        controller.goForward(nil)
        XCTAssertTrue(controller.compatibilitySession === session)
        XCTAssertEqual(controller.currentURL.path, "/remember")
        controller.goForward(nil)
        try await waitFor("native website Forward") { controller.currentURL.path == "/second" && !session.isLoading }

        controller.goHome(nil)
        XCTAssertEqual(controller.currentURL, home)
        controller.goBack(nil)
        XCTAssertTrue(controller.compatibilitySession === session)
        XCTAssertEqual(controller.currentURL.path, "/second")
        let retained = try await session.webView.evaluateJavaScript("window.fixtureMemory") as? String
        XCTAssertEqual(retained, "retained", "Restoring a website session must not replay it as a new URL request")

        controller.navigate(controller.currentURL)
        XCTAssertTrue(controller.compatibilitySession === session, "Entering the same address must retain native website history")
        try await waitFor("same-address website reload") { controller.currentURL.path == "/second" && !session.isLoading }
        XCTAssertTrue(session.webView.canGoBack)

        session.load(server.url("/branch"))
        try await waitFor("new website branch") { controller.currentURL.path == "/branch" && !session.isLoading }
        XCTAssertFalse(session.webView.canGoForward)
        controller.goForward(nil)
        XCTAssertEqual(controller.currentURL.path, "/branch", "A new website navigation must discard the old app-level Forward boundary")
        XCTAssertTrue(controller.compatibilitySession === session)
    }

    @MainActor
    func testPopupRetainsOpenerAndSessionCookies() async throws {
        let server = try CompatibilityFixtureServer()
        defer { server.stop() }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let parent = MountedSiteSession(configuration: configuration)
        var children: [MountedSiteSession] = []
        defer { children.forEach { $0.close() }; parent.close() }
        var childClosed = false
        parent.session.createPopup = { configuration, _ in
            let child = MountedSiteSession(configuration: configuration)
            child.session.requestClose = { childClosed = true }
            children.append(child)
            return child.session.webView
        }
        parent.session.load(server.url("/remember"))
        try await waitFor("parent cookie page") { parent.session.url?.path == "/remember" && !parent.session.isLoading }
        // Production requires a user gesture. This test permits an automated popup
        // so it can exercise the real WebKit child/opener relationship without UI input.
        parent.session.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        _ = try await parent.session.webView.evaluateJavaScript("window.open('/popup', 'fixture-popup'); true")
        try await waitFor("popup opener callback") {
            (try? await parent.session.webView.evaluateJavaScript("window.fixturePopupResult") as? String) == "cookie-ok"
        }
        try await waitFor("popup close callback") { childClosed }
        XCTAssertEqual(children.count, 1)
        XCTAssertEqual(parent.session.url?.path, "/remember", "Opening a child must not navigate the parent")
    }

    @MainActor
    func testPersistentSiteDataSurvivesCreatingANewSession() async throws {
        guard #available(macOS 14.0, *) else { throw XCTSkip("An isolated named persistent WebKit store requires macOS 14") }
        let server = try CompatibilityFixtureServer()
        defer { server.stop() }
        let identifier = UUID()
        var first: MountedSiteSession?
        var second: MountedSiteSession?
        weak var firstView: WKWebView?
        weak var secondView: WKWebView?
        var phase = "creating first session"
        do {
            first = persistentFixtureSession(identifier)
            firstView = first?.session.webView
            first!.session.load(server.url("/remember"))
            try await waitFor("persistent storage creation") {
                guard let first, first.session.url?.path == "/remember", !first.session.isLoading else { return false }
                return (try? await first.session.webView.evaluateJavaScript("localStorage.getItem('SiteSessionFixture')") as? String) == "stored-fixture"
            }
            first?.close(); first = nil
            try await waitFor("first persistent view release") { firstView == nil }

            phase = "creating second session"
            second = persistentFixtureSession(identifier)
            secondView = second?.session.webView
            second!.session.load(server.url("/cookie-check"))
            try await waitFor("new session cookie request") {
                guard let second, second.session.url?.path == "/cookie-check", !second.session.isLoading else { return false }
                return (try? await second.session.webView.evaluateJavaScript("document.querySelector('#cookie') !== null") as? Bool) == true
            }
            phase = "reading persisted cookie and storage"
            let cookieResult = try await second!.session.webView.evaluateJavaScript("document.querySelector('#cookie').textContent") as? String
            let storageResult = try await second!.session.webView.evaluateJavaScript("localStorage.getItem('SiteSessionFixture')") as? String
            XCTAssertEqual(cookieResult, "cookie-ok")
            XCTAssertEqual(storageResult, "stored-fixture")
            second?.close(); second = nil
            try await waitFor("second persistent view release") { secondView == nil }
            phase = "removing isolated store"
            try await removeFixtureDataStore(identifier)
        } catch {
            print("Persistent fixture failure during \(phase): \(error)")
            first?.close(); first = nil
            second?.close(); second = nil
            try? await removeFixtureDataStore(identifier)
            throw error
        }
    }
}

@MainActor
private final class MountedSiteSession {
    let session: SiteSession
    private let window: NSWindow

    init(configuration: WKWebViewConfiguration) {
        _ = NSApplication.shared
        session = SiteSession(configuration: configuration)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = session.webView
    }

    func close() {
        session.webView.stopLoading()
        session.onChange = nil
        session.createPopup = nil
        session.requestClose = nil
        window.contentView = nil
        window.close()
    }
}

@MainActor
private func waitFor(_ description: String, timeout: TimeInterval = 15,
                     condition: () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try await condition() { return }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    XCTFail("Timed out waiting for \(description)")
    throw NSError(domain: "CompatibilityTests", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
}

@available(macOS 14.0, *)
@MainActor
private func removeFixtureDataStore(_ identifier: UUID) async throws {
    let deadline = Date().addingTimeInterval(5)
    while true {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                WKWebsiteDataStore.remove(forIdentifier: identifier) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
            return
        } catch {
            // WebKit releases its network-process datastore after the last view dies.
            // Poll this specific store while that asynchronous release is pending.
            let error = error as NSError
            guard error.domain == "WKWebSiteDataStore", error.code == 1,
                  error.localizedDescription.contains("in use"), Date() < deadline else { throw error }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

@available(macOS 14.0, *)
@MainActor
private func persistentFixtureSession(_ identifier: UUID) -> MountedSiteSession {
    autoreleasepool {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: identifier)
        XCTAssertTrue(configuration.websiteDataStore.isPersistent)
        return MountedSiteSession(configuration: configuration)
    }
}

private final class CompatibilityFixtureServer {
    private let process: Process
    private let output: Pipe
    private let errors: Pipe
    private let port: Int

    init() throws {
        process = Process()
        output = Pipe(); errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", "-c", Self.source]
        process.standardOutput = output; process.standardError = errors
        try process.run()
        var line = Data()
        while line.last != 10, line.count < 128 {
            guard let next = try output.fileHandleForReading.read(upToCount: 1), !next.isEmpty else { break }
            line.append(next)
        }
        guard let number = Int(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            process.terminate()
            throw NSError(domain: "CompatibilityFixtureServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Local HTTP fixture could not start"])
        }
        port = number
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
    func stop() { if process.isRunning { process.terminate() } }
    deinit { stop() }

    private static let source = #"""
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    from urllib.parse import parse_qs, urlsplit
    import html, json, time

    submissions = 0
    requests = []
    form_values = None
    expected_values = {'username': ['fixture user & caf\u00e9'], 'password': ['test-only-+&=']}
    cookie = 'SiteSessionFixture=fake-session; Path=/; Max-Age=3600; HttpOnly; SameSite=Lax'

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def reply(self, body, kind='text/html; charset=utf-8', status=200, headers=()):
            data = body.encode('utf-8')
            self.send_response(status)
            self.send_header('Content-Type', kind)
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'no-store')
            for key, value in headers: self.send_header(key, value)
            self.end_headers()
            self.wfile.write(data)
        def cookie_result(self):
            return 'cookie-ok' if 'SiteSessionFixture=fake-session' in self.headers.get('Cookie', '') else 'cookie-missing'
        def do_GET(self):
            path = urlsplit(self.path).path
            requests.append(['GET', self.path])
            if path == '/start':
                self.reply('', status=302, headers=[('Location', '/login')])
            elif path == '/login':
                self.reply('<!doctype html><title>Loading fixture</title><body><script type="module" src="/fixture-module.js"></script></body>')
            elif path == '/fixture-helper.js':
                self.reply("export const readyTitle = 'Module ready';", 'text/javascript')
            elif path == '/fixture-module.js':
                self.reply('''import { readyTitle } from '/fixture-helper.js';
    class FixtureLogin extends HTMLElement {
      connectedCallback() {
        this.attachShadow({mode: 'open'}).innerHTML = `<form method="POST" action="/submit" accept-charset="UTF-8"><label>Fixture user<input name="username" required></label><label>Fixture password<input type="password" name="password" required></label><button>Sign in to fixture</button></form>`;
      }
    }
    customElements.define('fixture-login', FixtureLogin);
    document.body.append(document.createElement('fixture-login'));
    document.title = readyTitle;
    window.fixtureReady = true;
    ''', 'text/javascript')
            elif path == '/done':
                self.reply('<!doctype html><title>Signed in fixture</title><body><p id="credentials">credentials-ok</p><p id="cookie">' + self.cookie_result() + '</p><a id="next" href="/second">Next page</a></body>')
            elif path == '/second':
                self.reply('<!doctype html><title>Second fixture page</title><body>Second page</body>')
            elif path == '/branch':
                self.reply('<!doctype html><title>Branch fixture page</title><body>New branch</body>')
            elif path == '/slow':
                self.reply('<!doctype html><title>Slow fixture</title><script src="/wait.js"></script><body>Slow page</body>')
            elif path == '/wait.js':
                time.sleep(6)
                self.reply('window.fixtureSlowLoaded = true;', 'text/javascript')
            elif path == '/stats':
                self.reply(json.dumps({'submissions': submissions, 'requests': requests, 'form_values': form_values, 'expected_values': expected_values}), 'application/json')
            elif path == '/remember':
                self.reply('<!doctype html><title>Remember fixture</title><body><script>localStorage.setItem("SiteSessionFixture", "stored-fixture"); window.fixturePopupResult = "";</script></body>', headers=[('Set-Cookie', cookie)])
            elif path == '/cookie-check':
                self.reply('<!doctype html><title>Cookie fixture</title><body><p id="cookie">' + self.cookie_result() + '</p></body>')
            elif path == '/popup':
                self.reply('<!doctype html><title>Popup fixture</title><body><script>window.opener.fixturePopupResult = ' + json.dumps(self.cookie_result()) + '; window.close();</script></body>')
            else:
                self.reply('Not found', status=404)
        def do_POST(self):
            global submissions, form_values
            requests.append(['POST', self.path])
            if urlsplit(self.path).path != '/submit':
                self.reply('Not found', status=404)
                return
            values = parse_qs(self.rfile.read(int(self.headers.get('Content-Length', '0'))).decode('utf-8'))
            form_values = values
            if values != expected_values:
                self.reply('Fixture values were not encoded correctly', status=400)
                return
            submissions += 1
            self.reply('', status=303, headers=[('Location', '/done'), ('Set-Cookie', cookie)])

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    print(server.server_port, flush=True)
    server.serve_forever()
    """#
}
