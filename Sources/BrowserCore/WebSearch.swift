import Foundation

public enum WebSearch {
    public struct Result: Sendable {
        public let url: URL
        public let title: String
        public let snippet: String

        public init(url: URL, title: String, snippet: String) {
            self.url = url
            self.title = title
            self.snippet = snippet
        }
    }

    public static func location(for query: String) -> URL? {
        guard let query = normalized(query) else { return nil }
        var parts = URLComponents(string: "browser:search")!
        parts.percentEncodedQuery = formData([URLQueryItem(name: "q", value: query)])
        return parts.url
    }

    public static func query(in location: URL) -> String? {
        guard let parts = URLComponents(url: location, resolvingAgainstBaseURL: false),
              parts.scheme == "browser", parts.host == nil, parts.path == "search", parts.fragment == nil,
              let items = parts.queryItems, items.count == 1, items[0].name == "q",
              let query = items[0].value else { return nil }
        return normalized(query)
    }

    private static func normalized(_ input: String) -> String? {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return !query.isEmpty && query.utf8.count <= 400 ? query : nil
    }

    static func request(for query: String, port: UInt16, token: String, safeSearch: Int) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/search")!, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-Browser-Search-Token")
        request.httpBody = Data(formData([
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "safesearch", value: String(safeSearch)),
            URLQueryItem(name: "language", value: "auto"),
        ]).utf8)
        return request
    }

    private static func formData(_ fields: [URLQueryItem]) -> String {
        var parts = URLComponents()
        parts.queryItems = fields
        // Form query parsers decode a bare plus sign as a space.
        return (parts.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
    }

    static func decode(_ data: Data) throws -> [Result] {
        struct Response: Decodable {
            struct Item: Decodable {
                let url: String?
                let title: String?
                let content: String?
            }
            let results: [Item]
            let unresponsive_engines: [[String]]?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        var results: [Result] = []
        var seen = Set<URL>()
        for item in response.results {
            guard let rawURL = item.url, rawURL.utf8.count <= 4096,
                  let parts = URLComponents(string: rawURL), let scheme = parts.scheme?.lowercased(),
                  ["https", "http"].contains(scheme), let host = parts.host, !host.isEmpty,
                  !host.contains(where: \.isWhitespace), parts.user == nil, parts.password == nil,
                  let url = parts.url, seen.insert(url).inserted else { continue }
            let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            results.append(Result(url: url, title: title.isEmpty ? host : String(title.prefix(250)),
                                  snippet: String((item.content ?? "").prefix(500))))
            if results.count == 15 { break }
        }
        if results.isEmpty, response.unresponsive_engines?.isEmpty == false {
            throw WebSearchError.sourcesUnavailable
        }
        return results
    }
}

public enum WebSearchError: Error {
    case sourcesUnavailable
}

public final class WebSearchClient {
    private let loader: PageLoader

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 12
        configuration.connectionProxyDictionary = [
            "HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
            "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0,
        ]
        configuration.httpAdditionalHeaders = ["Accept": "application/json"]
        loader = PageLoader(session: URLSession(configuration: configuration,
                                               delegate: SearchRedirectPolicy(), delegateQueue: nil))
    }

    public func search(_ query: String, port: UInt16, token: String, safeSearch: Int) async throws -> [WebSearch.Result] {
        let request = WebSearch.request(for: query, port: port, token: token, safeSearch: safeSearch)
        let data = try await loader.resource(request, maxBytes: 1_000_000)
        return try WebSearch.decode(data)
    }
}

private final class SearchRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
