import XCTest
@testable import Strand

final class CodexBridgeStateTests: XCTestCase {

    func testHealthDecodesBridgeMetadata() throws {
        let data = Data("""
        {
          "status": "ready",
          "transport": "codex-exec",
          "base_url": "http://127.0.0.1:37337/v1",
          "codex_cli": "/Applications/Codex.app/Contents/Resources/codex",
          "codex_version": "codex-cli 0.140.0-alpha.2",
          "model": "codex-config-default",
          "bridge_version": "1.0.0",
          "pid": 4242,
          "uptime_seconds": 12.5
        }
        """.utf8)

        let health = try CodexBridgeHealth.decode(data)

        XCTAssertTrue(health.isReady)
        XCTAssertEqual(health.baseURL, "http://127.0.0.1:37337/v1")
        XCTAssertEqual(health.codexCLI, "/Applications/Codex.app/Contents/Resources/codex")
        XCTAssertEqual(health.bridgeVersion, "1.0.0")
        XCTAssertEqual(health.pid, 4242)
        XCTAssertEqual(health.uptimeSeconds, 12.5)
    }

    func testRuntimeStateKeepsReachableButMissingCodexSeparateFromStopped() throws {
        let data = Data("""
        {
          "status": "missing",
          "transport": "codex-exec",
          "base_url": "http://127.0.0.1:37337/v1",
          "codex_cli": "/Applications/Codex.app/Contents/Resources/codex",
          "codex_version": "missing",
          "model": "codex-config-default"
        }
        """.utf8)

        let health = try CodexBridgeHealth.decode(data)
        let state = CodexBridgeRuntimeState.degraded(health)

        XCTAssertFalse(state.isReady)
        XCTAssertNotNil(state.health)
        XCTAssertEqual(state.title, "Needs Codex")
        XCTAssertTrue(state.detail.contains("Codex CLI is not executable"))
    }
}
