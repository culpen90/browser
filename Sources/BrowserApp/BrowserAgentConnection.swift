import BrowserLLM
import CryptoKit
import Foundation
import Network

/// A saved model provider. Pairing keys never enter page content or browser history.
struct BrowserAgentConnection: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var host: String
    var port: UInt16
    let key: Data
    private var fallback: Endpoint?
    private struct Endpoint: Equatable { let host: String; let port: UInt16 }
    private enum CodingKeys: String, CodingKey { case id, name, host, port, key }

    init(id: String, name: String, host: String, port: UInt16, key: Data) {
        self.id = id; self.name = name; self.host = host; self.port = port; self.key = key
    }

    func routed(to host: String, port: UInt16) -> Self {
        var route = self
        route.fallback = Endpoint(host: self.host, port: self.port)
        route.host = host
        route.port = port
        return route
    }

    static func parse(_ url: URL) throws -> Self {
        guard url.absoluteString.utf8.count <= 2_048,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "browseragent", parts.host?.lowercased() == "pair", parts.user == nil,
              parts.password == nil, parts.port == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { throw ConnectionError.invalidLink }
        var fields: [String: String] = [:]
        for item in parts.queryItems ?? [] {
            guard let value = item.value, fields[item.name] == nil,
                  ["host", "port", "key", "id", "name"].contains(item.name) else {
                throw ConnectionError.invalidLink
            }
            fields[item.name] = value
        }
        guard let host = fields["host"], validHost(host),
              let portText = fields["port"], portText.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = UInt16(portText), port > 0,
              let encoded = fields["key"], encoded.utf8.count == 43,
              encoded.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
                  (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              let key = Data(base64Encoded: encoded.replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/") + "="), key.count == 32 else {
            throw ConnectionError.invalidLink
        }
        let id: String
        if let rawID = fields["id"] {
            guard let uuid = UUID(uuidString: rawID) else { throw ConnectionError.invalidLink }
            id = uuid.uuidString.lowercased()
        } else {
            id = "legacy-" + SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
        }
        let name = fields["name"] ?? host
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 200, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ConnectionError.invalidLink
        }
        return Self(id: id, name: name, host: host, port: port, key: key)
    }

    static func validHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        if let address = IPv4Address(host) {
            let bytes = Array(address.rawValue)
            return bytes[0] > 0 && bytes[0] < 224 && bytes != [255, 255, 255, 255]
        }
        if let address = IPv6Address(host) {
            let bytes = Array(address.rawValue)
            return bytes[0] != 255 && bytes.contains(where: { $0 != 0 })
        }
        // Reject malformed numeric addresses instead of treating them as DNS names.
        if host.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) { return false }
        let domain = host.hasSuffix(".") ? String(host.dropLast()) : host
        return domain.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) ||
                (48...57).contains($0) || $0 == 45 }
        }
    }

    @MainActor
    func generate(system: String, user: String, maxTokens: Int, commandFormat: QwenCommandFormat?) async throws -> String {
        do { return try await send(system: system, user: user, maxTokens: maxTokens, commandFormat: commandFormat) }
        catch ConnectionError.unreachable where fallback != nil {
            // A nearby route can disappear when the device changes networks.
            var original = self
            original.host = fallback!.host
            original.port = fallback!.port
            original.fallback = nil
            return try await original.send(system: system, user: user, maxTokens: maxTokens, commandFormat: commandFormat)
        }
    }

    @MainActor
    private func send(system: String, user: String, maxTokens: Int, commandFormat: QwenCommandFormat?) async throws -> String {
        try Task.checkCancellation()
        var requestObject: [String: Any] = ["system": system, "user": user, "maxTokens": maxTokens]
        if let commandFormat {
            requestObject["format"] = ["exact": commandFormat.exactCommands, "withText": commandFormat.withTextCommands]
        }
        let plain = try JSONSerialization.data(withJSONObject: requestObject)
        guard plain.count + 28 <= 32_768 else { throw ConnectionError.tooLarge }
        let box = try AES.GCM.seal(plain, using: SymmetricKey(data: key), authenticating: BrowserAgentServer.requestAAD)
        guard let body = box.combined else { throw ConnectionError.invalidResponse }
        var endpoint = URLComponents()
        endpoint.scheme = "http"
        endpoint.host = host.contains(":") ? "[\(host)]" : host
        endpoint.port = Int(port)
        endpoint.path = "/v1/generate"
        guard let url = endpoint.url else { throw ConnectionError.invalidLink }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 135
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 135
        configuration.timeoutIntervalForResource = 140
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw ConnectionError.invalidResponse }
            guard [200, 400, 429, 500].contains(http.statusCode) else { throw ConnectionError.rejected }
            guard response.expectedContentLength <= 32_768 else { throw ConnectionError.tooLarge }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 32_768 else { throw ConnectionError.tooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            guard data.count >= 28,
                  let reply = try? AES.GCM.SealedBox(combined: data),
                  let plaintext = try? AES.GCM.open(reply, using: SymmetricKey(data: key),
                    authenticating: BrowserAgentServer.responseAAD + body.prefix(12)),
                  let result = try? JSONDecoder().decode(ModelResponse.self, from: plaintext) else {
                throw ConnectionError.unverified
            }
            if let error = result.error, result.text == nil { throw ConnectionError.provider(error) }
            guard http.statusCode == 200, let text = result.text, result.error == nil else {
                throw ConnectionError.invalidResponse
            }
            return text
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where [.cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost, .notConnectedToInternet].contains(error.code) {
            throw ConnectionError.unreachable(name)
        }
    }

    private struct ModelResponse: Decodable { let text: String?; let error: String? }
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

    enum ConnectionError: LocalizedError {
        case invalidLink, invalidResponse, tooLarge, rejected, unverified, unreachable(String), provider(String)
        var errorDescription: String? {
            switch self {
            case .invalidLink: return "Paste the complete pairing link from the other device’s Model Sharing window."
            case .invalidResponse: return "The selected device returned an invalid model response."
            case .tooLarge: return "The model request or response exceeds the connection’s size limit."
            case .rejected: return "The device rejected the connection. Add its current pairing link again."
            case .unverified: return "The model response could not be verified. Add the device’s pairing link again."
            case .unreachable(let name): return "Couldn’t reach \(name). Keep Browser and model sharing running there. For internet access, use a reachable address and allow the sharing port on its router."
            case .provider(let message): return String(message.prefix(1_024))
            }
        }
    }
}

extension Notification.Name {
    static let browserAgentDevicesDidChange = Notification.Name("BrowserAgentDevicesDidChange")
}

@MainActor
final class BrowserAgentDevices {
    static let shared = BrowserAgentDevices()
    private static let storageName = "paired-devices-v1"
    private struct State: Codable { var devices: [BrowserAgentConnection] = []; var selected: String? }
    private var state = State()
    private var nearbyRoutes: [String: (host: String, port: UInt16, expires: Date)] = [:]
    private(set) var loadError: Error?
    var devices: [BrowserAgentConnection] { state.devices }
    var selected: BrowserAgentConnection? { state.devices.first { $0.id == state.selected } }
    var effectiveSelected: BrowserAgentConnection? {
        guard let selected else { return nil }
        guard let route = nearbyRoutes[selected.id], route.expires > Date() else { return selected }
        return selected.routed(to: route.host, port: route.port)
    }

    private init() {
        do {
            if let data = try BrowserAgentSecrets.data(for: Self.storageName) {
                state = try JSONDecoder().decode(State.self, from: data)
                guard state.devices.count <= 32,
                      state.devices.allSatisfy({ BrowserAgentConnection.validHost($0.host) && $0.port > 0 && $0.key.count == 32 }) else {
                    throw BrowserAgentConnection.ConnectionError.invalidLink
                }
            }
        } catch { loadError = error }
    }

    func add(_ device: BrowserAgentConnection) throws {
        var next = state
        if let index = next.devices.firstIndex(where: { $0.id == device.id }) { next.devices[index] = device }
        else {
            guard next.devices.count < 32 else { throw DeviceError.full }
            next.devices.append(device)
        }
        next.selected = device.id
        try save(next)
    }

    func select(_ id: String?) throws {
        guard state.selected != id else { return }
        var next = state
        next.selected = id
        try save(next)
    }

    func remove(_ id: String) throws {
        var next = state
        next.devices.removeAll { $0.id == id }
        nearbyRoutes.removeValue(forKey: id)
        if next.selected == id { next.selected = nil }
        try save(next)
    }

    /// Nearby addresses are temporary hints; the saved internet address and key stay intact.
    func cacheNearbyRoute(id: String, host: String, port: UInt16) {
        guard BrowserAgentConnection.validHost(host), port > 0,
              state.devices.contains(where: { $0.id == id.lowercased() }) else { return }
        nearbyRoutes[id.lowercased()] = (host, port, Date().addingTimeInterval(60))
    }

    private func save(_ next: State) throws {
        if let loadError { throw loadError }
        try BrowserAgentSecrets.set(JSONEncoder().encode(next), for: Self.storageName)
        state = next
        NotificationCenter.default.post(name: .browserAgentDevicesDidChange, object: self)
    }

    enum DeviceError: LocalizedError {
        case full
        var errorDescription: String? { "Remove a saved device before adding another. The limit is 32 devices." }
    }
}
