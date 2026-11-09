import CryptoKit
import Foundation
import XCTest
@testable import BrowserApp

final class BrowserAgentPhonePresenceTests: XCTestCase {
    @MainActor
    func testPhoneCanBeSelectedOnlyWhileOnlineAndReceivesNewAttachToken() throws {
        var time = Date(timeIntervalSince1970: 1_000)
        let presence = BrowserAgentPhonePresence(now: { time })
        let id = UUID().uuidString
        XCTAssertNil(try presence.heartbeat(id: id, name: "My phone"))
        XCTAssertEqual(presence.phones.map(\.id), [id.lowercased()])
        try presence.attach(id.lowercased())
        let first = try XCTUnwrap(presence.heartbeat(id: id, name: "My phone"))
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertEqual(try presence.heartbeat(id: id, name: "My phone"), first)
        try presence.attach(id)
        let second = try XCTUnwrap(presence.heartbeat(id: id, name: "My phone"))
        XCTAssertNotEqual(first, second)
        time += 30
        XCTAssertTrue(presence.phones.isEmpty)
        XCTAssertThrowsError(try presence.attach(id))
        XCTAssertEqual(try presence.heartbeat(id: id, name: "My phone"), second)
        XCTAssertEqual(presence.phones.count, 1)
    }

    @MainActor
    func testPendingAttachmentExpiresAfterNinetySecondsAndCleanupRevokesIt() throws {
        var time = Date(timeIntervalSince1970: 1_000)
        let presence = BrowserAgentPhonePresence(now: { time })
        let id = UUID().uuidString
        _ = try presence.heartbeat(id: id, name: "Phone")
        try presence.attach(id)
        time += 89
        XCTAssertNotNil(try presence.heartbeat(id: id, name: "Phone"))
        time += 1
        XCTAssertNil(try presence.heartbeat(id: id, name: "Phone"))
        try presence.attach(id)
        presence.removeAll()
        XCTAssertTrue(presence.phones.isEmpty)
        XCTAssertThrowsError(try presence.attach(id))
        XCTAssertNil(try presence.heartbeat(id: id, name: "Phone"))
    }

    @MainActor
    func testHeartbeatValidatesIdentityAndNotifiesOnlyMeaningfulChanges() throws {
        let presence = BrowserAgentPhonePresence()
        var changes = 0
        presence.onChange = { changes += 1 }
        let id = UUID().uuidString
        _ = try presence.heartbeat(id: id, name: "Phone")
        _ = try presence.heartbeat(id: id.lowercased(), name: "Phone")
        XCTAssertEqual(changes, 1)
        _ = try presence.heartbeat(id: id, name: "Kitchen phone")
        XCTAssertEqual(changes, 2)
        try presence.attach(id)
        XCTAssertEqual(changes, 3)
        for name in ["", "   ", "Phone\nInjected", "Phone\u{0000}", "Phone\u{2028}Injected", String(repeating: "é", count: 101)] {
            XCTAssertThrowsError(try presence.heartbeat(id: id, name: name), name)
        }
        for badID in ["", "not-a-uuid", id + " ", " " + id] {
            XCTAssertThrowsError(try presence.heartbeat(id: badID, name: "Phone"))
            XCTAssertThrowsError(try presence.attach(badID))
        }
        XCTAssertEqual(changes, 3)
        presence.removeAll()
        XCTAssertEqual(changes, 4)
        presence.removeAll()
        XCTAssertEqual(changes, 4)
    }

    @MainActor
    func testPresenceRemainsBoundedAndExpiredPhonesMakeRoom() throws {
        var time = Date(timeIntervalSince1970: 1_000)
        let presence = BrowserAgentPhonePresence(now: { time })
        var ids: [String] = []
        for index in 0..<64 {
            let id = UUID().uuidString
            ids.append(id)
            _ = try presence.heartbeat(id: id, name: "Phone \(index)")
        }
        XCTAssertEqual(presence.phones.count, 64)
        let extra = UUID().uuidString
        XCTAssertThrowsError(try presence.heartbeat(id: extra, name: "Extra phone"))
        try presence.attach(ids[0])
        time += 30
        XCTAssertTrue(presence.phones.isEmpty)
        XCTAssertNil(try presence.heartbeat(id: extra, name: "Extra phone"))
        XCTAssertEqual(presence.phones.count, 1)
        XCTAssertNotNil(try presence.heartbeat(id: ids[0], name: "Returning phone"))
        XCTAssertEqual(presence.phones.count, 2)
    }

    @MainActor
    func testSwappingHeartbeatAndModelRoutesHasNoSideEffects() async throws {
        var stored: Data?
        var writes = 0
        var modelCalls = 0
        let store = BrowserAgentServer.IdentityStore(load: { stored }, save: { stored = $0; writes += 1 }, remove: { stored = nil })
        let presence = BrowserAgentPhonePresence()
        let server = BrowserAgentServer(persistentIdentity: true, identityStore: store, phonePresence: presence,
                                        discoverAddresses: { ["127.0.0.1"] }) { _, _, _, _, _ in
            modelCalls += 1
            return "Done"
        }
        defer { server.stop() }
        try server.start(modelURL: URL(fileURLWithPath: #filePath))
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !server.isRunning {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
        let link = try XCTUnwrap(server.pairingURI)
        let query = try XCTUnwrap(URLComponents(url: link, resolvingAgainstBaseURL: false)).queryItems ?? []
        var encoded = try XCTUnwrap(query.first { $0.name == "key" }?.value)
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while !encoded.count.isMultiple(of: 4) { encoded += "=" }
        let key = SymmetricKey(data: try XCTUnwrap(Data(base64Encoded: encoded)))
        func seal(_ object: [String: Any]) throws -> Data {
            try XCTUnwrap(AES.GCM.seal(JSONSerialization.data(withJSONObject: object), using: key,
                                      authenticating: BrowserAgentServer.requestAAD).combined)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        func post(_ body: Data, path: String) async throws -> Int {
            let port = try XCTUnwrap(server.port)
            let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/v1/\(path)"))
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let (_, response) = try await session.data(for: request)
            return try XCTUnwrap(response as? HTTPURLResponse).statusCode
        }
        let heartbeat = try seal(["id": UUID().uuidString, "name": "Phone", "createdAt": Date().timeIntervalSince1970])
        let wrongHeartbeatRoute = try await post(heartbeat, path: "generate")
        XCTAssertEqual(wrongHeartbeatRoute, 400)
        XCTAssertEqual(writes, 1, "A heartbeat sent to the wrong route must not consume persistent model replay state.")
        XCTAssertEqual(modelCalls, 0)
        XCTAssertTrue(presence.phones.isEmpty)
        let rightHeartbeatRoute = try await post(heartbeat, path: "phone")
        XCTAssertEqual(rightHeartbeatRoute, 200)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(presence.phones.count, 1)

        let generation = try seal(["system": "Answer briefly.", "user": "Hello", "maxTokens": 20])
        let wrongModelRoute = try await post(generation, path: "phone")
        XCTAssertEqual(wrongModelRoute, 400)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(modelCalls, 0)
        let rightModelRoute = try await post(generation, path: "generate")
        XCTAssertEqual(rightModelRoute, 200)
        XCTAssertEqual(writes, 2)
        XCTAssertEqual(modelCalls, 1)
        let repeatedModel = try await post(generation, path: "generate")
        XCTAssertEqual(repeatedModel, 401)
        XCTAssertEqual(writes, 2)
        XCTAssertEqual(modelCalls, 1)
    }

}
