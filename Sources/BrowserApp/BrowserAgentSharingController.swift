import AppKit
import CoreImage
import Network

@MainActor
final class BrowserAgentSharingController: NSWindowController, NSWindowDelegate {
    static let shared = BrowserAgentSharingController()

    private let server = BrowserAgentServer.shared
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let modelLabel = NSTextField(labelWithString: "")
    private let qrView = NSImageView()
    private let pairingLink = NSTextField(wrappingLabelWithString: "")
    private let addressMenu = NSPopUpButton()
    private let shareButton = NSButton(title: "Start Sharing", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy Pairing Link", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let internetAddress = NSTextField(string: UserDefaults.standard.string(forKey: "BrowserAgentInternetAddress") ?? "")
    private let internetPort = NSTextField(string: UserDefaults.standard.string(forKey: "BrowserAgentInternetPort") ?? String(BrowserAgentServer.sharingPort))
    private let routerButton = NSButton(title: "Find Internet Address", target: nil, action: nil)
    private let internetStatus = NSTextField(wrappingLabelWithString: "")
    private let router = BrowserAgentRouterMapping()
    private var mappingTask: Task<Void, Never>?
    private var mappingIdentity = UUID()
    private var externalEndpoint: (host: String, port: UInt16)?
    private var automaticallyMappedEndpoint = false
    private var selectedModelURL = BrowserAgentModel.defaultURL
    private var pairingURIs: [URL] = []
    private var displayedURI: URL?

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 820),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Share Model"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildInterface()
        server.onChange = { [weak self] in self?.refresh() }
        router.onExpiration = { [weak self] in
            guard let self, self.automaticallyMappedEndpoint else { return }
            self.externalEndpoint = nil
            self.automaticallyMappedEndpoint = false
            self.internetStatus.stringValue = "Your router’s mapping expired. Choose Find Internet Address to try again."
            self.refresh()
        }
        if !internetAddress.stringValue.isEmpty { useInternetAddress(nil) }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(from parent: NSWindow, modelURL: URL) {
        guard let window else { return }
        if let existingParent = window.sheetParent {
            existingParent.makeKeyAndOrderFront(nil)
            window.makeKeyAndOrderFront(nil)
            return
        }
        selectedModelURL = modelURL
        refresh()
        parent.beginSheet(window)
    }

    /// Choose a return route to the model; never give a remote phone a private LAN-only address.
    func pairingURI(forPeerHost host: String) -> URL? {
        let local = BrowserAgentRouterMapping.isPrivateIPv4(host) || host.hasSuffix(".local") ||
            host.hasSuffix(".local.") || host == "127.0.0.1" || host == "::1"
        if local {
            let prefix = host.split(separator: ".").dropLast().joined(separator: ".") + "."
            return server.pairingURIs.first(where: { Self.host($0)?.hasPrefix(prefix) == true }) ?? server.pairingURI
        }
        if let externalEndpoint { return server.pairingURI(host: externalEndpoint.host, port: externalEndpoint.port) }
        return server.pairingURIs.first(where: { uri in
            guard let host = Self.host(uri) else { return false }
            return host.hasPrefix("2") && host.contains(":") || host.hasPrefix("3") && host.contains(":")
        })
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss(nil)
        return false
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString: "Use this Mac’s model on another device")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let instructions = NSTextField(wrappingLabelWithString:
            "Pair once with the QR code or pairing link, then choose this Mac in Devices on your phone or another computer.")
        instructions.font = .systemFont(ofSize: 13)
        modelLabel.font = .systemFont(ofSize: 11)
        modelLabel.textColor = .secondaryLabelColor
        modelLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.setAccessibilityLabel("Model sharing status")

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        let status = NSStackView(views: [progress, statusLabel])
        status.alignment = .centerY
        status.spacing = 8

        qrView.wantsLayer = true
        qrView.layer?.backgroundColor = NSColor.white.cgColor
        qrView.layer?.cornerRadius = 8
        qrView.layer?.magnificationFilter = .nearest
        qrView.layer?.minificationFilter = .nearest
        qrView.imageScaling = .scaleNone
        qrView.setAccessibilityLabel("Device pairing QR code")
        qrView.setAccessibilityHelp("Scan with the phone camera to connect Browser to this Mac.")

        addressMenu.controlSize = .small
        addressMenu.target = self
        addressMenu.action = #selector(selectAddress(_:))
        addressMenu.setAccessibilityLabel("Mac network address")
        addressMenu.toolTip = "Choose the address reachable from your phone"
        pairingLink.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pairingLink.isSelectable = true
        pairingLink.maximumNumberOfLines = 4
        pairingLink.setAccessibilityLabel("Phone pairing link")

        copyButton.target = self
        copyButton.action = #selector(copyPairingLink(_:))
        shareButton.target = self
        shareButton.action = #selector(toggleSharing(_:))
        let actions = NSStackView(views: [shareButton, copyButton])
        actions.spacing = 8

        let internetTitle = NSTextField(labelWithString: "Connect over the internet")
        internetTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        internetAddress.placeholderString = "Public IPv4, IPv6, or your own hostname"
        internetAddress.setAccessibilityLabel("Internet address")
        internetPort.setAccessibilityLabel("Internet TCP port")
        let useAddress = NSButton(title: "Use Address", target: self, action: #selector(useInternetAddress(_:)))
        let addressRow = NSStackView(views: [internetAddress, internetPort, useAddress])
        addressRow.spacing = 8
        internetAddress.setContentHuggingPriority(.defaultLow, for: .horizontal)
        internetPort.widthAnchor.constraint(equalToConstant: 65).isActive = true
        routerButton.target = self
        routerButton.action = #selector(findInternetAddress(_:))
        routerButton.toolTip = "Ask your own router to open a direct connection. No external service is contacted."
        internetStatus.font = .systemFont(ofSize: 11)
        internetStatus.textColor = .secondaryLabelColor
        internetStatus.stringValue = "Nearby devices connect directly on Wi-Fi. For internet access, find your router’s address or enter a reachable public address. Allow TCP port \(BrowserAgentServer.sharingPort) on the receiving Mac."

        let reset = NSButton(title: "Reset Pairing", target: self, action: #selector(resetPairing(_:)))
        reset.toolTip = "Revoke all pairing links. Devices must pair again."

        let explanation = NSTextField(wrappingLabelWithString:
            "Connections are direct and encrypted. Sharing ends when you stop it or quit Browser; paired devices are remembered. Keep the pairing link private. Reset Pairing revokes all saved links.")
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor
        let done = NSButton(title: "Done", target: self, action: #selector(dismiss(_:)))
        done.keyEquivalent = "\r"
        let footer = NSStackView(views: [reset, NSView(), done])
        footer.distribution = .fill
        let layout = NSStackView(views: [title, instructions, modelLabel, status, qrView, addressMenu,
                                       pairingLink, actions, internetTitle, addressRow, routerButton,
                                       internetStatus, explanation, NSView(), footer])
        layout.orientation = .vertical
        layout.alignment = .leading
        layout.distribution = .fill
        layout.spacing = 8
        layout.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            layout.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            layout.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            layout.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            instructions.widthAnchor.constraint(equalTo: layout.widthAnchor),
            modelLabel.widthAnchor.constraint(equalTo: layout.widthAnchor),
            status.widthAnchor.constraint(equalTo: layout.widthAnchor),
            progress.widthAnchor.constraint(equalToConstant: 16),
            progress.heightAnchor.constraint(equalToConstant: 16),
            qrView.widthAnchor.constraint(equalToConstant: 220),
            qrView.heightAnchor.constraint(equalToConstant: 220),
            qrView.centerXAnchor.constraint(equalTo: layout.centerXAnchor),
            pairingLink.widthAnchor.constraint(equalTo: layout.widthAnchor),
            addressRow.widthAnchor.constraint(equalTo: layout.widthAnchor),
            internetStatus.widthAnchor.constraint(equalTo: layout.widthAnchor),
            explanation.widthAnchor.constraint(equalTo: layout.widthAnchor),
            footer.widthAnchor.constraint(equalTo: layout.widthAnchor)
        ])
    }

    private func refresh() {
        let active = server.modelURL != nil
        let modelURL = server.modelURL ?? selectedModelURL
        modelLabel.stringValue = modelURL.lastPathComponent
        let available = FileManager.default.isReadableFile(atPath: modelURL.path)
        statusLabel.stringValue = !active && !available
            ? "Download or choose a model in AI Agent before sharing."
            : server.status
        shareButton.title = active ? "Stop Sharing" : "Start Sharing"
        shareButton.isEnabled = active || available
        if active, !server.isRunning { progress.startAnimation(nil) }
        else { progress.stopAnimation(nil) }

        let previousHost = displayedURI.flatMap(Self.host)
        pairingURIs = server.pairingURIs
        if let externalEndpoint, let uri = server.pairingURI(host: externalEndpoint.host, port: externalEndpoint.port),
           !pairingURIs.contains(uri) { pairingURIs.insert(uri, at: 0) }
        addressMenu.removeAllItems()
        for uri in pairingURIs { addressMenu.addItem(withTitle: Self.host(uri) ?? "Network address") }
        if let previousHost, let index = pairingURIs.firstIndex(where: { Self.host($0) == previousHost }) {
            addressMenu.selectItem(at: index)
        }
        addressMenu.isHidden = pairingURIs.count < 2
        routerButton.isEnabled = server.isRunning && mappingTask == nil
        showPairingURI()
    }

    private func showPairingURI() {
        let index = addressMenu.indexOfSelectedItem
        let uri = pairingURIs.indices.contains(index) ? pairingURIs[index] : nil
        if displayedURI != uri {
            displayedURI = uri
            qrView.image = uri.flatMap(Self.qrCode)
            copyButton.title = "Copy Pairing Link"
        }
        pairingLink.stringValue = uri?.absoluteString ?? ""
        qrView.isHidden = uri == nil
        pairingLink.isHidden = uri == nil
        copyButton.isEnabled = uri != nil
    }

    @objc private func toggleSharing(_ sender: Any?) {
        if server.modelURL != nil {
            server.stop()
            Task { await stopSharing() }
        } else {
            do { try server.start(modelURL: selectedModelURL) }
            catch { statusLabel.stringValue = error.localizedDescription }
        }
    }

    @objc private func useInternetAddress(_ sender: Any?) {
        let host = internetAddress.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty, host.utf8.count <= 253, !host.contains(where: { $0.isWhitespace }),
              !host.contains(where: { "/?#@%".contains($0) }),
              let port = UInt16(internetPort.stringValue), port > 0,
              (host.contains(":") ? IPv6Address(host) != nil : host.utf8.allSatisfy({
                  (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46
              })) else {
            internetStatus.stringValue = "Enter an IPv4, IPv6, or hostname and a TCP port from 1 to 65535."
            return
        }
        externalEndpoint = (host, port)
        automaticallyMappedEndpoint = false
        UserDefaults.standard.set(host, forKey: "BrowserAgentInternetAddress")
        UserDefaults.standard.set(String(port), forKey: "BrowserAgentInternetPort")
        internetStatus.stringValue = "The pairing link now uses \(host). Forward this external port to TCP \(BrowserAgentServer.sharingPort) on this Mac, or allow the port in your IPv6 firewall."
        displayedURI = nil
        refresh()
    }

    @objc private func findInternetAddress(_ sender: Any?) {
        guard server.isRunning, let port = server.port, mappingTask == nil else { return }
        internetStatus.stringValue = "Checking your local router for a direct internet connection…"
        routerButton.isEnabled = false
        let identity = UUID()
        mappingIdentity = identity
        mappingTask = Task { [weak self] in
            guard let self else { return }
            defer { if mappingIdentity == identity { mappingTask = nil; refresh() } }
            do {
                let mapping = try await router.open(port: port, localAddresses: server.addresses)
                try Task.checkCancellation()
                guard server.isRunning, mappingIdentity == identity else { return }
                internetAddress.stringValue = mapping.host
                internetPort.stringValue = String(mapping.port)
                externalEndpoint = (mapping.host, mapping.port)
                automaticallyMappedEndpoint = true
                displayedURI = nil
                refresh()
                internetStatus.stringValue = "Your router opened a direct connection at \(mapping.host):\(mapping.port). Pair with the updated QR code or link."
            } catch {
                if Task.isCancelled {
                    if mappingIdentity == identity { await router.close() }
                } else if mappingIdentity == identity { internetStatus.stringValue = error.localizedDescription }
            }
        }
    }

    @objc private func resetPairing(_ sender: Any?) {
        mappingIdentity = UUID()
        mappingTask?.cancel()
        mappingTask = nil
        Task { await router.close() }
        if automaticallyMappedEndpoint { externalEndpoint = nil; automaticallyMappedEndpoint = false }
        do { try server.resetPairing() }
        catch { statusLabel.stringValue = error.localizedDescription }
        refresh()
    }

    func stopSharing() async {
        mappingIdentity = UUID()
        mappingTask?.cancel()
        mappingTask = nil
        server.stop()
        if automaticallyMappedEndpoint { externalEndpoint = nil; automaticallyMappedEndpoint = false }
        refresh()
        await router.close()
    }

    @objc private func selectAddress(_ sender: Any?) { showPairingURI() }

    @objc private func copyPairingLink(_ sender: Any?) {
        guard let uri = displayedURI else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(uri.absoluteString, forType: .string)
        copyButton.title = "Copied"
    }

    @objc private func dismiss(_ sender: Any?) {
        guard let window else { return }
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
    }

    private static func host(_ uri: URL) -> String? {
        URLComponents(url: uri, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "host" })?.value
    }

    private static func qrCode(_ uri: URL) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(uri.absoluteString.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage,
              let code = CIContext().createCGImage(output, from: output.extent) else { return nil }
        let scale = floor(188 / output.extent.width)
        guard scale >= 1 else { return nil }
        let size = NSSize(width: CGFloat(code.width) * scale, height: CGFloat(code.height) * scale)
        let image = NSImage(size: NSSize(width: 220, height: 220))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: image.size)).fill()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: code, size: size).draw(in: NSRect(x: (220 - size.width) / 2,
                                                       y: (220 - size.height) / 2,
                                                       width: size.width, height: size.height))
        image.unlockFocus()
        return image
    }
}
