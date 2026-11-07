import AppKit
import BrowserLLM
import Foundation
import XCTest
@testable import BrowserApp

final class LocalModelTests: XCTestCase {
    func testQwenReadsFixtureTextWithLocalWeights() throws {
        let model = try QwenModel(contentsOf: modelURL())
        let answer = try model.generate(
            system: "Answer using the information in the user's text. Keep your answer short.",
            user: "The museum opens at 10 AM. What time does the museum open?",
            maxNewTokens: 24
        )
        XCTAssertTrue(answer.uppercased().contains("10 AM"), "Generated: \(answer)")
    }

    @MainActor
    func testLocalAgentFollowsALinkAndAnswersFromTheDestination() async throws {
        let modelURL = try modelURL()
        let server = try CompatibilityFixtureServer()
        defer { server.stop() }
        _ = NSApplication.shared
        let browser = BrowserWindowController()
        defer { browser.close() }
        browser.window?.contentView?.layoutSubtreeIfNeeded()
        browser.navigate(server.url("/agent-live"))

        var actions: [String] = []
        let answer: String
        do {
            answer = try await BrowserAgentController(window: browser).run(
                "Use the Museum details link, then tell me when the museum opens.",
                modelURL: modelURL,
                onActivity: { actions.append($0) },
                approve: { message in
                    XCTFail("Unexpected approval: \(message)")
                    return false
                }
            )
        } catch {
            XCTFail("Agent failed at \(browser.currentURL.path) after \(actions): \(error)")
            return
        }

        XCTAssertEqual(browser.currentURL.path, "/agent-live-details", "Agent actions: \(actions)")
        XCTAssertTrue(actions.contains { $0.hasPrefix("Click") && $0.contains("Museum details") }, "Agent actions: \(actions)")
        XCTAssertNotNil(answer.range(of: #"10(?::00)?\s*a\.?m\.?"#, options: [.regularExpression, .caseInsensitive]),
                        "Generated: \(answer)")
    }

    private func modelURL() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["BROWSER_TEST_MODEL"], !path.isEmpty else {
            throw XCTSkip("Set BROWSER_TEST_MODEL to the official Qwen2.5-0.5B-Instruct Q4_0 GGUF to run inference.")
        }
        return URL(fileURLWithPath: path)
    }
}
