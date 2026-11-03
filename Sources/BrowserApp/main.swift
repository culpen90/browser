import AppKit

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private var browser: BrowserWindowController?
    private var pendingURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenu()
        let controller = BrowserWindowController()
        browser = controller
        let argumentURL = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }).flatMap { value in
            value.contains("://") || value == "browser:home" ? URL(string: value) : URL(fileURLWithPath: value)
        }
        controller.start(at: pendingURL ?? argumentURL)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { if let browser { browser.navigate(url) } else { pendingURL = url } }
    }
    private func makeMenu() {
        let main = NSMenu()
        let app = NSMenu(title: "Browser")
        app.addItem(withTitle: "About Browser", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Browser", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Browser", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(app, to: main)
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Open File…", action: #selector(BrowserWindowController.openFile(_:)), keyEquivalent: "o")
        file.addItem(withTitle: "Open Location…", action: #selector(BrowserWindowController.focusAddress(_:)), keyEquivalent: "l")
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(file, to: main)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Copy Page Text", action: #selector(BrowserWindowController.copyPageText(_:)), keyEquivalent: "")
        add(edit, to: main)
        let navigation = NSMenu(title: "Navigate")
        navigation.addItem(withTitle: "Back", action: #selector(BrowserWindowController.goBack(_:)), keyEquivalent: "[")
        navigation.addItem(withTitle: "Forward", action: #selector(BrowserWindowController.goForward(_:)), keyEquivalent: "]")
        navigation.addItem(withTitle: "Reload Page", action: #selector(BrowserWindowController.reload(_:)), keyEquivalent: "r")
        navigation.addItem(withTitle: "Stop Loading", action: #selector(BrowserWindowController.stopLoading(_:)), keyEquivalent: "\u{1b}").keyEquivalentModifierMask = []
        navigation.addItem(.separator())
        navigation.addItem(withTitle: "Home", action: #selector(BrowserWindowController.goHome(_:)), keyEquivalent: "H")
        add(navigation, to: main)
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        add(window, to: main)
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }
    private func add(_ submenu: NSMenu, to menu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu; menu.addItem(item)
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = ApplicationDelegate()
    application.setActivationPolicy(.regular)
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
