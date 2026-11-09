import Darwin
import Foundation
import Network
import XCTest
@testable import BrowserApp

/// Opt-in real-phone test. The Android coordinator binds the production client
/// to cellular data while ADB remains on Wi-Fi solely for test coordination.
final class BrowserAgentPhysicalInternetTests: XCTestCase {
    @MainActor
    func testPhysicalPhoneUsesMacModelOverInternet() async throws {
        guard let directoryPath = ProcessInfo.processInfo.environment["BROWSER_TEST_PHYSICAL_INTERNET_DIR"] else {
            throw XCTSkip("Set BROWSER_TEST_PHYSICAL_INTERNET_DIR for the physical-phone cellular internet fixture.")
        }
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        let pairingFile = directory.appendingPathComponent("pairing.txt")
        let evidenceFile = directory.appendingPathComponent("server-evidence.json")
        let attachedFile = directory.appendingPathComponent("attached")
        let readyFile = directory.appendingPathComponent("ready-to-attach")
        let doneFile = directory.appendingPathComponent("done")
        let expectedIDFile = directory.appendingPathComponent("expected-phone-id.txt")
        let presence = BrowserAgentPhonePresence()
        let router = BrowserAgentRouterMapping()
        var mapping: BrowserAgentRouterMapping.Mapping?
        var authenticated: [(ip: String, path: String, time: TimeInterval)] = []
        var modelCalls = 0
        var completedModelCalls = 0
        var modelReplies: [[String: Any]] = []
        var attachment: String?
        var outcome = "starting"
        var failure: String?
        var cleanupRequested = false
        var phoneProof: [String: Any]?

        func writeEvidence() throws {
            var evidence: [String: Any] = [
                "outcome": outcome,
                "authenticatedRemoteIPs": Array(Set(authenticated.map(\.ip))).sorted(),
                "authenticatedRequests": authenticated.map { ["ip": $0.ip, "path": $0.path, "time": $0.time] as [String: Any] },
                "modelCalls": modelCalls,
                "completedModelCalls": completedModelCalls,
                "modelReplies": modelReplies,
                "attachment": attachment as Any? ?? NSNull(),
                "portMappingCleanupRequested": cleanupRequested
            ]
            if let mapping { evidence["publicEndpoint"] = ["host": mapping.host, "port": Int(mapping.port)] }
            if let failure { evidence["failure"] = failure }
            if let phoneProof { evidence["phone"] = phoneProof }
            try Self.writePrivate(JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]),
                                  to: evidenceFile, exclusive: false)
        }

        let server = BrowserAgentServer(listenPort: BrowserAgentServer.sharingPort, phonePresence: presence) { url, system, user, tokens, format in
            modelCalls += 1
            let startedAt = Date().timeIntervalSince1970
            let diagnosticIndex: Int?
            if modelReplies.count < 32 {
                diagnosticIndex = modelReplies.count
                modelReplies.append([
                    "call": modelCalls,
                    "kind": format == nil ? "answer" : "command",
                    "maxTokens": tokens,
                    "exactCommands": format?.exactCommands ?? [],
                    "startedAt": startedAt,
                    "status": "running"
                ])
            } else { diagnosticIndex = nil }
            try? writeEvidence()
            do {
                let answer = try await BrowserAgentModel.shared.generate(at: url, system: system, user: user,
                                                                         maxTokens: tokens, commandFormat: format)
                completedModelCalls += 1
                if let diagnosticIndex {
                    // This opt-in test supplies controlled museum facts only. Do not retain
                    // request prompts or model credentials in its private diagnostic output.
                    let text = String(answer.prefix(1_024)).replacingOccurrences(
                        of: #"(?i)browseragent://[^\s]+"#, with: "[pairing link redacted]", options: .regularExpression)
                    modelReplies[diagnosticIndex]["text"] = text
                    modelReplies[diagnosticIndex]["status"] = "completed"
                    modelReplies[diagnosticIndex]["elapsedSeconds"] = Date().timeIntervalSince1970 - startedAt
                }
                try? writeEvidence()
                return answer
            } catch {
                if let diagnosticIndex {
                    modelReplies[diagnosticIndex]["status"] = "failed"
                    modelReplies[diagnosticIndex]["errorType"] = String(describing: type(of: error))
                    modelReplies[diagnosticIndex]["elapsedSeconds"] = Date().timeIntervalSince1970 - startedAt
                }
                try? writeEvidence()
                throw error
            }
        }
        server.onPeerAuthenticated = { address, path in
            if authenticated.count < 512 {
                authenticated.append((Self.normalizedAddress(address), path, Date().timeIntervalSince1970))
            }
            try? writeEvidence()
        }

        do {
            try server.start(modelURL: BrowserAgentModel.defaultURL)
            let readyDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !server.isRunning {
                guard ContinuousClock.now < readyDeadline else { throw FixtureError.listenerTimeout }
                try await Task.sleep(for: .milliseconds(20))
            }
            mapping = try await router.open(port: BrowserAgentServer.sharingPort, localAddresses: server.addresses)
            let endpoint = try XCTUnwrap(mapping)
            guard Self.isPublicAddress(endpoint.host) else { throw FixtureError.nonpublicEndpoint }
            let pairingURI = try XCTUnwrap(server.pairingURI(host: endpoint.host, port: endpoint.port))
            try Self.writePrivate(Data(pairingURI.absoluteString.utf8), to: pairingFile, exclusive: true)
            outcome = "waiting-for-cellular-phone"
            try writeEvidence()

            let deadline = ContinuousClock.now.advanced(by: .seconds(300))
            while !files.fileExists(atPath: doneFile.path) {
                try Task.checkCancellation()
                if files.fileExists(atPath: directory.appendingPathComponent("abort").path) {
                    throw FixtureError.coordinatorAborted
                }
                guard ContinuousClock.now < deadline else { throw FixtureError.phoneTimeout }
                if attachment == nil, files.fileExists(atPath: readyFile.path) {
                    guard files.fileExists(atPath: expectedIDFile.path) else { throw FixtureError.invalidPhoneEvidence }
                    let raw = try String(contentsOf: expectedIDFile, encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let id = UUID(uuidString: raw) else { throw FixtureError.invalidPhoneEvidence }
                    let expectedID = id.uuidString.lowercased()
                    if let phone = presence.phones.first(where: { $0.id == expectedID }) {
                        try presence.attach(phone.id)
                        attachment = phone.id
                        outcome = "attachment-requested"
                        try Self.writePrivate(Data(phone.id.utf8), to: attachedFile, exclusive: true)
                        try writeEvidence()
                    }
                }
                try await Task.sleep(for: .milliseconds(100))
            }

            let phoneEvidence = try JSONSerialization.jsonObject(with: Data(contentsOf: doneFile)) as? [String: Any]
            guard let phoneEvidence, phoneEvidence["success"] as? Bool == true,
                  phoneEvidence["cellular"] as? Bool == true, phoneEvidence["wifi"] as? Bool == false,
                  phoneEvidence["modelAnswered"] as? Bool == true, phoneEvidence["attached"] as? Bool == true,
                  (phoneEvidence["phoneID"] as? String)?.lowercased() == attachment?.lowercased(),
                  (phoneEvidence["computerID"] as? String)?.lowercased() == server.deviceID.lowercased(),
                  phoneEvidence["publicHost"] as? String == endpoint.host,
                  phoneEvidence["publicPort"] as? Int == Int(endpoint.port),
                  phoneEvidence["navigatedPath"] as? String == "/hours" else {
                throw FixtureError.invalidPhoneEvidence
            }
            let proofFields = Set(["success", "cellular", "wifi", "modelAnswered", "attached", "phoneID",
                                   "computerID", "model", "sdk", "networkHandle", "interface", "publicHost",
                                   "publicPort", "navigatedPath"])
            phoneProof = phoneEvidence.filter { proofFields.contains($0.key) }
            XCTAssertGreaterThan(modelCalls, 0, "The physical phone must call the real model.")
            XCTAssertGreaterThan(completedModelCalls, 0, "The real model must complete a request.")
            XCTAssertNotNil(attachment, "The Mac must select the authenticated physical phone.")
            let publicModelRequests = authenticated.filter { $0.path == "/v1/generate" && Self.isWANPeer($0.ip, endpoint: endpoint.host) }
            let publicHeartbeats = authenticated.filter { $0.path == "/v1/phone" && Self.isWANPeer($0.ip, endpoint: endpoint.host) }
            XCTAssertFalse(publicModelRequests.isEmpty, "The model request must arrive from a public remote address, excluding this router's WAN address and LAN/loopback routes.")
            XCTAssertFalse(publicHeartbeats.isEmpty, "The physical phone's authenticated heartbeat must cross the internet.")
            XCTAssertTrue(authenticated.allSatisfy { Self.isWANPeer($0.ip, endpoint: endpoint.host) },
                          "This fixture accepts evidence only from an internet peer, excluding router hairpinning.")
            outcome = modelCalls > 0 && completedModelCalls > 0 && attachment != nil &&
                !publicModelRequests.isEmpty && !publicHeartbeats.isEmpty &&
                authenticated.allSatisfy({ Self.isWANPeer($0.ip, endpoint: endpoint.host) }) ? "passed" : "failed"
            server.stop()
            cleanupRequested = true
            await Task { @MainActor in await router.close() }.value
            try? files.removeItem(at: pairingFile)
            try writeEvidence()
        } catch {
            outcome = "failed"
            // Connection/cryptography errors can include endpoint context; never record a pairing link.
            failure = error is FixtureError ? String(describing: error) : String(describing: type(of: error))
            server.stop()
            cleanupRequested = true
            await Task { @MainActor in await router.close() }.value
            try? files.removeItem(at: pairingFile)
            try? writeEvidence()
            throw error
        }
    }

    private static func normalizedAddress(_ address: String) -> String {
        let trimmed = address.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard let ipv6 = IPv6Address(trimmed) else { return trimmed }
        let bytes = Array(ipv6.rawValue)
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 {
            return bytes.suffix(4).map(String.init).joined(separator: ".")
        }
        return ipv6.debugDescription
    }

    private static func isWANPeer(_ address: String, endpoint: String) -> Bool {
        let normalized = normalizedAddress(address)
        return normalized != normalizedAddress(endpoint) && isPublicAddress(normalized)
    }

    private static func isPublicAddress(_ address: String) -> Bool {
        if let ipv4 = IPv4Address(address) {
            let bytes = Array(ipv4.rawValue)
            if bytes[0] == 0 || bytes[0] == 10 || bytes[0] == 127 || bytes[0] >= 224 { return false }
            if bytes[0] == 100 && (64...127).contains(bytes[1]) { return false }
            if bytes[0] == 169 && bytes[1] == 254 { return false }
            if bytes[0] == 172 && (16...31).contains(bytes[1]) { return false }
            if bytes[0] == 192 && (bytes[1] == 168 || bytes[1] == 0) { return false }
            if bytes[0] == 198 && (bytes[1] == 18 || bytes[1] == 19 || bytes[1] == 51 && bytes[2] == 100) { return false }
            if bytes[0] == 203 && bytes[1] == 0 && bytes[2] == 113 { return false }
            return true
        }
        guard let ipv6 = IPv6Address(address) else { return false }
        let bytes = Array(ipv6.rawValue)
        // Global unicast only. Local, unique-local, mapped, and multicast addresses do not prove WAN transit.
        guard bytes[0] & 0xe0 == 0x20 else { return false }
        if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8 { return false }
        return true
    }

    private static func writePrivate(_ data: Data, to url: URL, exclusive: Bool) throws {
        if !exclusive {
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".evidence-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try writePrivate(data, to: temporary, exclusive: true)
            guard Darwin.rename(temporary.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return
        }
        let flags = O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW | (exclusive ? O_EXCL : O_TRUNC)
        let descriptor = Darwin.open(url.path, flags, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        try file.write(contentsOf: data)
    }

    private enum FixtureError: Error {
        case listenerTimeout, nonpublicEndpoint, phoneTimeout, invalidPhoneEvidence, coordinatorAborted
    }
}
