import AppKit

@MainActor
final class BrowserAgentPhonesController: NSWindowController, NSWindowDelegate,
    @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    static let shared = BrowserAgentPhonesController()
    private let saved = BrowserAgentPhones.shared
    private let phoneMenu = NSPopUpButton()
    private let phoneLink = NSTextField()
    private let macAddress = NSTextField()
    private let macPort = NSTextField(string: String(BrowserAgentServer.sharingPort))
    private let status = NSTextField(wrappingLabelWithString: "")
    private let code = NSTextField(labelWithString: "")
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let forgetButton = NSButton(title: "Forget Saved Phone", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel Connection", target: nil, action: nil)
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var nearby: [String: BrowserAgentPhone] = [:]
    private var manual: [String: BrowserAgentPhone] = [:]
    private var choices: [Choice] = []
    private var modelURL = BrowserAgentModel.defaultURL
    private var operation: Task<Void, Never>?
    private var pending: Pending?
    private var refreshTimer: Timer?

    private struct Choice {
        let id: String
        let name: String
        let phone: BrowserAgentPhone?
        var identifier: String { (phone == nil ? "connected:" : "phone:") + id }
    }
    private struct Pending {
        let connection: BrowserAgentPhoneConnection
        let link: URL
        let phone: BrowserAgentPhone
        let expires: Date
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Connect a Phone"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        browser.delegate = self
        buildInterface()
        BrowserAgentPhonePresence.shared.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(from parent: NSWindow, modelURL: URL = BrowserAgentModel.defaultURL) {
        guard let window else { return }
        self.modelURL = modelURL
        if let existing = window.sheetParent { existing.makeKeyAndOrderFront(nil); return }
        guard parent.attachedSheet == nil else { return }
        status.stringValue = "Open Browser’s Receive Connection screen on your phone, then select it here."
        parent.beginSheet(window)
        services.removeAll()
        nearby.removeAll()
        browser.searchForServices(ofType: "_browseragent-phone._tcp.", inDomain: "local.")
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func receivePhoneURL(_ url: URL, from parent: NSWindow, modelURL: URL = BrowserAgentModel.defaultURL) {
        present(from: parent, modelURL: modelURL)
        do {
            let phone = try BrowserAgentPhone.parse(url)
            manual[phone.id] = phone
            refresh(select: "phone:" + phone.id)
            status.stringValue = "Select Connect to send this Mac’s model connection to \(phone.name)."
        } catch { status.stringValue = error.localizedDescription }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(nil); return false }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString: "Use this Mac’s model on your phone")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString:
            "Choose a connected phone or find one nearby. Your phone uses the model running on this Mac for its own browser tasks.")
        explanation.font = .systemFont(ofSize: 13)
        phoneMenu.target = self
        phoneMenu.action = #selector(selectionChanged(_:))
        phoneMenu.setAccessibilityLabel("Phone to connect")
        phoneLink.placeholderString = "Paste a phone link"
        phoneLink.setAccessibilityLabel("Phone connection link")
        phoneLink.target = self
        phoneLink.action = #selector(addPhone(_:))
        phoneLink.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let add = NSButton(title: "Add Phone", target: self, action: #selector(addPhone(_:)))
        let input = NSStackView(views: [phoneLink, add])
        input.spacing = 8
        let addressTitle = NSTextField(labelWithString: "Mac address for this phone (optional)")
        addressTitle.font = .systemFont(ofSize: 11)
        macAddress.placeholderString = "Automatic, or your Mac’s reachable public address"
        macAddress.setAccessibilityLabel("Mac address reachable from phone")
        macAddress.setContentHuggingPriority(.defaultLow, for: .horizontal)
        macPort.setAccessibilityLabel("Mac model TCP port")
        macPort.widthAnchor.constraint(equalToConstant: 68).isActive = true
        let route = NSStackView(views: [macAddress, macPort])
        route.spacing = 8
        status.font = .systemFont(ofSize: 12)
        status.setAccessibilityLabel("Phone connection status")
        code.font = .monospacedDigitSystemFont(ofSize: 24, weight: .semibold)
        code.setAccessibilityLabel("Phone verification code")
        code.isHidden = true
        connectButton.target = self
        connectButton.action = #selector(connect(_:))
        cancelButton.target = self
        cancelButton.action = #selector(cancelConnection(_:))
        cancelButton.isHidden = true
        forgetButton.target = self
        forgetButton.action = #selector(forgetPhone(_:))
        let actions = NSStackView(views: [connectButton, cancelButton, NSView(), forgetButton])
        actions.spacing = 8
        let internet = NSTextField(wrappingLabelWithString:
            "Previously paired phones appear as connected while Browser is open, including over the internet. Pair a new phone nearby, or paste its reachable phone link. Keep this Mac awake with model sharing on.")
        internet.font = .systemFont(ofSize: 11)
        internet.textColor = .secondaryLabelColor
        let done = NSButton(title: "Done", target: self, action: #selector(dismiss(_:)))
        done.keyEquivalent = "\r"
        let footer = NSStackView(views: [NSView(), done])
        let stack = NSStackView(views: [title, explanation, phoneMenu, input, addressTitle, route,
                                       status, code, actions, internet, NSView(), footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
        for view in [explanation, phoneMenu, input, route, status, actions, internet, footer] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private var selection: Choice? {
        choices.indices.contains(phoneMenu.indexOfSelectedItem) ? choices[phoneMenu.indexOfSelectedItem] : nil
    }

    private func refresh(select identifier: String? = nil) {
        guard operation == nil, pending == nil else { return }
        let previous = identifier ?? selection?.identifier
        let connected = BrowserAgentPhonePresence.shared.phones
        let connectedIDs = Set(connected.map(\.id))
        var result = connected.map { Choice(id: $0.id, name: $0.name, phone: nil) }
        var available = Dictionary(uniqueKeysWithValues: saved.saved.map { ($0.id, $0) })
        available.merge(nearby) { _, nearby in nearby }
        available.merge(manual) { _, manual in manual }
        result += available.values.filter { !connectedIDs.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { Choice(id: $0.id, name: $0.name, phone: $0) }
        choices = result
        phoneMenu.removeAllItems()
        for choice in choices {
            let subtitle = choice.phone == nil ? "Connected" : (nearby[choice.id] == nil ? "Saved" : "Nearby")
            phoneMenu.addItem(withTitle: "\(choice.name) · \(subtitle)")
        }
        if choices.isEmpty { phoneMenu.addItem(withTitle: "No phones found") }
        if let previous, let index = choices.firstIndex(where: { $0.identifier == previous }) { phoneMenu.selectItem(at: index) }
        else if let previous, let id = previous.split(separator: ":", maxSplits: 1).last,
                let index = choices.firstIndex(where: { $0.id == id }) { phoneMenu.selectItem(at: index) }
        phoneMenu.isEnabled = !choices.isEmpty
        updateControls()
        if let error = saved.loadError { status.stringValue = error.localizedDescription }
    }

    private func updateControls() {
        let busy = operation != nil
        connectButton.title = pending == nil ? "Connect" : "Code Matches · Connect"
        connectButton.isEnabled = !busy && (selection != nil || pending != nil)
        cancelButton.isHidden = !busy && pending == nil
        phoneMenu.isEnabled = !busy && pending == nil && !choices.isEmpty
        phoneLink.isEnabled = !busy && pending == nil
        macAddress.isEnabled = !busy && pending == nil
        macPort.isEnabled = !busy && pending == nil
        forgetButton.isEnabled = !busy && pending == nil && selection.map { selected in
            saved.saved.contains { $0.id == selected.id }
        } == true
    }

    @objc private func selectionChanged(_ sender: Any?) {
        code.isHidden = true
        updateControls()
        if let selection {
            status.stringValue = selection.phone == nil
                ? "\(selection.name) is connected. Select Connect to choose this Mac’s model on that phone."
                : "Select Connect, then accept the invitation on \(selection.name)."
        }
    }

    @objc private func addPhone(_ sender: Any?) {
        guard operation == nil, pending == nil else { return }
        do {
            guard let url = URL(string: phoneLink.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw BrowserAgentPhone.PhoneError.invalidLink
            }
            let phone = try BrowserAgentPhone.parse(url)
            manual[phone.id] = phone
            phoneLink.stringValue = ""
            refresh(select: "phone:" + phone.id)
            selectionChanged(nil)
        } catch { status.stringValue = error.localizedDescription }
    }

    @objc private func connect(_ sender: Any?) {
        guard operation == nil else { return }
        if let pending {
            self.pending = nil
            guard pending.expires > Date() else {
                status.stringValue = "The invitation expired. Connect again and compare the code."
                updateControls()
                return
            }
            sendConnection(pending)
            return
        }
        guard let choice = selection else { return }
        if BrowserAgentPhonePresence.shared.phones.contains(where: { $0.id == choice.id }) {
            do {
                try BrowserAgentPhonePresence.shared.attach(choice.id)
                status.stringValue = "Connection requested for \(choice.name). The phone will choose this Mac’s model when it next checks in."
            } catch { status.stringValue = error.localizedDescription }
            return
        }
        guard let phone = choice.phone else {
            status.stringValue = "This phone is offline. Open Browser on the phone and try again."
            refresh()
            return
        }
        do { try saved.validatePin(phone) }
        catch { status.stringValue = error.localizedDescription; return }
        operation = Task { [weak self] in
            guard let self else { return }
            defer { operation = nil; updateControls() }
            do {
                if !BrowserAgentServer.shared.isRunning { try BrowserAgentServer.shared.start(modelURL: modelURL) }
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while !BrowserAgentServer.shared.isRunning {
                    guard ContinuousClock.now < deadline else { throw BrowserAgentPhone.PhoneError.unreachable }
                    try await Task.sleep(for: .milliseconds(20))
                }
                let link: URL
                let override = macAddress.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                if !override.isEmpty {
                    guard BrowserAgentConnection.validHost(override), let port = UInt16(macPort.stringValue), port > 0,
                          let uri = BrowserAgentServer.shared.pairingURI(host: override, port: port) else {
                        throw BrowserAgentConnection.ConnectionError.invalidLink
                    }
                    link = uri
                } else {
                    guard let uri = BrowserAgentSharingController.shared.pairingURI(forPeerHost: phone.host) else {
                        throw InvitationError.missingMacAddress
                    }
                    link = uri
                }
                let connection = try BrowserAgentPhoneConnection(phone: phone, senderKey: BrowserAgentPhoneConnection.stableSenderKey())
                code.stringValue = connection.verificationCode
                code.isHidden = false
                status.stringValue = "Compare this code on \(phone.name), then accept the connection there."
                updateControls()
                let reply = try await connection.offer(name: BrowserAgentServer.shared.deviceName, id: BrowserAgentServer.shared.deviceID)
                try Task.checkCancellation()
                guard reply.accepted else { throw BrowserAgentPhone.PhoneError.declined }
                let invitation = Pending(connection: connection, link: link, phone: phone, expires: Date().addingTimeInterval(85))
                if saved.isTrusted(phone) {
                    try await finishConnection(invitation)
                } else {
                    pending = invitation
                    status.stringValue = "The phone accepted. Confirm that both devices show \(connection.verificationCode), then select Code Matches · Connect."
                }
            } catch is CancellationError { status.stringValue = "Connection canceled."; code.isHidden = true }
            catch { status.stringValue = error.localizedDescription; code.isHidden = true }
        }
        updateControls()
    }

    private func sendConnection(_ invitation: Pending) {
        operation = Task { [weak self] in
            guard let self else { return }
            defer { operation = nil; updateControls() }
            do { try await finishConnection(invitation) }
            catch is CancellationError { status.stringValue = "Connection canceled." }
            catch { status.stringValue = error.localizedDescription }
            code.isHidden = true
        }
        updateControls()
    }

    private func finishConnection(_ invitation: Pending) async throws {
        status.stringValue = "Connecting \(invitation.phone.name) to this Mac’s model…"
        let reply = try await invitation.connection.connect(pairingLink: invitation.link)
        try Task.checkCancellation()
        guard reply.accepted else { throw BrowserAgentPhone.PhoneError.declined }
        try saved.remember(invitation.phone)
        status.stringValue = "Connected to \(invitation.phone.name). Run a browser task on your phone to use this Mac’s model."
        code.isHidden = true
    }

    @objc private func cancelConnection(_ sender: Any?) {
        operation?.cancel()
        pending = nil
        code.isHidden = true
        status.stringValue = "Connection canceled."
        updateControls()
    }

    @objc private func forgetPhone(_ sender: Any?) {
        guard let choice = selection else { return }
        do {
            try saved.forget(choice.id)
            manual.removeValue(forKey: choice.id)
            refresh()
            status.stringValue = "Saved phone forgotten."
        } catch { status.stringValue = error.localizedDescription }
    }

    @objc private func dismiss(_ sender: Any?) {
        cancelConnection(nil)
        refreshTimer?.invalidate()
        refreshTimer = nil
        browser.stop()
        for service in services { service.stop() }
        services.removeAll()
        nearby.removeAll()
        guard let window else { return }
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard services.count < 64 else { return }
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 3)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0 == service }
        if let data = service.txtRecordData(), let id = NetService.dictionary(fromTXTRecord: data)["id"],
           let string = String(data: id, encoding: .utf8) { nearby.removeValue(forKey: string.lowercased()) }
        refresh()
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let data = sender.txtRecordData(), let host = sender.hostName,
              let port = UInt16(exactly: sender.port), port > 0 else { return }
        let records = NetService.dictionary(fromTXTRecord: data)
        guard let id = records["id"].flatMap({ String(data: $0, encoding: .utf8) }),
              let name = records["name"].flatMap({ String(data: $0, encoding: .utf8) }),
              let key = records["pub"].flatMap({ String(data: $0, encoding: .utf8) }) else { return }
        var uri = URLComponents()
        uri.scheme = "browseragent"
        uri.host = "phone"
        uri.queryItems = [URLQueryItem(name: "host", value: host), URLQueryItem(name: "port", value: String(port)),
                          URLQueryItem(name: "id", value: id), URLQueryItem(name: "name", value: name),
                          URLQueryItem(name: "pub", value: key)]
        guard let url = uri.url, let phone = try? BrowserAgentPhone.parse(url) else { return }
        nearby[phone.id] = phone
        refresh()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        status.stringValue = "Nearby discovery is unavailable. Choose a connected phone or paste a phone link."
    }

    private enum InvitationError: LocalizedError {
        case missingMacAddress
        var errorDescription: String? { "Enter the Mac address reachable from this phone, or configure an internet address in Share Model first." }
    }
}
