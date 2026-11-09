import CryptoKit
import Foundation

/// A phone accepts a computer's model connection. It never supplies model completions.
struct BrowserAgentPhone: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var host: String
    var port: UInt16
    let publicKey: Data

    static func parse(_ url: URL) throws -> Self {
        guard url.absoluteString.utf8.count <= 2_048,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "browseragent", parts.host?.lowercased() == "phone",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { throw PhoneError.invalidLink }
        var fields: [String: String] = [:]
        for item in parts.queryItems ?? [] {
            guard let value = item.value, fields[item.name] == nil,
                  ["host", "port", "id", "name", "pub"].contains(item.name) else { throw PhoneError.invalidLink }
            fields[item.name] = value
        }
        guard fields.count == 5, let host = fields["host"], BrowserAgentConnection.validHost(host),
              let portText = fields["port"], portText.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = UInt16(portText), port > 0,
              let idText = fields["id"], let id = UUID(uuidString: idText),
              let name = fields["name"], !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 200, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let encoded = fields["pub"], !encoded.isEmpty, encoded.count <= 256,
              encoded.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
                  (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { throw PhoneError.invalidLink }
        var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while !base64.count.isMultiple(of: 4) { base64 += "=" }
        guard let publicKey = Data(base64Encoded: base64),
              let parsedKey = try? P256.KeyAgreement.PublicKey(derRepresentation: publicKey),
              parsedKey.derRepresentation == publicKey else { throw PhoneError.invalidLink }
        return Self(id: id.uuidString.lowercased(), name: name, host: host, port: port, publicKey: publicKey)
    }

    var link: URL? {
        var uri = URLComponents()
        uri.scheme = "browseragent"
        uri.host = "phone"
        uri.queryItems = [URLQueryItem(name: "host", value: host), URLQueryItem(name: "port", value: String(port)),
                          URLQueryItem(name: "id", value: id), URLQueryItem(name: "name", value: name),
                          URLQueryItem(name: "pub", value: publicKey.base64EncodedString()
                            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                            .replacingOccurrences(of: "=", with: ""))]
        return uri.url
    }

    enum PhoneError: LocalizedError {
        case invalidLink, keyChanged, invalidResponse, unreachable, declined, tooMany
        var errorDescription: String? {
            switch self {
            case .invalidLink: return "Paste the complete phone link from Browser’s Receive Connection screen on your phone."
            case .keyChanged: return "This phone’s identity has changed. Forget its saved entry, then add its current phone link and compare the new code."
            case .invalidResponse: return "The phone’s connection response could not be verified."
            case .unreachable: return "Couldn’t reach the phone. Keep Browser’s Receive Connection screen open there and check its address."
            case .declined: return "The phone did not accept the connection. Try again when you’re ready."
            case .tooMany: return "Forget a saved phone before adding another. The limit is 32 phones."
            }
        }
    }
}

/// The offer contains identity only. The model credential is sent separately after code verification.
struct BrowserAgentPhoneConnection {
    static let domain = Data("BrowserAgent/phone-invite/v1".utf8)
    static let requestAAD = Data("BrowserAgent/phone-invite/v1 request".utf8)
    static let responseAAD = Data("BrowserAgent/phone-invite/v1 response".utf8)
    let phone: BrowserAgentPhone
    let senderPublicKey: Data
    let keyData: Data
    var verificationCode: String {
        let digest = Array(SHA256.hash(data: keyData + Data("verify".utf8)))
        let value = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        return String(format: "%06u", value)
    }

    init(phone: BrowserAgentPhone, senderKey: P256.KeyAgreement.PrivateKey) throws {
        let publicKey = try P256.KeyAgreement.PublicKey(derRepresentation: phone.publicKey)
        let secret = try senderKey.sharedSecretFromKeyAgreement(with: publicKey).withUnsafeBytes { Data($0) }
        self.phone = phone
        senderPublicKey = senderKey.publicKey.derRepresentation
        keyData = Data(SHA256.hash(data: Self.domain + secret + senderPublicKey + phone.publicKey))
    }

    static func stableSenderKey() throws -> P256.KeyAgreement.PrivateKey {
        if let raw = try BrowserAgentSecrets.data(for: "phone-invitation-key-v1") {
            return try P256.KeyAgreement.PrivateKey(rawRepresentation: raw)
        }
        let key = P256.KeyAgreement.PrivateKey()
        try BrowserAgentSecrets.set(key.rawRepresentation, for: "phone-invitation-key-v1")
        return key
    }

    struct Reply: Decodable { let accepted: Bool; let remembered: Bool? }
    struct Envelope: Codable { let publicKey: String; let data: String }

    func seal(_ object: [String: Any]) throws -> (body: Data, nonce: Data) {
        let plaintext = try JSONSerialization.data(withJSONObject: object)
        guard plaintext.count <= 8_192 else { throw BrowserAgentPhone.PhoneError.invalidResponse }
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: keyData), authenticating: Self.requestAAD)
        guard let combined = box.combined else { throw BrowserAgentPhone.PhoneError.invalidResponse }
        let body = try JSONEncoder().encode(Envelope(publicKey: senderPublicKey.base64EncodedString(), data: combined.base64EncodedString()))
        guard body.count <= 16_384 else { throw BrowserAgentPhone.PhoneError.invalidResponse }
        return (body, Data(combined.prefix(12)))
    }

    func open(_ data: Data, requestNonce: Data) throws -> Reply {
        guard data.count <= 16_384, requestNonce.count == 12,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              Data(base64Encoded: envelope.publicKey) == phone.publicKey,
              let combined = Data(base64Encoded: envelope.data), combined.count >= 28, combined.count <= 8_220,
              let box = try? AES.GCM.SealedBox(combined: combined),
              let plaintext = try? AES.GCM.open(box, using: SymmetricKey(data: keyData),
                                               authenticating: Self.responseAAD + requestNonce),
              let reply = try? JSONDecoder().decode(Reply.self, from: plaintext) else {
            throw BrowserAgentPhone.PhoneError.invalidResponse
        }
        return reply
    }

    @MainActor
    func offer(name: String, id: String) async throws -> Reply {
        try await post(path: "/v1/offer", object: ["name": name, "id": id,
                                                 "createdAt": Int64(Date().timeIntervalSince1970)])
    }

    @MainActor
    func connect(pairingLink: URL) async throws -> Reply {
        _ = try BrowserAgentConnection.parse(pairingLink)
        return try await post(path: "/v1/connect", object: ["pairingLink": pairingLink.absoluteString,
                                                           "createdAt": Int64(Date().timeIntervalSince1970)])
    }

    @MainActor
    private func post(path: String, object: [String: Any]) async throws -> Reply {
        try Task.checkCancellation()
        let requestBody = try seal(object)
        var endpoint = URLComponents()
        endpoint.scheme = "http"
        endpoint.host = phone.host.contains(":") ? "[\(phone.host)]" : phone.host
        endpoint.port = Int(phone.port)
        endpoint.path = path
        guard let url = endpoint.url else { throw BrowserAgentPhone.PhoneError.invalidLink }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = requestBody.body
        request.timeoutInterval = 100
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 100
        configuration.timeoutIntervalForResource = 105
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, [200, 400, 403].contains(http.statusCode),
                  response.expectedContentLength <= 16_384 else { throw BrowserAgentPhone.PhoneError.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 16_384 else { throw BrowserAgentPhone.PhoneError.invalidResponse }
                data.append(byte)
            }
            try Task.checkCancellation()
            return try open(data, requestNonce: requestBody.nonce)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw BrowserAgentPhone.PhoneError.unreachable
        }
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
}

@MainActor
final class BrowserAgentPhones {
    static let shared = BrowserAgentPhones()
    private(set) var saved: [BrowserAgentPhone] = []
    private(set) var loadError: Error?
    private static let storageName = "connected-phones-v1"

    private init() {
        do {
            if let data = try BrowserAgentSecrets.data(for: Self.storageName) {
                saved = try JSONDecoder().decode([BrowserAgentPhone].self, from: data)
                guard saved.count <= 32, Set(saved.map(\.id)).count == saved.count else {
                    throw BrowserAgentPhone.PhoneError.tooMany
                }
                for phone in saved {
                    guard let link = phone.link, try BrowserAgentPhone.parse(link) == phone else {
                        throw BrowserAgentPhone.PhoneError.invalidLink
                    }
                }
            }
        } catch { loadError = error }
    }

    func isTrusted(_ phone: BrowserAgentPhone) -> Bool {
        saved.contains { $0.id == phone.id && $0.publicKey == phone.publicKey }
    }

    func validatePin(_ phone: BrowserAgentPhone) throws {
        if let loadError { throw loadError }
        if let prior = saved.first(where: { $0.id == phone.id }), prior.publicKey != phone.publicKey {
            throw BrowserAgentPhone.PhoneError.keyChanged
        }
    }

    func remember(_ phone: BrowserAgentPhone) throws {
        try validatePin(phone)
        var next = saved
        if let index = next.firstIndex(where: { $0.id == phone.id }) {
            var remembered = phone
            // Preserve a manually saved internet route when this connection used Bonjour.
            if phone.host.lowercased().hasSuffix(".local.") || phone.host.lowercased().hasSuffix(".local") {
                remembered.host = next[index].host
                remembered.port = next[index].port
            }
            next[index] = remembered
        } else {
            guard next.count < 32 else { throw BrowserAgentPhone.PhoneError.tooMany }
            next.append(phone)
        }
        try BrowserAgentSecrets.set(JSONEncoder().encode(next), for: Self.storageName)
        saved = next
    }

    func forget(_ id: String) throws {
        if let loadError { throw loadError }
        let next = saved.filter { $0.id != id }
        try BrowserAgentSecrets.set(JSONEncoder().encode(next), for: Self.storageName)
        saved = next
    }
}
