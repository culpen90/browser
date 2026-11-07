import AppKit
import CoreImage

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
    private var selectedModelURL = BrowserAgentModel.defaultURL
    private var pairingURIs: [URL] = []
    private var displayedURI: URL?

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 650),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Connect Phone"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildInterface()
        server.onChange = { [weak self] in self?.refresh() }
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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss(nil)
        return false
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString: "Use this Mac’s model on your phone")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let instructions = NSTextField(wrappingLabelWithString:
            "Connect on the same Wi-Fi. Scan the QR code or paste the pairing link into Browser on your phone.")
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
        qrView.setAccessibilityLabel("Phone pairing QR code")
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

        let explanation = NSTextField(wrappingLabelWithString:
            "Sharing stays on until you stop it or quit Browser. The pairing link grants access to this model.")
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor
        let done = NSButton(title: "Done", target: self, action: #selector(dismiss(_:)))
        done.keyEquivalent = "\r"
        let footer = NSStackView(views: [NSView(), done])
        footer.distribution = .fill
        let layout = NSStackView(views: [title, instructions, modelLabel, status, qrView, addressMenu,
                                       pairingLink, actions, explanation, NSView(), footer])
        layout.orientation = .vertical
        layout.alignment = .leading
        layout.distribution = .fill
        layout.spacing = 10
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
            qrView.widthAnchor.constraint(equalToConstant: 260),
            qrView.heightAnchor.constraint(equalToConstant: 260),
            qrView.centerXAnchor.constraint(equalTo: layout.centerXAnchor),
            pairingLink.widthAnchor.constraint(equalTo: layout.widthAnchor),
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
        addressMenu.removeAllItems()
        for uri in pairingURIs { addressMenu.addItem(withTitle: Self.host(uri) ?? "Network address") }
        if let previousHost, let index = pairingURIs.firstIndex(where: { Self.host($0) == previousHost }) {
            addressMenu.selectItem(at: index)
        }
        addressMenu.isHidden = pairingURIs.count < 2
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
        } else {
            do { try server.start(modelURL: selectedModelURL) }
            catch { statusLabel.stringValue = error.localizedDescription }
        }
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
        let scale = floor(228 / output.extent.width)
        guard scale >= 1 else { return nil }
        let size = NSSize(width: CGFloat(code.width) * scale, height: CGFloat(code.height) * scale)
        let image = NSImage(size: NSSize(width: 260, height: 260))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: image.size)).fill()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: code, size: size).draw(in: NSRect(x: (260 - size.width) / 2,
                                                       y: (260 - size.height) / 2,
                                                       width: size.width, height: size.height))
        image.unlockFocus()
        return image
    }
}
