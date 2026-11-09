import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import BrowserApp

/// Opt-in reciprocal test: a computer discovers/receives a phone's invitation
/// address, delivers its model connection, then selects the authenticated phone.
final class BrowserAgentPhoneInboxFixtureTests: XCTestCase {
    @MainActor
    func testServePhoneInboxFixture() async throws {
        guard let path = ProcessInfo.processInfo.environment["BROWSER_TEST_PHONE_INBOX_FILE"] else {
            throw XCTSkip("Set BROWSER_TEST_PHONE_INBOX_FILE for the Mac-initiated Android connection fixture.")
        }
        let files = FileManager.default
        let phoneLink = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let phone = try BrowserAgentPhone.parse(XCTUnwrap(URL(string: phoneLink)))
        let presence = BrowserAgentPhonePresence()
        var generations = 0
        let server = BrowserAgentServer(phonePresence: presence, discoverAddresses: { ["10.0.2.2"] }) { url, system, user, tokens, format in
            generations += 1
            return try await BrowserAgentModel.shared.generate(at: url, system: system, user: user,
                                                               maxTokens: tokens, commandFormat: format)
        }
        try server.start(modelURL: BrowserAgentModel.defaultURL)
        defer {
            server.stop()
            for suffix in [".code", ".connected", ".attached"] { try? files.removeItem(atPath: path + suffix) }
        }
        let readyDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !server.isRunning {
            guard ContinuousClock.now < readyDeadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(20))
        }
        let connection = try BrowserAgentPhoneConnection(phone: phone, senderKey: P256.KeyAgreement.PrivateKey())
        try writePrivate(connection.verificationCode, to: path + ".code")
        let offer = try await connection.offer(name: "Mac Inbox Fixture", id: server.deviceID)
        XCTAssertTrue(offer.accepted, "The Android fixture must compare and accept the offer code.")
        guard offer.accepted else { return }
        let connected = try await connection.connect(pairingLink: XCTUnwrap(server.pairingURI))
        XCTAssertTrue(connected.accepted)
        guard connected.accepted else { return }
        try writePrivate("connected", to: path + ".connected")
        var attached = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(180))
        while !files.fileExists(atPath: path + ".done") {
            guard ContinuousClock.now < deadline else { XCTFail("Android inbox fixture timed out."); return }
            if !attached, files.fileExists(atPath: path + ".ready-to-attach"),
               presence.phones.contains(where: { $0.id == phone.id }) {
                try presence.attach(phone.id)
                try writePrivate("attached", to: path + ".attached")
                attached = true
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(attached, "The paired phone must authenticate and receive a computer-initiated attachment.")
        XCTAssertGreaterThan(generations, 0, "The phone must complete a request through the real Mac model.")
    }

    private func writePrivate(_ value: String, to path: String) throws {
        let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        try file.write(contentsOf: Data(value.utf8))
    }
}
