import Foundation

public enum Address {
    /// Classifies typed input. Programmatic navigation continues to use strict address resolution.
    public static func resolveInput(_ input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let lower = value.lowercased()
        if lower.hasPrefix("browser:search"), let location = URL(string: value),
           let query = WebSearch.query(in: location) {
            return WebSearch.location(for: query)
        }
        let explicit = value.hasPrefix("/") || value.hasPrefix("~/")
            || lower.range(of: #"^[a-z][a-z0-9+.-]*://"#, options: .regularExpression) != nil
            || ["http:", "https:", "file:", "browser:", "browseragent:", "javascript:", "data:",
                "mailto:", "tel:", "ftp:", "about:"].contains(where: lower.hasPrefix)
        let authority = value.prefix { !"/?#".contains($0) }
        let suffix = value.dropFirst(authority.count)
        let hasHostLabel = !authority.isEmpty && authority.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let hasAddressSuffix = suffix.hasPrefix("/") || (suffix.hasPrefix("#") && suffix.count > 1)
            || (suffix.hasPrefix("?") && suffix.contains("="))
        if explicit || (!authority.contains(where: \.isWhitespace)
                        && (authority.lowercased() == "localhost" || authority.contains(".")
                            || authority.contains(":") || authority.hasPrefix("[") || authority.contains("@")
                            || (hasHostLabel && hasAddressSuffix))) {
            return resolve(value)
        }
        return WebSearch.location(for: value)
    }

    /// Resolves address-bar input without sending it to a search provider.
    public static func resolve(_ input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.lowercased() == "browser:home" { return URL(string: "browser:home") }
        if value.hasPrefix("/") || value.hasPrefix("~/") {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        }

        let lower = value.lowercased()
        if let colon = lower.firstIndex(of: ":"),
           ["javascript", "data", "mailto", "tel", "ftp", "about", "browser"].contains(String(lower[..<colon])) {
            return nil
        }
        if lower.hasPrefix("file:") {
            guard let url = URL(string: value), url.isFileURL,
                  url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
            return url
        }

        let candidate: String
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            candidate = value
        } else {
            // A colon followed by a numeric port belongs to a host, not a URL scheme.
            let authority = String(value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)[0])
                .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            if let colon = authority.lastIndex(of: ":"), !authority.hasPrefix("[") {
                let port = authority[authority.index(after: colon)...]
                guard !port.isEmpty, port.allSatisfy(\.isNumber) else { return nil }
            }
            let isLoopback = lower == "localhost" || lower.hasPrefix("localhost:")
                || lower.hasPrefix("localhost/") || lower.hasPrefix("localhost?") || lower.hasPrefix("localhost#")
                || lower == "127.0.0.1" || lower.hasPrefix("127.0.0.1:") || lower.hasPrefix("127.0.0.1/")
                || lower.hasPrefix("[::1]")
            candidate = (isLoopback ? "http://" : "https://") + value
        }

        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              components.user == nil, components.password == nil else { return nil }
        if let port = components.port, !(1...65535).contains(port) { return nil }
        return components.url
    }
}

public struct NavigationHistory {
    public private(set) var entries: [URL] = []
    public private(set) var index: Int = -1
    public init() {}

    public var current: URL? { entries.indices.contains(index) ? entries[index] : nil }
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index >= 0 && index + 1 < entries.count }

    public mutating func push(_ url: URL) {
        guard current != url else { return }
        discardForwardEntries()
        entries.append(url)
        index = entries.count - 1
    }

    public mutating func discardForwardEntries() {
        if index + 1 < entries.count { entries.removeSubrange((index + 1)..<entries.count) }
    }

    public mutating func back() -> URL? {
        guard canGoBack else { return nil }
        index -= 1
        return current
    }

    public mutating func forward() -> URL? {
        guard canGoForward else { return nil }
        index += 1
        return current
    }

    public mutating func replaceCurrent(_ url: URL) {
        guard entries.indices.contains(index) else { push(url); return }
        entries[index] = url
    }
}
