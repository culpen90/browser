import BrowserCore
import Combine
import Foundation

enum LocalSearchError: LocalizedError {
    case stopped, unavailable, changed

    var errorDescription: String? {
        switch self {
        case .stopped: return "Local search is stopped. Start it in Search Settings."
        case .unavailable: return "Local search couldn’t start. Open Search Settings for details."
        case .changed: return "Local search changed while this query was running. Reload to search again."
        }
    }
}

@MainActor
final class LocalSearchService {
    static let shared = LocalSearchService(resources: Bundle.main.resourceURL)

    private static let sources: [SearchSettingsView.Source] = [
        .init(id: "brave", name: "Brave Search", detail: "General web results from an independent index.", symbol: "compass.drawing"),
        .init(id: "duckduckgo", name: "DuckDuckGo", detail: "A second source for everyday web searches.", symbol: "magnifyingglass"),
        .init(id: "bing", name: "Bing", detail: "More web results from Microsoft’s index.", symbol: "globe.americas"),
    ]
    private static let defaultSources: Set<String> = ["brave", "duckduckgo"]
    private static let sourcesKey = "BrowserSearch.sources"
    private static let safeSearchKey = "BrowserSearch.safeSearch"

    private struct Instance {
        let id: UUID
        let process: Process
        let token: String
        var port: UInt16?
    }

    @Published private(set) var snapshot: SearchSettingsView.Snapshot
    private let resources: URL?
    private let defaults: UserDefaults
    private lazy var client = WebSearchClient()
    private var instance: Instance?
    private var startup: Task<Void, Never>?

    init(resources: URL?, defaults: UserDefaults = .standard) {
        self.resources = resources
        self.defaults = defaults
        let validSources = Set(Self.sources.map(\.id))
        let savedSources = Set(defaults.stringArray(forKey: Self.sourcesKey) ?? []).intersection(validSources)
        let savedSafeSearch = defaults.object(forKey: Self.safeSearchKey) as? Int ?? 1
        snapshot = .init(status: .stopped, sources: Self.sources, defaults: Self.defaultSources,
                         selected: savedSources.isEmpty ? Self.defaultSources : savedSources,
                         safeSearch: (0...2).contains(savedSafeSearch) ? savedSafeSearch : 1)
    }

    func update(_ preferences: SearchSettingsView.Preferences) {
        let sources = preferences.selected.intersection(Set(Self.sources.map(\.id)))
        guard !sources.isEmpty, (0...2).contains(preferences.safeSearch) else { return }
        let sourcesChanged = sources != snapshot.selected
        var updated = snapshot
        updated.selected = sources
        updated.safeSearch = preferences.safeSearch
        snapshot = updated
        defaults.set(sources.sorted(), forKey: Self.sourcesKey)
        defaults.set(preferences.safeSearch, forKey: Self.safeSearchKey)
        // Only the selected engines exist in the instance, including when a query uses a bang.
        if sourcesChanged, instance != nil { restart() }
    }

    func start() {
        guard instance == nil else { return }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        guard let resources,
              FileManager.default.isReadableFile(atPath: resources.appendingPathComponent("LocalSearchLauncher.py").path) else {
            setStatus(.unavailable("Open a packaged copy of Browser to use the bundled SearXNG service."))
            return
        }
        let executable = resources.appendingPathComponent("LocalSearch/\(architecture)/python/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            setStatus(.unavailable("This copy of Browser is missing its local search runtime."))
            return
        }

        let id = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Browser-Search-\(id)", isDirectory: true)
        let token = UUID().uuidString + UUID().uuidString
        let process = Process()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let engines = Self.sources.map(\.id).filter(snapshot.selected.contains)
            let encodedEngines = String(decoding: try JSONEncoder().encode(engines), as: UTF8.self)
            process.executableURL = executable
            process.arguments = ["-I", "-B", resources.appendingPathComponent("LocalSearchLauncher.py").path]
            process.currentDirectoryURL = directory
            process.environment = [
                "PATH": "/usr/bin:/bin",
                "HOME": directory.path,
                "TMPDIR": directory.path,
                "LANG": "en_US.UTF-8",
                "BROWSER_SEARCH_STATE": directory.path,
                "BROWSER_SEARCH_TOKEN": token,
                "BROWSER_SEARCH_PARENT_PID": String(ProcessInfo.processInfo.processIdentifier),
                "BROWSER_SEARCH_ENGINES": encodedEngines,
            ]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] _ in
                try? FileManager.default.removeItem(at: directory)
                Task { @MainActor [weak self] in self?.processExited(id) }
            }
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: directory)
            setStatus(.unavailable("Browser couldn’t launch SearXNG. Try starting it again."))
            return
        }

        instance = Instance(id: id, process: process, token: token)
        setStatus(.starting)
        startup = Task { [weak self] in await self?.waitForPort(of: id, in: directory) }
    }

    func stop() {
        startup?.cancel()
        startup = nil
        let running = instance
        instance = nil
        if let running, running.process.isRunning { running.process.terminate() }
        setStatus(.stopped)
    }

    func restart() {
        stop()
        start()
    }

    func search(_ query: String) async throws -> [WebSearch.Result] {
        guard let id = instance?.id else {
            if case .stopped = snapshot.status { throw LocalSearchError.stopped }
            throw LocalSearchError.unavailable
        }
        let safeSearch = snapshot.safeSearch
        while instance?.id == id, instance?.port == nil {
            try await Task.sleep(for: .milliseconds(75))
        }
        guard let running = instance, running.id == id, let port = running.port else {
            if case .unavailable = snapshot.status { throw LocalSearchError.unavailable }
            throw LocalSearchError.changed
        }
        try Task.checkCancellation()
        let results = try await client.search(query, port: port, token: running.token, safeSearch: safeSearch)
        guard instance?.id == id else { throw LocalSearchError.changed }
        return results
    }

    private func waitForPort(of id: UUID, in directory: URL) async {
        let deadline = ContinuousClock.now + .seconds(30)
        let readyFile = directory.appendingPathComponent("ready")
        while !Task.isCancelled, instance?.id == id {
            if let text = try? String(contentsOf: readyFile, encoding: .ascii), let port = UInt16(text), port > 0 {
                instance?.port = port
                startup = nil
                setStatus(.ready)
                return
            }
            if ContinuousClock.now >= deadline {
                stop()
                setStatus(.unavailable("SearXNG took too long to start. Try restarting local search."))
                return
            }
            try? await Task.sleep(for: .milliseconds(75))
        }
    }

    private func processExited(_ id: UUID) {
        guard instance?.id == id else { return }
        startup?.cancel()
        startup = nil
        instance = nil
        setStatus(.unavailable("SearXNG exited. Restart local search to try again."))
    }

    private func setStatus(_ status: SearchSettingsView.Status) {
        snapshot = .init(status: status, sources: snapshot.sources, defaults: snapshot.defaults,
                         selected: snapshot.selected, safeSearch: snapshot.safeSearch)
    }
}
