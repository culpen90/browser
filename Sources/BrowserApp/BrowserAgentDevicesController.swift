import AppKit

@MainActor
final class BrowserAgentDevicesController: NSWindowController, NSWindowDelegate, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    static let shared = BrowserAgentDevicesController()
    private let devices = BrowserAgentDevices.shared
    private let deviceMenu = NSPopUpButton()
    private let link = NSSecureTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let nearby = NSTextField(wrappingLabelWithString: "")
    private let removeButton = NSButton(title: "Forget Device", target: nil, action: nil)
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var modelURL = BrowserAgentModel.defaultURL

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 430),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Model Devices"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildInterface()
        browser.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(devicesChanged(_:)),
                                               name: .browserAgentDevicesDidChange, object: nil)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(from parent: NSWindow, modelURL: URL = BrowserAgentModel.defaultURL) {
        guard let window else { return }
        self.modelURL = modelURL
        refresh()
        if let existing = window.sheetParent { existing.makeKeyAndOrderFront(nil); return }
        guard parent.attachedSheet == nil else { return }
        parent.beginSheet(window)
        services.removeAll()
        nearby.stringValue = "Looking for nearby devices…"
        browser.searchForServices(ofType: "_browseragent._tcp.", inDomain: "local.")
    }

    func receivePairingURL(_ url: URL, from parent: NSWindow) {
        present(from: parent)
        do {
            try devices.add(BrowserAgentConnection.parse(url))
            status.stringValue = "Device saved. Its model will handle your next agent task."
        } catch { status.stringValue = error.localizedDescription }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(nil); return false }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString: "Choose where the model runs")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString:
            "Select this Mac or a paired device. Add a device once using the pairing link from its Model Sharing window.")
        explanation.font = .systemFont(ofSize: 13)
        deviceMenu.target = self
        deviceMenu.action = #selector(selectDevice(_:))
        deviceMenu.setAccessibilityLabel("Model device")
        deviceMenu.setContentHuggingPriority(.defaultLow, for: .horizontal)
        removeButton.target = self
        removeButton.action = #selector(forgetDevice(_:))
        let selection = NSStackView(views: [deviceMenu, removeButton])
        selection.spacing = 8
        selection.distribution = .fill
        link.placeholderString = "Paste pairing link"
        link.setAccessibilityLabel("Device pairing link")
        link.target = self
        link.action = #selector(addDevice(_:))
        link.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let add = NSButton(title: "Add Device", target: self, action: #selector(addDevice(_:)))
        let input = NSStackView(views: [link, add])
        input.spacing = 8
        status.font = .systemFont(ofSize: 12)
        status.setAccessibilityLabel("Device connection status")
        nearby.font = .systemFont(ofSize: 11)
        nearby.textColor = .secondaryLabelColor
        let internet = NSTextField(wrappingLabelWithString:
            "Internet connections go directly to the address in the pairing link. The sharing device needs a reachable public address and open port, or a private network connecting your devices.")
        internet.font = .systemFont(ofSize: 11)
        internet.textColor = .secondaryLabelColor
        let share = NSButton(title: "Share This Mac’s Model…", target: self, action: #selector(shareModel(_:)))
        let phone = NSButton(title: "Connect a Phone…", target: self, action: #selector(connectPhone(_:)))
        let sharing = NSStackView(views: [share, phone])
        sharing.spacing = 8
        let done = NSButton(title: "Done", target: self, action: #selector(dismiss(_:)))
        done.keyEquivalent = "\r"
        let footer = NSStackView(views: [NSView(), done])
        let stack = NSStackView(views: [title, explanation, selection, input, status, nearby, internet, sharing, NSView(), footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
        for view in [explanation, selection, input, status, nearby, internet, footer] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func refresh() {
        deviceMenu.removeAllItems()
        deviceMenu.addItem(withTitle: "This Mac · On device")
        for device in devices.devices { deviceMenu.addItem(withTitle: device.name) }
        if let selected = devices.selected,
           let index = devices.devices.firstIndex(where: { $0.id == selected.id }) {
            deviceMenu.selectItem(at: index + 1)
            status.stringValue = "\(selected.name) · \(selected.host):\(selected.port)"
        } else { deviceMenu.selectItem(at: 0); status.stringValue = "The model runs on this Mac." }
        removeButton.isEnabled = devices.selected != nil
        if let error = devices.loadError { status.stringValue = error.localizedDescription }
    }

    @objc private func devicesChanged(_ notification: Notification) { refresh() }

    @objc private func selectDevice(_ sender: Any?) {
        let index = deviceMenu.indexOfSelectedItem - 1
        do { try devices.select(devices.devices.indices.contains(index) ? devices.devices[index].id : nil) }
        catch { refresh(); status.stringValue = error.localizedDescription }
    }

    @objc private func addDevice(_ sender: Any?) {
        do {
            guard let url = URL(string: link.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw BrowserAgentConnection.ConnectionError.invalidLink
            }
            try devices.add(BrowserAgentConnection.parse(url))
            link.stringValue = ""
            status.stringValue = "Device saved. Its model will handle your next agent task."
        } catch { status.stringValue = error.localizedDescription }
    }

    @objc private func forgetDevice(_ sender: Any?) {
        guard let selected = devices.selected else { return }
        do { try devices.remove(selected.id) }
        catch { status.stringValue = error.localizedDescription }
    }

    @objc private func shareModel(_ sender: Any?) {
        guard let parent = window?.sheetParent else { return }
        dismiss(nil)
        BrowserAgentSharingController.shared.present(from: parent, modelURL: modelURL)
    }

    @objc private func connectPhone(_ sender: Any?) {
        guard let parent = window?.sheetParent else { return }
        dismiss(nil)
        BrowserAgentPhonesController.shared.present(from: parent, modelURL: modelURL)
    }

    @objc private func dismiss(_ sender: Any?) {
        browser.stop()
        for service in services { service.stop() }
        services.removeAll()
        guard let window else { return }
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 3)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0 == service }
        updateNearby()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        nearby.stringValue = "Nearby discovery is unavailable. You can still add a pairing link."
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        if let data = sender.txtRecordData(),
           let idData = NetService.dictionary(fromTXTRecord: data)["id"],
           let id = String(data: idData, encoding: .utf8),
           let host = sender.hostName, let port = UInt16(exactly: sender.port), port > 0 {
            devices.cacheNearbyRoute(id: id, host: host, port: port)
        }
        updateNearby()
    }

    private func updateNearby() {
        let names = services.compactMap { service -> String? in
            guard let data = service.txtRecordData(),
                  let idData = NetService.dictionary(fromTXTRecord: data)["id"],
                  let id = String(data: idData, encoding: .utf8), UUID(uuidString: id) != nil else { return nil }
            let records = NetService.dictionary(fromTXTRecord: data)
            let name = records["name"].flatMap { String(data: $0, encoding: .utf8) } ?? service.name
            return String(name.prefix(100)).components(separatedBy: .controlCharacters).joined()
        }
        nearby.stringValue = names.isEmpty ? "No nearby model devices found." : "Nearby: " + names.joined(separator: ", ")
    }
}
