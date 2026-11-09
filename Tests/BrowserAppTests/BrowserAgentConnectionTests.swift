import BrowserLLM
import CryptoKit
import Foundation
import Network
import XCTest
@testable import BrowserApp

final class BrowserAgentConnectionTests: XCTestCase {
    func testNamedPairingSupportsInternetAndIPv6AndRejectsAmbiguousLinks() throws {
        let identity = UUID().uuidString
        for host in ["198.51.100.7", "2001:db8::7", "model.example.com", "computer.local."] {
            let url = try link(host: host, id: identity, name: "Study Mac")
            let peer = try BrowserAgentConnection.parse(url)
            XCTAssertEqual(peer.host, host)
            XCTAssertEqual(peer.name, "Study Mac")
            XCTAssertEqual(peer.id, identity.lowercased())
            XCTAssertEqual(peer.key.count, 32)
            XCTAssertEqual(peer.port, 38_765)
        }
        let legacy = try link(host: "192.168.1.7")
        XCTAssertEqual(try BrowserAgentConnection.parse(legacy).id, try BrowserAgentConnection.parse(legacy).id)
        for host in ["0.0.0.0", "::", "ff02::1", "224.0.0.1", "999.0.0.1", "bad/host", "bad host", "a..example", "-bad.example"] {
            XCTAssertThrowsError(try BrowserAgentConnection.parse(link(host: host)))
        }
        for suffix in ["&host=attacker.example", "&key=bad", "&unknown=value", "#fragment"] {
            XCTAssertThrowsError(try BrowserAgentConnection.parse(XCTUnwrap(URL(string: legacy.absoluteString + suffix))))
        }
    }

    @MainActor
    func testRealEncryptedModelRequestsOverBothIPFamilies() async throws {
        for host in ["127.0.0.1", "::1"] {
            var calls = 0
            let server = BrowserAgentServer(discoverAddresses: { [host] }) { _, system, user, tokens, format in
                calls += 1
                XCTAssertEqual(system, "Read the page.")
                XCTAssertEqual(user, "Museum opens at 10 AM.")
                XCTAssertEqual(tokens, 80)
                XCTAssertEqual(format?.exactCommands, ["ANSWER", "CLICK 1"])
                XCTAssertEqual(format?.withTextCommands, ["SEARCH"])
                return "10 AM"
            }
            try server.start(modelURL: URL(fileURLWithPath: #filePath))
            defer { server.stop() }
            try await waitUntil { server.isRunning }
            let peer = try BrowserAgentConnection.parse(XCTUnwrap(server.pairingURI))
            let answer = try await peer.generate(system: "Read the page.", user: "Museum opens at 10 AM.",
                                                 maxTokens: 80, commandFormat: QwenCommandFormat(exact: ["ANSWER", "CLICK 1"], withText: ["SEARCH"]))
            XCTAssertEqual(answer, "10 AM")
            let unauthorized = BrowserAgentConnection(id: peer.id, name: peer.name, host: peer.host,
                                                       port: peer.port, key: Data(repeating: 9, count: 32))
            do {
                _ = try await unauthorized.generate(system: "Read", user: "Page", maxTokens: 80, commandFormat: nil)
                XCTFail("The client accepted the wrong pairing key.")
            } catch BrowserAgentConnection.ConnectionError.rejected { }
            XCTAssertEqual(calls, 1)
            server.stop()
        }
    }

    @MainActor
    func testClientRejectsReplayedResponseAndRedirect() async throws {
        let key = SymmetricKey(size: .bits256)
        var captured: Data?
        var redirects = false
        let fixture = try EncryptedFixture { request in
            if redirects { return (302, "Location: http://127.0.0.1:1/v1/generate\r\n", Data()) }
            if captured == nil {
                captured = try? AES.GCM.seal(Data(#"{"text":"Verified"}"#.utf8), using: key,
                                            authenticating: Data("BrowserAgent/v1 response".utf8) + request.prefix(12)).combined
            }
            return (200, "", captured ?? Data())
        }
        defer { fixture.stop() }
        try await waitUntil { fixture.port != nil }
        let peer = BrowserAgentConnection(id: UUID().uuidString, name: "Fixture", host: "127.0.0.1",
                                           port: try XCTUnwrap(fixture.port), key: key.withUnsafeBytes { Data($0) })
        let verified = try await peer.generate(system: "Read", user: "Page", maxTokens: 80, commandFormat: nil)
        XCTAssertEqual(verified, "Verified")
        do {
            _ = try await peer.generate(system: "Read", user: "Another page", maxTokens: 80, commandFormat: nil)
            XCTFail("A response bound to an earlier request was accepted.")
        } catch BrowserAgentConnection.ConnectionError.unverified { }
        redirects = true
        do {
            _ = try await peer.generate(system: "Read", user: "Page", maxTokens: 80, commandFormat: nil)
            XCTFail("The client followed a redirect.")
        } catch BrowserAgentConnection.ConnectionError.rejected { }
    }

    private func link(host: String, id: String? = nil, name: String? = nil) throws -> URL {
        var url = URLComponents()
        url.scheme = "browseragent"
        url.host = "pair"
        url.queryItems = [URLQueryItem(name: "host", value: host), URLQueryItem(name: "port", value: "38765"),
                          URLQueryItem(name: "key", value: Data(repeating: 3, count: 32).base64EncodedString()
                            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                            .replacingOccurrences(of: "=", with: ""))]
        if let id { url.queryItems?.append(URLQueryItem(name: "id", value: id)) }
        if let name { url.queryItems?.append(URLQueryItem(name: "name", value: name)) }
        return try XCTUnwrap(url.url)
    }

    @MainActor
    private func waitUntil(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !ready() {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    private final class EncryptedFixture {
        let listener: NWListener
        private var connections: [NWConnection] = []
        private let respond: (Data) -> (Int, String, Data)
        private var isReady = false
        var port: UInt16? { isReady ? listener.port?.rawValue : nil }

        init(respond: @escaping (Data) -> (Int, String, Data)) throws {
            self.respond = respond
            listener = try NWListener(using: .tcp, on: .any)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.isReady = state == .ready }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.connections.append(connection)
                    connection.start(queue: .global())
                    self?.receive(connection, buffer: Data())
                }
            }
            listener.start(queue: .global())
        }

        func stop() { listener.cancel(); for connection in connections { connection.cancel() } }

        private func receive(_ connection: NWConnection, buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, complete, error in
                Task { @MainActor in
                    guard let self, error == nil else { connection.cancel(); return }
                    var buffer = buffer
                    if let data { buffer.append(data) }
                    guard let boundary = buffer.range(of: Data("\r\n\r\n".utf8)),
                          let header = String(data: buffer[..<boundary.lowerBound], encoding: .utf8),
                          let line = header.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
                          let length = Int(line.split(separator: ":").last!.trimmingCharacters(in: .whitespaces)),
                          buffer.count >= boundary.upperBound + length else {
                        if complete { connection.cancel(); return }
                        self.receive(connection, buffer: buffer)
                        return
                    }
                    let body = Data(buffer[boundary.upperBound...])
                    let (status, headers, response) = self.respond(body)
                    var message = Data("HTTP/1.1 \(status) OK\r\nContent-Length: \(response.count)\r\n\(headers)Connection: close\r\n\r\n".utf8)
                    message.append(response)
                    connection.send(content: message, contentContext: .finalMessage, isComplete: true,
                                    completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
    }
}
