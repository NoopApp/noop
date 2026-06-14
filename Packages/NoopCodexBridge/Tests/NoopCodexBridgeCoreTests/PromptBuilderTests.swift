import XCTest
@testable import NoopCodexBridgeCore

final class PromptBuilderTests: XCTestCase {
    func testBridgeConfigurationStaysLoopbackOnly() {
        let configuration = BridgeConfiguration(environment: [
            "NOOP_CODEX_BRIDGE_HOST": "0.0.0.0",
            "NOOP_CODEX_BRIDGE_PORT": "8080",
            "NOOP_CODEX_BRIDGE_TOKEN": " local-secret ",
        ])

        XCTAssertEqual(configuration.host, "127.0.0.1")
        XCTAssertEqual(configuration.port, 8080)
        XCTAssertEqual(configuration.baseURL, "http://127.0.0.1:8080/v1")
        XCTAssertEqual(configuration.accessToken, "local-secret")
    }

    func testPromptIncludesCoachInstructionsAndConversation() throws {
        let json = """
        {
          "model": "codex-local",
          "messages": [
            {"role": "system", "content": "Use NOOP coaching rules."},
            {"role": "user", "content": "USER BIOMETRIC SUMMARY: charge 82"},
            {"role": "assistant", "content": "Good readiness."},
            {"role": "user", "content": "What should I do today?"}
          ]
        }
        """.data(using: .utf8)!

        let request = try JSONDecoder().decode(OpenAIChatRequest.self, from: json)
        let prompt = PromptBuilder.makePrompt(from: request)

        XCTAssertTrue(prompt.contains("Use NOOP coaching rules."))
        XCTAssertTrue(prompt.contains("USER BIOMETRIC SUMMARY: charge 82"))
        XCTAssertTrue(prompt.contains("What should I do today?"))
        XCTAssertTrue(prompt.contains("Do not run shell commands"))
        XCTAssertTrue(prompt.hasSuffix("Return only the assistant's next reply."))
    }
}
