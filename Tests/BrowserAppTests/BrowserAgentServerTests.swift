import CryptoKit
import Darwin
import Foundation
import Network
import XCTest
@testable import BrowserApp

final class BrowserAgentServerTests: XCTestCase {
    @MainActor
    func testEncryptedRequestRejectsWrongKeyAndReplay() async throws {
        var calls = 0
        let server = BrowserAgentServer(discoverAddresses: { ["127.0.0.1"] }) { _, system, user, tokens, format in
            calls += 1
            XCTAssertEqual(system, "Read the page.")
            XCTAssertEqual(user, "Museum opens at 10 AM.")
            XCTAssertEqual(tokens, 144)
            XCTAssertNotNil(format)
            return "10 AM"
        }
        try server.start(modelURL: URL(fileURLWithPath: #filePath))
        defer { server.stop() }
        try await waitUntilReady(server)
        let (url, key) = try pairing(server)
        let body = try request(using: key)

        let (encrypted, response) = try await post(body, to: url)
        XCTAssertEqual(response.statusCode, 200)
        let decoded = try decrypt(encrypted, using: key, request: body)
        XCTAssertEqual(decoded["text"], "10 AM")
        XCTAssertThrowsError(try decrypt(encrypted, using: key, request: Data(repeating: 0, count: 12)))

        let (replayed, replayResponse) = try await post(body, to: url)
        XCTAssertEqual(replayResponse.statusCode, 401)
        XCTAssertTrue(replayed.isEmpty)
        let badBody = try request(using: SymmetricKey(size: .bits256))
        let (unauthorized, wrongKeyResponse) = try await post(badBody, to: url)
        XCTAssertEqual(wrongKeyResponse.statusCode, 401)
        XCTAssertTrue(unauthorized.isEmpty)
        XCTAssertEqual(calls, 1)

        let oldKey = key.withUnsafeBytes { Data($0) }
        server.stop()
        try server.start(modelURL: URL(fileURLWithPath: #filePath))
        try await waitUntilReady(server)
        let (_, newKey) = try pairing(server)
        XCTAssertFalse(newKey.withUnsafeBytes { Data($0) } == oldKey)
    }

    @MainActor
    func testAuthorizedErrorsAndBackpressureStayEncrypted() async throws {
        var started = false
        var releaseInference: CheckedContinuation<Void, Never>?
        let server = BrowserAgentServer(discoverAddresses: { ["127.0.0.1"] }) { _, _, _, _, _ in
            try Task.checkCancellation()
            await withCheckedContinuation { continuation in
                releaseInference = continuation
                started = true
            }
            try Task.checkCancellation()
            return "Done"
        }
        try server.start(modelURL: URL(fileURLWithPath: #filePath))
        defer { server.stop() }
        try await waitUntilReady(server)
        let (url, key) = try pairing(server)
        let firstBody = try request(using: key)
        let first = Task { try await post(firstBody, to: url) }
        defer {
            releaseInference?.resume()
            releaseInference = nil
            first.cancel()
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !started {
            guard ContinuousClock.now < deadline else { XCTFail("The first request did not reach the model."); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        let secondBody = try request(using: key)
        let (encrypted, response) = try await post(secondBody, to: url)
        XCTAssertEqual(response.statusCode, 429)
        XCTAssertNotNil(try decrypt(encrypted, using: key, request: secondBody)["error"])
        releaseInference?.resume()
        releaseInference = nil
        _ = try await first.value

        let invalid = try XCTUnwrap(AES.GCM.seal(Data("{}".utf8), using: key,
                                              authenticating: Data("BrowserAgent/v1 request".utf8)).combined)
        let (invalidResponse, invalidStatus) = try await post(invalid, to: url)
        XCTAssertEqual(invalidStatus.statusCode, 400)
        XCTAssertNotNil(try decrypt(invalidResponse, using: key, request: invalid)["error"])

        let oversized = Data(repeating: 0, count: 32_769)
        let (rejected, oversizedResponse) = try await post(oversized, to: url)
        XCTAssertEqual(oversizedResponse.statusCode, 401)
        XCTAssertTrue(rejected.isEmpty)
    }

    /// A real Mac endpoint for the Android emulator's production client. The test
    /// coordinator reads a private pairing file and creates the matching .done file.
    @MainActor
    func testServePhoneFixture() async throws {
        guard let path = ProcessInfo.processInfo.environment["BROWSER_TEST_PHONE_PAIR_FILE"] else {
            throw XCTSkip("Set BROWSER_TEST_PHONE_PAIR_FILE to run the phone-to-Mac fixture.")
        }
        let server = BrowserAgentServer()
        try server.start(modelURL: BrowserAgentModel.defaultURL)
        defer { server.stop() }
        try await waitUntilReady(server)
        var uri = try XCTUnwrap(URLComponents(url: XCTUnwrap(server.pairingURI), resolvingAgainstBaseURL: false))
        uri.queryItems = uri.queryItems?.map {
            $0.name == "host" ? URLQueryItem(name: "host", value: "10.0.2.2") : $0
        }
        let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close(); try? FileManager.default.removeItem(atPath: path) }
        try file.write(contentsOf: Data(try XCTUnwrap(uri.string).utf8))
        let deadline = ContinuousClock.now.advanced(by: .seconds(300))
        while !FileManager.default.fileExists(atPath: path + ".done") {
            guard ContinuousClock.now < deadline else { XCTFail("Phone fixture timed out."); return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @MainActor
    private func waitUntilReady(_ server: BrowserAgentServer) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !server.isRunning {
            guard ContinuousClock.now < deadline else { XCTFail(server.status); throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor
    private func pairing(_ server: BrowserAgentServer) throws -> (URL, SymmetricKey) {
        let uri = try XCTUnwrap(server.pairingURI)
        let parts = try XCTUnwrap(URLComponents(url: uri, resolvingAgainstBaseURL: false))
        let query = parts.queryItems ?? []
        let port = try XCTUnwrap(query.first { $0.name == "port" }?.value)
        var encoded = try XCTUnwrap(query.first { $0.name == "key" }?.value)
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while !encoded.count.isMultiple(of: 4) { encoded += "=" }
        let key = SymmetricKey(data: try XCTUnwrap(Data(base64Encoded: encoded)))
        return (try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/v1/generate")), key)
    }

    private func request(using key: SymmetricKey) throws -> Data {
        let json = #"{"system":"Read the page.","user":"Museum opens at 10 AM.","maxTokens":200,"format":{"exact":["ANSWER"],"withText":[]}}"#
        return try XCTUnwrap(AES.GCM.seal(Data(json.utf8), using: key,
                                        authenticating: Data("BrowserAgent/v1 request".utf8)).combined)
    }

    private func post(_ body: Data, to url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        return (data, try XCTUnwrap(response as? HTTPURLResponse))
    }

    private func decrypt(_ response: Data, using key: SymmetricKey, request: Data) throws -> [String: String] {
        let box = try AES.GCM.SealedBox(combined: response)
        let plaintext = try AES.GCM.open(box, using: key,
                                         authenticating: Data("BrowserAgent/v1 response".utf8) + request.prefix(12))
        return try JSONDecoder().decode([String: String].self, from: plaintext)
    }
}
