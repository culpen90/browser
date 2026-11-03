import AppKit
import BrowserCore

@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSMenuItemValidation {
    let addressField = NSTextField()
    let canvas = PageCanvas(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let progress = NSProgressIndicator()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()
    private let loader = PageLoader()
    private var history = NavigationHistory()
    private var navigationTask: Task<Void, Never>?
    private var generation = 0
    private(set) var currentURL = URL(string: "browser:home")!
    private var isLoading = false
    private var currentStatus = "Ready"
    private var visibleDocument: HTMLDocument?
    private var displayedURL: URL?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Browser"
        window.minSize = NSSize(width: 520, height: 360)
        window.setFrameAutosaveName("BrowserWindow")
        super.init(window: window)
        window.delegate = self
        buildInterface()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func button(_ existing: NSButton? = nil, symbol: String, label: String, action: Selector) -> NSButton {
        let button = existing ?? NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.target = self; button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 34).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let toolbar = NSView()
        toolbar.wantsLayer = true
        let controls = NSStackView(views: [
            button(backButton, symbol: "chevron.left", label: "Back (⌘[)", action: #selector(goBack(_:))),
            button(forwardButton, symbol: "chevron.right", label: "Forward (⌘])", action: #selector(goForward(_:))),
            button(reloadButton, symbol: "arrow.clockwise", label: "Reload (⌘R)", action: #selector(reload(_:))),
            button(symbol: "house", label: "Home (⇧⌘H)", action: #selector(goHome(_:)))
        ])
        controls.spacing = 5
        addressField.placeholderString = "Enter a web address"
        addressField.font = .systemFont(ofSize: 14)
        addressField.bezelStyle = .roundedBezel
        addressField.focusRingType = .exterior
        addressField.target = self; addressField.action = #selector(submitAddress(_:))
        addressField.delegate = self
        addressField.setAccessibilityLabel("Address")
        progress.style = .spinning; progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        let header = NSStackView(views: [controls, addressField, progress])
        header.spacing = 12; header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(header)

        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .white
        canvas.autoresizingMask = [.width]
        canvas.onNavigate = { [weak self] url in self?.navigate(url) }
        canvas.onHover = { [weak self] url in
            guard let self else { return }
            self.statusLabel.stringValue = url ?? self.currentStatus
        }

        let footer = NSView()
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(statusLabel)
        for view in [toolbar, scrollView, footer] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor), toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor), toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor), toolbar.heightAnchor.constraint(equalToConstant: 54),
            header.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12), header.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -14), header.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            addressField.heightAnchor.constraint(equalToConstant: 32), addressField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            progress.widthAnchor.constraint(equalToConstant: 16), progress.heightAnchor.constraint(equalToConstant: 16),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor), scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor), scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor), scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.heightAnchor.constraint(equalToConstant: 26), footer.leadingAnchor.constraint(equalTo: content.leadingAnchor), footer.trailingAnchor.constraint(equalTo: content.trailingAnchor), footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 14), statusLabel.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -14), statusLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])
    }

    func start(at url: URL? = nil) { showWindow(nil); navigate(url ?? currentURL) }
    func windowDidResize(_ notification: Notification) { canvas.relayout() }
    func windowWillClose(_ notification: Notification) { navigationTask?.cancel() }
    @objc func focusAddress(_ sender: Any?) { window?.makeFirstResponder(addressField); addressField.selectText(nil) }
    @objc private func submitAddress(_ sender: Any?) {
        guard let url = Address.resolve(addressField.stringValue) else {
            setStatus("Enter an HTTP, HTTPS, or local file address.")
            NSSound.beep(); return
        }
        window?.makeFirstResponder(canvas)
        navigate(url)
    }
    @objc func goBack(_ sender: Any?) { if let url = history.back() { navigate(url, record: false) } }
    @objc func goForward(_ sender: Any?) { if let url = history.forward() { navigate(url, record: false) } }
    @objc func goHome(_ sender: Any?) { navigate(URL(string: "browser:home")!) }
    @objc func reload(_ sender: Any?) {
        if isLoading { stopLoading(sender) }
        else { navigate(currentURL, record: false) }
    }
    @objc func stopLoading(_ sender: Any?) {
        generation += 1; navigationTask?.cancel(); navigationTask = nil
        setLoading(false); setStatus("Stopped")
    }
    @objc func openFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose an HTML or text document"
        panel.beginSheetModal(for: window!) { [weak self] response in
            if response == .OK, let url = panel.url { self?.navigate(url) }
        }
    }
    @objc func copyPageText(_ sender: Any?) { canvas.copyPageText(sender) }

    func navigate(_ url: URL, record: Bool = true) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) || url.absoluteString == "browser:home" else {
            setStatus("This address type is not supported."); NSSound.beep(); return
        }
        generation += 1
        let requestID = generation
        navigationTask?.cancel()
        currentURL = url
        if record { history.push(url) }
        addressField.stringValue = url.absoluteString
        updateButtons()
        if url.absoluteString == "browser:home" {
            setLoading(false)
            display(HTMLParser().parse(Self.homeHTML), css: "", baseURL: url, images: [:])
            canvas.scrollToAnchor(nil); setStatus("Ready"); return
        }
        if record, displayedURL?.withoutFragment == url.withoutFragment, displayedURL?.fragment != url.fragment, visibleDocument != nil {
            displayedURL = url
            setLoading(false); canvas.scrollToAnchor(url.fragment); setStatus("Ready"); return
        }
        setLoading(true); setStatus("Loading \(url.host ?? url.lastPathComponent)…")
        navigationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await self.loader.load(url)
                try Task.checkCancellation()
                guard self.generation == requestID else { return }
                let source = page.isPlainText ? "<html><head><title>\(Self.escape(page.url.lastPathComponent))</title></head><body><pre>\(Self.escape(page.html))</pre></body></html>" : page.html
                let document = HTMLParser().parse(source)
                let proposedBase = document.baseURL(relativeTo: page.url)
                let base = Self.resourceAllowed(proposedBase, from: page.url) ? proposedBase : page.url
                self.currentURL = page.url
                self.history.replaceCurrent(page.url)
                self.addressField.stringValue = page.url.absoluteString
                self.display(document, css: document.embeddedStyles, baseURL: base, images: [:])
                self.canvas.scrollToAnchor(page.url.fragment)
                let resourceLoader = self.loader
                var styleParts: [Int: String] = [:]
                var styleRequests: [(Int, URL)] = []
                // Preserve the document's style/link source order in the cascade.
                let styleNodes = document.root.styleNodes.filter { node in
                    node.tagName == "style" || node.attributes["rel"]?.lowercased().split(whereSeparator: \.isWhitespace).contains("stylesheet") == true
                }
                for (index, node) in styleNodes.prefix(16).enumerated() {
                    try Task.checkCancellation()
                    if node.tagName == "style" { styleParts[index] = node.textContent }
                    else if let href = node.attributes["href"], let resource = URL(string: href, relativeTo: base)?.absoluteURL,
                            Self.resourceAllowed(resource, from: page.url) {
                        styleRequests.append((index, resource))
                    }
                }
                for start in stride(from: 0, to: styleRequests.count, by: 4) {
                    let batch = styleRequests[start..<min(start + 4, styleRequests.count)]
                    await withTaskGroup(of: (Int, String?).self) { group in
                        for (index, resource) in batch {
                            group.addTask {
                                let data = try? await resourceLoader.resource(resource, maxBytes: 1_000_000)
                                return (index, data.flatMap { String(data: $0, encoding: .utf8) })
                            }
                        }
                        for await (index, text) in group { styleParts[index] = text }
                    }
                    try Task.checkCancellation()
                }
                let css = styleParts.keys.sorted().compactMap { styleParts[$0] }.joined(separator: "\n")
                try Task.checkCancellation()
                guard self.generation == requestID else { return }
                let positionBeforeStyles = self.scrollView.contentView.bounds.origin
                self.display(document, css: css, baseURL: base, images: [:])
                if positionBeforeStyles.y == 0 { self.canvas.scrollToAnchor(page.url.fragment) }
                else { self.canvas.scroll(positionBeforeStyles) }
                var images: [URL: NSImage] = [:]
                let imageURLs = document.root.descendants(tag: "img").compactMap { node -> URL? in
                    guard let src = node.attributes["src"] else { return nil }
                    return URL(string: src, relativeTo: base)?.absoluteURL
                }
                let resources = Array(Set(imageURLs)).filter { Self.resourceAllowed($0, from: page.url) }.prefix(24)
                let orderedResources = Array(resources)
                for start in stride(from: 0, to: orderedResources.count, by: 4) {
                    try Task.checkCancellation()
                    let batch = orderedResources[start..<min(start + 4, orderedResources.count)]
                    let loaded = await withTaskGroup(of: (URL, Data?).self, returning: [(URL, Data?)].self) { group in
                        for resource in batch {
                            group.addTask { (resource, try? await resourceLoader.resource(resource)) }
                        }
                        var values: [(URL, Data?)] = []
                        for await value in group { values.append(value) }
                        return values
                    }
                    for (resource, data) in loaded {
                        if let data, let image = NSImage(data: data), image.size.width > 0, image.size.width <= 8192,
                           image.size.height > 0, image.size.height <= 8192 { images[resource] = image }
                    }
                }
                try Task.checkCancellation()
                guard self.generation == requestID else { return }
                if !images.isEmpty {
                    let positionBeforeImages = self.scrollView.contentView.bounds.origin
                    self.display(document, css: css, baseURL: base, images: images)
                    if positionBeforeImages.y == 0 { self.canvas.scrollToAnchor(page.url.fragment) }
                    else { self.canvas.scroll(positionBeforeImages) }
                }
                let status = page.statusCode.map { $0 >= 400 ? "HTTP \($0)" : "Ready" } ?? "Ready"
                self.setStatus(status); self.setLoading(false)
            } catch {
                guard self.generation == requestID, !Task.isCancelled else { return }
                self.display(HTMLParser().parse(Self.errorHTML(url: url, message: error.localizedDescription)), css: "", baseURL: url, images: [:])
                self.canvas.scrollToAnchor(nil)
                self.setStatus("Couldn’t load page"); self.setLoading(false)
            }
        }
    }

    static func resourceAllowed(_ resource: URL, from page: URL) -> Bool {
        if ["http", "https"].contains(resource.scheme?.lowercased() ?? "") { return true }
        return page.isFileURL && resource.isFileURL
    }
    private func display(_ document: HTMLDocument, css: String, baseURL: URL, images: [URL: NSImage]) {
        visibleDocument = document; displayedURL = currentURL
        canvas.show(document: document, css: css.isEmpty ? document.embeddedStyles : css, baseURL: baseURL, images: images)
        window?.title = document.title.isEmpty ? "Browser" : "\(document.title) — Browser"
    }
    private func setStatus(_ value: String) { currentStatus = value; statusLabel.stringValue = value }
    private func setLoading(_ loading: Bool) {
        isLoading = loading
        if loading { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        reloadButton.image = NSImage(systemSymbolName: loading ? "xmark" : "arrow.clockwise", accessibilityDescription: loading ? "Stop" : "Reload")
        reloadButton.toolTip = loading ? "Stop (Esc)" : "Reload (⌘R)"
        reloadButton.setAccessibilityLabel(loading ? "Stop" : "Reload")
        updateButtons()
    }
    private func updateButtons() { backButton.isEnabled = history.canGoBack; forwardButton.isEnabled = history.canGoForward }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(goBack(_:)) { return history.canGoBack }
        if menuItem.action == #selector(goForward(_:)) { return history.canGoForward }
        if menuItem.action == #selector(stopLoading(_:)) { return isLoading }
        return true
    }
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    static let homeHTML = """
    <!doctype html><html><head><title>Home</title><style>
    body { background-color: #f7f8fa; color: #26354a; padding: 28px; }
    h1 { font-size: 44px; margin-top: 56px; margin-bottom: 12px; }
    p { font-size: 18px; margin-bottom: 22px; }
    h2 { font-size: 13px; color: #65758b; margin-top: 48px; }
    a { color: #2563eb; }
    li { margin-bottom: 18px; }
    </style></head><body>
    <h1>A place to begin.</h1>
    <p>Enter an address above and explore the web.</p>
    <h2>EXPLORE</h2>
    <ul><li><a href="https://example.com">Example Domain</a></li>
    <li><a href="https://info.cern.ch/hypertext/WWW/TheProject.html">The World Wide Web project</a></li>
    <li><a href="https://www.rfc-editor.org/rfc/rfc9110.txt">Read an internet standard</a></li></ul>
    <h2>MAKE YOURSELF AT HOME</h2>
    <p>⌘L to enter an address. ⌘O to open a local page.</p>
    </body></html>
    """
    private static func errorHTML(url: URL, message: String) -> String {
        """
        <html><head><title>Page unavailable</title><style>body { padding: 28px; color: #26354a; } h1 { font-size: 32px; margin-top: 60px; } p { font-size: 17px; }</style></head><body>
        <h1>This page couldn’t be loaded.</h1><p>\(escape(message))</p><p>\(escape(url.absoluteString))</p><p>Check the address or your connection, then press ⌘R to try again.</p></body></html>
        """
    }
}

private extension URL {
    var withoutFragment: String { var parts = URLComponents(url: self, resolvingAgainstBaseURL: true); parts?.fragment = nil; return parts?.string ?? absoluteString }
}

private extension HTMLNode {
    var styleNodes: [HTMLNode] {
        var nodes: [HTMLNode] = []
        if tagName == "style" || tagName == "link" { nodes.append(self) }
        for child in children { nodes += child.styleNodes }
        return nodes
    }
}
