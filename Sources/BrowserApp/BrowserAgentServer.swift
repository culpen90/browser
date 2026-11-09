import BrowserLLM
import CryptoKit
import Darwin
import Foundation
import Network

/// An explicitly enabled direct peer endpoint. Page text is authenticated and encrypted
/// before it enters HTTP, including when the paired devices share an open network.
@MainActor
final class BrowserAgentServer {
    typealias Generator = (URL, String, String, Int, QwenCommandFormat?) async throws -> String

    static let sharingPort: UInt16 = 38_765
    static let shared = BrowserAgentServer(persistentIdentity: true, listenPort: sharingPort, advertise: true,
                                           phonePresence: .shared)
    static let requestAAD = Data("BrowserAgent/v1 request".utf8)
    static let responseAAD = Data("BrowserAgent/v1 response".utf8)

    var onChange: (() -> Void)?
    /// Optional diagnostics for verifying the direct network path without logging request content.
    var onPeerAuthenticated: ((String, String) -> Void)?
    private(set) var isRunning = false
    private(set) var addresses: [String] = []
    private(set) var port: UInt16?
    private(set) var modelURL: URL?
    private(set) var status = "Model sharing is off."
    private(set) var deviceID = UUID().uuidString
    let deviceName = String(decoding: (Host.current().localizedName ?? "My Mac").utf8.prefix(160), as: UTF8.self)

    var pairingURI: URL? { pairingURIs.first }
    var pairingURIs: [URL] {
        guard isRunning, let port, let key else { return [] }
        return addresses.compactMap { pairingURI(host: $0, port: port, key: key) }
    }

    func pairingURI(host: String, port: UInt16) -> URL? {
        guard isRunning, let key else { return nil }
        return pairingURI(host: host, port: port, key: key)
    }

    private func pairingURI(host: String, port: UInt16, key: SymmetricKey) -> URL? {
        let encoded = key.withUnsafeBytes { Data($0) }.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var uri = URLComponents()
        uri.scheme = "browseragent"
        uri.host = "pair"
        uri.queryItems = [URLQueryItem(name: "host", value: host),
                              URLQueryItem(name: "port", value: String(port)),
                              URLQueryItem(name: "key", value: encoded),
                              URLQueryItem(name: "id", value: deviceID),
                              URLQueryItem(name: "name", value: deviceName)]
        return uri.url
    }

    private let generate: Generator
    private let discoverAddresses: @MainActor () -> [String]
    private let networkQueue = DispatchQueue(label: "BrowserAgent.ModelSharing")
    private var listener: NWListener?
    private var service: NetService?
    private let persistentIdentity: Bool
    private let listenPort: UInt16
    private let advertise: Bool
    private let identityStore: IdentityStore
    private let phonePresence: BrowserAgentPhonePresence
    private var sessionID = UUID()
    private var key: SymmetricKey?
    private var clients: [UUID: Client] = [:]
    private var seenNonces = Set<Data>()
    private var phoneNonces: [Data: Date] = [:]
    private var inference: (client: UUID, task: Task<Void, Never>)?
    private static let maximumBody = 32_768
    private static let maximumHeader = 8_192

    init(persistentIdentity: Bool = false, listenPort: UInt16 = 0, advertise: Bool = false,
         identityStore: IdentityStore = .keychain,
         phonePresence: BrowserAgentPhonePresence? = nil,
         discoverAddresses: @escaping @MainActor () -> [String] = { BrowserAgentServer.localAddresses() },
         generate: @escaping Generator = { url, system, user, tokens, format in
        try await BrowserAgentModel.shared.generate(at: url, system: system, user: user,
                                                   maxTokens: tokens, commandFormat: format)
    }) {
        self.discoverAddresses = discoverAddresses
        self.generate = generate
        self.persistentIdentity = persistentIdentity
        self.listenPort = listenPort
        self.advertise = advertise
        self.identityStore = identityStore
        self.phonePresence = phonePresence ?? BrowserAgentPhonePresence()
    }

    func start(modelURL: URL) throws {
        if self.modelURL == modelURL, listener != nil { return }
        stop()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: modelURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue, FileManager.default.isReadableFile(atPath: modelURL.path) else {
            throw BrowserAgentModel.ModelError.missing
        }
        let addresses = discoverAddresses()
        let storedIdentity: StoredIdentity
        if persistentIdentity, let data = try identityStore.load() {
            storedIdentity = try JSONDecoder().decode(StoredIdentity.self, from: data)
            guard storedIdentity.key.count == 32, UUID(uuidString: storedIdentity.id) != nil,
                  storedIdentity.nonces.count <= 10_000, storedIdentity.nonces.allSatisfy({ $0.count == 12 }) else {
                throw ServerError.invalidIdentity
            }
        } else {
            storedIdentity = StoredIdentity(id: deviceID, key: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }, nonces: [])
            if persistentIdentity {
                try identityStore.save(JSONEncoder().encode(storedIdentity))
            }
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: listenPort)!)
        self.listener = listener
        self.addresses = addresses
        self.modelURL = modelURL
        deviceID = storedIdentity.id
        key = SymmetricKey(data: storedIdentity.key)
        seenNonces = Set(storedIdentity.nonces)
        status = "Starting model sharing…"
        let identity = sessionID
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.listenerChanged(state, identity: identity) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, self.sessionID == identity else { connection.cancel(); return }
                self.accept(connection)
            }
        }
        listener.start(queue: networkQueue)
        onChange?()
    }

    func stop() {
        sessionID = UUID()
        listener?.cancel()
        listener = nil
        service?.stop()
        service = nil
        inference?.task.cancel()
        inference = nil
        for client in clients.values {
            client.timeout?.cancel()
            client.connection.cancel()
        }
        clients.removeAll()
        seenNonces.removeAll()
        phoneNonces.removeAll()
        phonePresence.removeAll()
        key = nil
        port = nil
        modelURL = nil
        addresses = []
        isRunning = false
        status = "Model sharing is off."
        onChange?()
    }

    /// Revoke all existing pairing links without changing the device's name.
    func resetPairing() throws {
        stop()
        try identityStore.remove()
        deviceID = UUID().uuidString
    }

    private func listenerChanged(_ state: NWListener.State, identity: UUID) {
        guard sessionID == identity else { return }
        switch state {
        case .ready:
            port = listener?.port?.rawValue
            isRunning = port != nil
            status = "Ready for direct encrypted connections."
            if advertise, let port {
                let service = NetService(domain: "local.", type: "_browseragent._tcp.", name: deviceID, port: Int32(port))
                service.setTXTRecord(NetService.data(fromTXTRecord: [
                    "id": Data(deviceID.utf8), "name": Data(deviceName.utf8)
                ]))
                self.service = service
                service.publish()
            }
            onChange?()
        case .failed:
            stop()
            status = "Model sharing could not start. Check that TCP port \(listenPort) is available."
            onChange?()
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard isRunning, clients.count < 8 else {
            connection.cancel()
            return
        }
        let client = Client(connection: connection)
        let id = client.id
        clients[client.id] = client
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in self?.close(id) }
            default:
                break
            }
        }
        client.timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(12)) }
            catch { return }
            self?.close(id)
        }
        connection.start(queue: networkQueue)
        receive(client)
    }

    private func receive(_ client: Client) {
        let id = client.id
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, let client = self.clients[id], !client.handling else { return }
                if let data { client.buffer.append(data) }
                guard error == nil, client.buffer.count <= Self.maximumHeader + Self.maximumBody else {
                    self.reject(client)
                    return
                }
                if !self.consume(client), self.clients[client.id] === client, !client.handling {
                    if complete { self.reject(client) }
                    else { self.receive(client) }
                }
            }
        }
    }

    /// Returns true once the request has been dispatched or rejected.
    private func consume(_ client: Client) -> Bool {
        if client.bodyStart == nil {
            guard let separator = client.buffer.range(of: Data([13, 10, 13, 10])) else {
                if client.buffer.count > Self.maximumHeader { reject(client); return true }
                return false
            }
            guard separator.upperBound <= Self.maximumHeader,
                  let header = String(data: client.buffer[..<separator.lowerBound], encoding: .ascii),
                  let parsed = Self.parseHeader(header) else { reject(client); return true }
            client.bodyStart = separator.upperBound
            client.bodyLength = parsed.length
            client.isPhoneHeartbeat = parsed.phone
        }
        let start = client.bodyStart!
        let length = client.bodyLength
        guard client.buffer.count >= start + length else { return false }
        guard client.buffer.count == start + length else { reject(client); return true }
        let body = Data(client.buffer[start...])
        client.buffer = Data()
        client.handling = true
        client.timeout?.cancel()
        handle(body, client: client)
        return true
    }

    private static func parseHeader(_ header: String) -> (length: Int, phone: Bool)? {
        let lines = header.components(separatedBy: "\r\n")
        guard lines.count <= 33, let first = lines.first,
              ["POST /v1/generate HTTP/1.1", "POST /v1/generate HTTP/1.0",
               "POST /v1/phone HTTP/1.1", "POST /v1/phone HTTP/1.0"].contains(first) else { return nil }
        var length: Int?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                  line.first != " ", line.first != "\t" else { return nil }
            let name = line[..<colon].lowercased()
            guard name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else {
                return nil
            }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "transfer-encoding" || name == "expect" { return nil }
            if name == "content-length" {
                guard length == nil, !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                      let count = Int(value), (28...maximumBody).contains(count) else { return nil }
                length = count
            }
        }
        return length.map { ($0, first.hasPrefix("POST /v1/phone ")) }
    }

    private func handle(_ body: Data, client: Client) {
        guard let key, let modelURL,
              let box = try? AES.GCM.SealedBox(combined: body),
              let plaintext = try? AES.GCM.open(box, using: key, authenticating: Self.requestAAD) else {
            reject(client)
            return
        }
        let nonce = Data(body.prefix(12))
        if client.isPhoneHeartbeat {
            do {
                let request = try JSONDecoder().decode(PhoneHeartbeat.self, from: plaintext)
                let now = Date()
                phoneNonces = phoneNonces.filter { now.timeIntervalSince($0.value) < 120 }
                guard abs(now.timeIntervalSince1970 - request.createdAt) <= 60,
                      phoneNonces.count < 4_096, phoneNonces[nonce] == nil else { reject(client); return }
                phoneNonces[nonce] = now
                let token = try phonePresence.heartbeat(id: request.id, name: request.name)
                onPeerAuthenticated?(client.remoteHost, "/v1/phone")
                respond(Response(attach: token), status: 200, client: client, key: key, requestNonce: nonce)
            } catch {
                respond(Response(error: "The phone identity is invalid."), status: 400,
                        client: client, key: key, requestNonce: nonce)
            }
            return
        }
        let request: Request
        do {
            request = try JSONDecoder().decode(Request.self, from: plaintext)
            try request.validate()
        } catch {
            respond(Response(error: "The phone sent an invalid model request."), status: 400,
                    client: client, key: key, requestNonce: nonce)
            return
        }
        guard seenNonces.count < 10_000 else {
            status = persistentIdentity ? "Pairing has reached its request limit. Reset Pairing and pair your devices again."
                : "This sharing session has reached its limit. Stop sharing and connect again."
            onChange?()
            reject(client)
            return
        }
        guard seenNonces.insert(nonce).inserted else {
            reject(client)
            return
        }
        if persistentIdentity {
            do {
                let stored = StoredIdentity(id: deviceID, key: key.withUnsafeBytes { Data($0) }, nonces: Array(seenNonces))
                try identityStore.save(JSONEncoder().encode(stored))
            } catch {
                reject(client)
                return
            }
        }
        onPeerAuthenticated?(client.remoteHost, "/v1/generate")
        guard inference == nil else {
            respond(Response(error: "The Mac is busy answering another request. Try again shortly."), status: 429,
                    client: client, key: key, requestNonce: nonce)
            return
        }
        let identity = sessionID
        let task = Task { [weak self] in
            guard let self else { return }
            let response: Response
            do {
                let format = request.format.map { QwenCommandFormat(exact: $0.exact, withText: $0.withText) }
                let text = try await generate(modelURL, request.system, request.user, min(request.maxTokens, 144), format)
                try Task.checkCancellation()
                response = Response(text: text)
            } catch {
                guard !Task.isCancelled else { return }
                response = Response(error: String(error.localizedDescription.prefix(1_024)))
            }
            guard sessionID == identity, clients[client.id] === client else { return }
            inference = nil
            respond(response, status: 200, client: client, key: key, requestNonce: nonce)
        }
        inference = (client.id, task)
        client.timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(120)) }
            catch { return }
            self?.close(client.id)
        }
    }

    private func respond(_ response: Response, status: Int, client: Client, key: SymmetricKey, requestNonce: Data) {
        do {
            let plaintext = try JSONEncoder().encode(response)
            guard plaintext.count + 28 <= Self.maximumBody else { throw ServerError.responseTooLarge }
            let box = try AES.GCM.seal(plaintext, using: key, authenticating: Self.responseAAD + requestNonce)
            guard let body = box.combined else { throw ServerError.responseTooLarge }
            send(body, status: status, client: client)
        } catch {
            reject(client)
        }
    }

    private func reject(_ client: Client) { send(Data(), status: 401, client: client) }

    private func send(_ body: Data, status: Int, client: Client) {
        guard clients[client.id] === client else { return }
        client.handling = true
        client.timeout?.cancel()
        let id = client.id
        client.timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            self?.close(id)
        }
        let phrase = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 429: "Too Many Requests"][status] ?? "OK"
        var message = Data("HTTP/1.1 \(status) \(phrase)\r\nContent-Type: application/octet-stream\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        message.append(body)
        client.connection.send(content: message, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close(id) }
        })
    }

    private func close(_ id: UUID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.timeout?.cancel()
        client.connection.cancel()
        if inference?.client == id {
            inference?.task.cancel()
            inference = nil
        }
    }

    private static func isPrivateIPv4(_ address: String) -> Bool {
        let bytes = address.split(separator: ".").compactMap { UInt8($0) }
        guard bytes.count == 4 else { return false }
        return bytes[0] == 10 || bytes[0] == 192 && bytes[1] == 168 ||
            bytes[0] == 172 && (16...31).contains(bytes[1])
    }

    private static func localAddresses() -> [String] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return [] }
        defer { freeifaddrs(interfaces) }
        var result: [(name: String, address: String)] = []
        var current = interfaces
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            let interface = entry.pointee
            guard let socket = interface.ifa_addr,
                  [UInt8(AF_INET), UInt8(AF_INET6)].contains(socket.pointee.sa_family),
                  interface.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(socket, socklen_t(socket.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0,
                              NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: buffer)
            // Global IPv6 addresses can be reached directly when the router's firewall permits it.
            // Link-local IPv6 needs an interface scope, so prefer IPv4 for nearby pairing.
            if isPrivateIPv4(address) || (socket.pointee.sa_family == UInt8(AF_INET6) &&
                (address.hasPrefix("2") || address.hasPrefix("3"))) {
                result.append((String(cString: interface.ifa_name), address))
            }
        }
        let ordered = result.sorted { $0.name == $1.name ? $0.address < $1.address : $0.name < $1.name }
        var seen = Set<String>()
        return ordered.map(\.address).filter { seen.insert($0).inserted }
    }

    private struct StoredIdentity: Codable {
        let id: String
        let key: Data
        let nonces: [Data]
    }

    struct IdentityStore {
        var load: () throws -> Data?
        var save: (Data) throws -> Void
        var remove: () throws -> Void

        static let keychain = IdentityStore(
            load: { try BrowserAgentSecrets.data(for: "sharing-identity-v1") },
            save: { try BrowserAgentSecrets.set($0, for: "sharing-identity-v1") },
            remove: { try BrowserAgentSecrets.remove("sharing-identity-v1") })
    }

    @MainActor
    private final class Client {
        let id = UUID()
        let connection: NWConnection
        var remoteHost: String {
            guard case .hostPort(let host, _) = connection.endpoint else { return "" }
            return host.debugDescription
        }
        var buffer = Data()
        var bodyStart: Int?
        var bodyLength = 0
        var handling = false
        var isPhoneHeartbeat = false
        var timeout: Task<Void, Never>?

        init(connection: NWConnection) { self.connection = connection }
    }

    private struct Request: Decodable {
        let system: String
        let user: String
        let maxTokens: Int
        let format: Format?

        struct Format: Decodable {
            let exact: [String]
            let withText: [String]
        }

        func validate() throws {
            guard maxTokens > 0, !user.isEmpty, system.utf8.count <= 6_000, user.utf8.count <= 10_000,
                  system.utf8.count + user.utf8.count <= 12_000 else { throw ServerError.invalidRequest }
            if let format {
                let commands = format.exact + format.withText
                guard format.exact.count <= 64, format.withText.count <= 32, !commands.isEmpty,
                      commands.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.contains(where: \.isNewline) }),
                      commands.reduce(0, { $0 + $1.utf8.count }) <= 4_096 else { throw ServerError.invalidRequest }
            }
        }
    }

    private struct Response: Encodable {
        var text: String?
        var error: String?
        var attach: String?
    }

    private struct PhoneHeartbeat: Decodable { let id: String; let name: String; let createdAt: Double }

    private enum ServerError: LocalizedError {
        case invalidIdentity, invalidRequest, responseTooLarge

        var errorDescription: String? {
            switch self {
            case .invalidIdentity: return "The saved pairing identity is invalid. Reset pairing and try again."
            case .invalidRequest: return "The model request is invalid."
            case .responseTooLarge: return "The model response was too large."
            }
        }
    }
}
