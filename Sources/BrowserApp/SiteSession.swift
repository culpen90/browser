import AppKit
import WebKit

/// A full website session. The independent renderer remains the default for other pages.
@MainActor
final class SiteSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    var onChange: ((SiteSession) -> Void)?
    var onNewHistoryEntry: (() -> Void)?
    var createPopup: ((WKWebViewConfiguration, URL?) -> WKWebView?)?
    var requestClose: (() -> Void)?
    private var observations: [NSKeyValueObservation] = []
    private var failure: String?
    private var stopped = false
    private var knownHistoryItems = Set<ObjectIdentifier>()
    private var hasHistoryItem = false
    private(set) var navigationRevision = 0

    var url: URL? { webView.url }
    var title: String { webView.title ?? "" }
    var isLoading: Bool { webView.isLoading && !stopped }
    var status: String {
        if let failure { return failure }
        if stopped { return "Stopped" }
        return isLoading ? "Loading \(url?.host ?? "website")…" : "Ready"
    }

    init(configuration: WKWebViewConfiguration? = nil) {
        let suppliedConfiguration = configuration
        let configuration = configuration ?? WKWebViewConfiguration()
        // Keep Reddit's own cookies/storage between launches. Never export them to the
        // independent engine, expose a native bridge to web content, or replace the platform user agent.
        if suppliedConfiguration == nil { configuration.websiteDataStore = .default() }
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.changed() } },
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.changed() } },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.changed() } },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.changed() } },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.changed() } }
        ]
    }

    static func allowsNavigation(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              parts.user == nil, parts.password == nil else { return false }
        return parts.port.map { (1...65535).contains($0) } ?? true
    }

    static func requiresCompatibility(_ url: URL) -> Bool {
        guard allowsNavigation(url), let host = url.host?.lowercased() else { return false }
        return host == "reddit.com" || host.hasSuffix(".reddit.com") || host == "redd.it" || host.hasSuffix(".redd.it")
    }

    func load(_ url: URL) {
        guard Self.allowsNavigation(url) else { return }
        failure = nil; stopped = false
        webView.load(URLRequest(url: url))
    }

    func reload() { failure = nil; stopped = false; webView.reload() }
    func stop() { stopped = true; webView.stopLoading(); changed() }
    func setVisible(_ visible: Bool) { webView.setAllMediaPlaybackSuspended(!visible, completionHandler: nil) }
    private func changed() {
        let list = webView.backForwardList
        if let item = list.currentItem {
            // A new native item also branches any forward pages in the app history.
            // Existing items indicate Back/Forward traversal, which must retain them.
            if hasHistoryItem && !knownHistoryItems.contains(ObjectIdentifier(item)) { onNewHistoryEntry?() }
            hasHistoryItem = true
            knownHistoryItems = Set((list.backList + [item] + list.forwardList).map(ObjectIdentifier.init))
        }
        onChange?(self)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // about:blank is needed for popup creation. Remote pages cannot navigate to
        // local files, data URLs, custom app schemes or credential-bearing addresses.
        guard let url = action.request.url,
              Self.allowsNavigation(url) || url.absoluteString == "about:blank" else {
            decisionHandler(.cancel)
            if action.targetFrame?.isMainFrame != false { failure = "This address type is not supported."; changed() }
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationRevision += 1
        failure = nil; stopped = false; changed()
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { changed() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { changed() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        failure = error.localizedDescription; changed()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        navigationRevision += 1
        failure = "The website stopped responding. Press Reload to reopen it."; changed()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.request.url.map({ Self.allowsNavigation($0) || $0.absoluteString == "about:blank" }) ?? true else { return nil }
        // Return the actual child view: moving its URL into the parent loses window.opener
        // and breaks popup-based authentication.
        return createPopup?(configuration, navigationAction.request.url)
    }
    func webViewDidClose(_ webView: WKWebView) { requestClose?() }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        present(message, frame: frame, buttons: ["OK"]) { _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        present(message, frame: frame, buttons: ["OK", "Cancel"]) { completionHandler($0 == .alertFirstButtonReturn) }
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard let window = webView.window else { completionHandler(nil); return }
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "Website"
        alert.informativeText = String(prompt.prefix(4000))
        alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { response in completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil) }
    }
    private func present(_ message: String, frame: WKFrameInfo, buttons: [String], completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard let window = webView.window else { completion(.alertSecondButtonReturn); return }
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "Website"
        alert.informativeText = String(message.prefix(4000))
        for title in buttons { alert.addButton(withTitle: title) }
        alert.beginSheetModal(for: window, completionHandler: completion)
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        guard let window = webView.window else { completionHandler(nil); return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.message = "Choose files for \(frame.request.url?.host ?? "this website")"
        panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
    }
}
