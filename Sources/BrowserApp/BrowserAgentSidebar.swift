import AppKit
import UniformTypeIdentifiers

@MainActor
final class BrowserAgentSidebar: NSView, NSTextViewDelegate {
    var onRun: ((String, URL?) -> Void)?
    var onStop: (() -> Void)?
    var onClose: (() -> Void)?

    private static let modelPreference = "BrowserAgentModelPath"
    private let taskScroll = NSTextView.scrollableTextView()
    private let logScroll = NSTextView.scrollableTextView()
    private let reviewScroll = NSTextView.scrollableTextView()
    private var taskView: NSTextView { taskScroll.documentView as! NSTextView }
    private var logView: NSTextView { logScroll.documentView as! NSTextView }
    private var reviewText: NSTextView { reviewScroll.documentView as! NSTextView }
    private let stateLabel = NSTextField(labelWithString: "Ready")
    private let modelLabel = NSTextField(labelWithString: "")
    private let modelMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    private let layout = NSStackView()
    private let downloadButton = NSButton(title: "Download Model", target: nil, action: nil)
    private let downloadDetails = NSTextField(labelWithString: "429 MB from Hugging Face")
    private let downloadRow = NSStackView()
    private let runButton = NSButton(title: "Run", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let devicesButton = NSButton(title: "Devices…", target: nil, action: nil)
    private let activity = NSStackView()
    private let review = NSStackView()
    private let allowButton = NSButton(title: "Allow", target: nil, action: nil)
    private var reviewContinuation: CheckedContinuation<Bool, Never>?
    private var downloadTask: Task<Void, Never>?
    private var running = false
    private var stopping = false
    private var modelURL: URL? = UserDefaults.standard.string(forKey: modelPreference).map {
        URL(fileURLWithPath: $0)
    }

    init() {
        super.init(frame: .zero)
        buildInterface()
        NotificationCenter.default.addObserver(self, selector: #selector(devicesChanged(_:)),
                                               name: .browserAgentDevicesDidChange, object: nil)
        updateModel()
        updateControls()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func focusTask() {
        updateModel()
        updateControls()
        window?.makeFirstResponder(reviewContinuation == nil ? taskView : reviewText)
    }

    func appendActivity(_ message: String) {
        guard running, !stopping else { return }
        appendLog(message)
    }

    func finish(result: String) {
        guard running else { return }
        if stopping { didStop(); return }
        endRun(status: "Complete", log: result, heading: "Result")
    }

    func fail(_ message: String) {
        guard running else { return }
        if stopping { didStop(); return }
        endRun(status: "Couldn’t finish", log: message, heading: "Error")
    }

    func didStop() {
        guard running else { return }
        endRun(status: "Stopped", log: "Stopped by you.")
    }

    func stop() {
        downloadTask?.cancel()
        guard running, !stopping else { return }
        stopping = true
        stateLabel.stringValue = "Stopping…"
        resolveReview(false)
        updateControls()
        onStop?()
    }

    func requestApproval(_ message: String) async -> Bool {
        guard running, !stopping, reviewContinuation == nil else { return false }
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return false }
            return await withCheckedContinuation { continuation in
                reviewContinuation = continuation
                reviewText.string = message
                reviewText.scrollRangeToVisible(NSRange(location: 0, length: 0))
                showDetails(review)
                stateLabel.stringValue = "Waiting for review"
                if !isHidden { window?.makeFirstResponder(reviewText) }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.resolveReview(false) }
        }
    }

    func textDidChange(_ notification: Notification) { updateControls() }

    private func buildInterface() {
        let title = NSTextField(labelWithString: "AI Agent")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        stateLabel.font = .systemFont(ofSize: 11, weight: .medium)
        stateLabel.textColor = .secondaryLabelColor
        stateLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close AI Agent")!,
                                   target: self, action: #selector(closeSidebar(_:)))
        closeButton.isBordered = false
        closeButton.toolTip = "Close AI Agent (⇧⌘A)"
        closeButton.setAccessibilityLabel("Close AI Agent")
        closeButton.widthAnchor.constraint(equalToConstant: 22).isActive = true
        closeButton.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let header = NSStackView(views: [title, NSView(), stateLabel, closeButton])
        header.spacing = 8
        header.alignment = .centerY
        header.distribution = .fill

        let promptLabel = NSTextField(labelWithString: "Task")
        promptLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        configureEditor(taskView, in: taskScroll, label: "Browser task", editable: true)
        taskView.delegate = self
        taskView.allowsUndo = true
        taskView.isAutomaticQuoteSubstitutionEnabled = false
        taskView.isAutomaticDashSubstitutionEnabled = false
        let taskHeight = taskScroll.heightAnchor.constraint(equalToConstant: 56)
        taskHeight.priority = .defaultHigh
        taskHeight.isActive = true

        runButton.target = self
        runButton.action = #selector(runTask(_:))
        stopButton.target = self
        stopButton.action = #selector(stopTask(_:))
        runButton.toolTip = "Start the browser task"
        stopButton.toolTip = "Stop the agent"
        devicesButton.target = self
        devicesButton.action = #selector(chooseDevice(_:))
        devicesButton.toolTip = "Choose a paired device’s model or share this Mac’s model"
        devicesButton.setAccessibilityLabel("Model Devices")
        let actions = NSStackView(views: [runButton, stopButton, NSView(), devicesButton])
        actions.spacing = 7

        modelLabel.font = .systemFont(ofSize: 11)
        modelLabel.textColor = .secondaryLabelColor
        modelLabel.lineBreakMode = .byTruncatingMiddle
        modelLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        modelMenu.controlSize = .small
        modelMenu.menu?.autoenablesItems = false
        modelMenu.setAccessibilityLabel("Model options")
        modelMenu.addItem(withTitle: "Model")
        modelMenu.addItem(withTitle: "Choose Model…")
        modelMenu.addItem(withTitle: "Use Default Model")
        modelMenu.item(at: 1)?.target = self
        modelMenu.item(at: 1)?.action = #selector(chooseModel(_:))
        modelMenu.item(at: 2)?.target = self
        modelMenu.item(at: 2)?.action = #selector(useDefaultModel(_:))
        modelMenu.menu?.addItem(.separator())
        modelMenu.addItem(withTitle: "Share Model…")
        modelMenu.lastItem?.target = self
        modelMenu.lastItem?.action = #selector(connectPhone(_:))
        modelMenu.addItem(withTitle: "Model Devices…")
        modelMenu.lastItem?.target = self
        modelMenu.lastItem?.action = #selector(chooseDevice(_:))
        let modelRow = NSStackView(views: [modelLabel, modelMenu])
        modelRow.alignment = .centerY
        modelRow.distribution = .fill
        downloadButton.target = self
        downloadButton.action = #selector(downloadModel(_:))
        downloadDetails.font = .systemFont(ofSize: 10)
        downloadDetails.textColor = .secondaryLabelColor
        downloadDetails.lineBreakMode = .byTruncatingTail
        downloadDetails.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        downloadRow.addArrangedSubview(downloadButton)
        downloadRow.addArrangedSubview(downloadDetails)
        downloadRow.alignment = .centerY

        configureReview()
        let activityLabel = NSTextField(labelWithString: "Activity")
        activityLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        configureEditor(logView, in: logScroll, label: "Agent activity and result", editable: false)
        logScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        activity.orientation = .vertical
        activity.alignment = .leading
        activity.distribution = .fill
        activity.spacing = 6
        activity.addArrangedSubview(activityLabel)
        activity.addArrangedSubview(logScroll)
        appendLog("Ask the agent to summarize a page or follow a link. It starts from the page you’re viewing.")

        layout.orientation = .vertical
        layout.alignment = .leading
        layout.distribution = .fill
        layout.spacing = 6
        layout.translatesAutoresizingMaskIntoConstraints = false
        for view in [header, promptLabel, taskScroll, actions, modelRow, activity] {
            layout.addArrangedSubview(view)
        }
        addSubview(layout)
        NSLayoutConstraint.activate([
            layout.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            layout.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
            layout.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            layout.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            header.widthAnchor.constraint(equalTo: layout.widthAnchor),
            taskScroll.widthAnchor.constraint(equalTo: layout.widthAnchor),
            taskScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 38),
            actions.widthAnchor.constraint(equalTo: layout.widthAnchor),
            modelRow.widthAnchor.constraint(equalTo: layout.widthAnchor),
            activity.widthAnchor.constraint(equalTo: layout.widthAnchor),
            logScroll.widthAnchor.constraint(equalTo: activity.widthAnchor),
            logScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 32)
        ])
    }

    private func configureEditor(_ editor: NSTextView, in scroll: NSScrollView, label: String, editable: Bool) {
        scroll.borderType = .bezelBorder
        scroll.autohidesScrollers = true
        scroll.hasVerticalScroller = true
        editor.setAccessibilityLabel(label)
        editor.isEditable = editable
        editor.isSelectable = true
        editor.isRichText = false
        editor.importsGraphics = false
        editor.textContainerInset = NSSize(width: 5, height: 5)
        editor.font = .systemFont(ofSize: 13)
    }

    @objc private func closeSidebar(_ sender: Any?) { onClose?() }

    private func configureReview() {
        let label = NSTextField(labelWithString: "Review website action")
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        configureEditor(reviewText, in: reviewScroll, label: "Website action to review", editable: false)
        let skip = NSButton(title: "Skip", target: self, action: #selector(skipReview(_:)))
        allowButton.target = self
        allowButton.action = #selector(allowReview(_:))
        let buttons = NSStackView(views: [skip, allowButton])
        buttons.spacing = 7
        review.orientation = .vertical
        review.alignment = .leading
        review.distribution = .fill
        review.spacing = 5
        for view in [label, reviewScroll, buttons] { review.addArrangedSubview(view) }
        NSLayoutConstraint.activate([
            reviewScroll.widthAnchor.constraint(equalTo: review.widthAnchor),
            reviewScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 38)
        ])
    }

    private func updateModel() {
        modelLabel.stringValue = BrowserAgentDevices.shared.selected.map { "\($0.name) · Remote model" }
            ?? modelURL?.lastPathComponent ?? "Qwen2.5 0.5B · On device"
        modelLabel.toolTip = modelLabel.stringValue
        let showDownload = BrowserAgentDevices.shared.selected == nil && (!modelIsAvailable || downloadTask != nil)
        if showDownload, downloadRow.superview == nil {
            layout.insertArrangedSubview(downloadRow, at: layout.arrangedSubviews.count - 1)
            downloadRow.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
        } else if !showDownload {
            downloadRow.removeFromSuperview()
        }
        downloadButton.title = downloadTask == nil ? "Download Model" : "Cancel Download"
    }

    private func showDetails(_ details: NSView) {
        let oldDetails = details === review ? activity : review
        oldDetails.removeFromSuperview()
        layout.addArrangedSubview(details)
        details.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
        window?.recalculateKeyViewLoop()
    }

    private var modelIsAvailable: Bool {
        BrowserAgentDevices.shared.selected != nil ||
            FileManager.default.isReadableFile(atPath: (modelURL ?? BrowserAgentModel.defaultURL).path)
    }

    private func updateControls() {
        let task = taskView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        runButton.isEnabled = !running && downloadTask == nil && !task.isEmpty &&
            (modelIsAvailable || BrowserAgentTask(task).directReply != nil)
        stopButton.isEnabled = running && !stopping
        taskView.isEditable = !running
        let canChooseModel = !running && downloadTask == nil
        modelMenu.item(at: 1)?.isEnabled = canChooseModel
        modelMenu.item(at: 2)?.isEnabled = canChooseModel
        modelMenu.item(at: 4)?.isEnabled = canChooseModel
        modelMenu.item(at: 5)?.isEnabled = canChooseModel
        devicesButton.isEnabled = canChooseModel
        downloadButton.isEnabled = !running
    }

    @objc private func chooseModel(_ sender: Any?) {
        guard !running, let window else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose a compatible GGUF model"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let type = UTType(filenameExtension: "gguf") { panel.allowedContentTypes = [type] }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            do { try BrowserAgentDevices.shared.select(nil) }
            catch { self.appendLog(error.localizedDescription, heading: "Model device"); return }
            self.modelURL = url
            UserDefaults.standard.set(url.path, forKey: Self.modelPreference)
            self.updateModel()
            self.updateControls()
        }
    }

    @objc private func connectPhone(_ sender: Any?) {
        guard !running, downloadTask == nil, let window else { return }
        BrowserAgentSharingController.shared.present(from: window, modelURL: modelURL ?? BrowserAgentModel.defaultURL)
    }

    @objc private func chooseDevice(_ sender: Any?) {
        guard !running, downloadTask == nil, let window else { return }
        BrowserAgentDevicesController.shared.present(from: window, modelURL: modelURL ?? BrowserAgentModel.defaultURL)
    }

    @objc private func devicesChanged(_ notification: Notification) {
        updateModel()
        updateControls()
    }

    @objc private func useDefaultModel(_ sender: Any?) {
        guard !running else { return }
        do { try BrowserAgentDevices.shared.select(nil) }
        catch { appendLog(error.localizedDescription, heading: "Model device"); return }
        modelURL = nil
        UserDefaults.standard.removeObject(forKey: Self.modelPreference)
        updateModel()
        updateControls()
    }

    @objc private func downloadModel(_ sender: Any?) {
        if let downloadTask {
            downloadTask.cancel()
            downloadButton.isEnabled = false
            stateLabel.stringValue = "Canceling…"
            return
        }
        guard !running else { return }
        stateLabel.stringValue = "Downloading…"
        downloadTask = Task { [weak self] in
            do {
                _ = try await BrowserAgentModel.downloadDefault()
                self?.downloadTask = nil
                self?.stateLabel.stringValue = "Ready"
                self?.useDefaultModel(nil)
            } catch {
                guard let self else { return }
                self.downloadTask = nil
                if Task.isCancelled {
                    self.stateLabel.stringValue = "Ready"
                } else {
                    self.stateLabel.stringValue = "Download failed"
                    self.appendLog(error.localizedDescription, heading: "Model download")
                }
                self.updateModel()
                self.updateControls()
            }
        }
        updateModel()
        updateControls()
    }

    @objc private func runTask(_ sender: Any?) {
        let task = taskView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty, !running, let onRun else { return }
        running = true
        stateLabel.stringValue = "Running"
        logView.string = ""
        appendLog(task, heading: "Task")
        updateControls()
        onRun(task, modelURL)
    }

    @objc private func stopTask(_ sender: Any?) { stop() }
    @objc private func allowReview(_ sender: Any?) { resolveReview(true) }
    @objc private func skipReview(_ sender: Any?) { resolveReview(false) }

    private func resolveReview(_ allowed: Bool) {
        guard let continuation = reviewContinuation else { return }
        reviewContinuation = nil
        showDetails(activity)
        if running, !stopping { stateLabel.stringValue = "Running" }
        continuation.resume(returning: allowed)
    }

    private func endRun(status: String, log: String, heading: String? = nil) {
        resolveReview(false)
        running = false
        stopping = false
        stateLabel.stringValue = status
        appendLog(log, heading: heading)
        updateControls()
    }

    private func appendLog(_ message: String, heading: String? = nil) {
        guard let storage = logView.textStorage else { return }
        if storage.length > 0 { storage.append(NSAttributedString(string: "\n\n")) }
        if let heading {
            storage.append(NSAttributedString(string: heading + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor
            ]))
        }
        storage.append(NSAttributedString(string: message, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor
        ]))
        logView.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
    }
}
