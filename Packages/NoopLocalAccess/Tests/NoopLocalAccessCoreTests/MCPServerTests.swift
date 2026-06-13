import XCTest
@testable import NoopLocalAccessCore

final class MCPServerTests: XCTestCase {
    func testInitializeIncludesReadOnlyInstructionsForCodex() throws {
        let server = NoopMCPServer(configuration: LocalAccessConfiguration(databasePath: "/unused"))
        let response = try XCTUnwrap(try server.handle(RPCRequest(id: .int(1), method: "initialize", params: nil)))
        let result = try XCTUnwrap(response.objectValue?["result"]?.objectValue)

        XCTAssertEqual(result["protocolVersion"], .string(noopLocalAccessProtocolVersion))
        XCTAssertTrue(result["instructions"]?.stringValue?.contains("read-only") == true)
        XCTAssertTrue(result["instructions"]?.stringValue?.contains("do not diagnose") == true)
    }

    func testToolsAreAnnotatedReadOnly() throws {
        let tools = try XCTUnwrap(toolsList().objectValue?["tools"])
        guard case .array(let values) = tools else {
            return XCTFail("Expected tools array")
        }

        XCTAssertFalse(values.isEmpty)
        for tool in values {
            let annotations = try XCTUnwrap(tool.objectValue?["annotations"]?.objectValue)
            XCTAssertEqual(annotations["readOnlyHint"], .bool(true))
            XCTAssertEqual(annotations["openWorldHint"], .bool(false))
        }
    }

    func testMetricSeriesUsesComputedFallbackForMissingImportedDay() throws {
        let url = try TemporaryDatabase.seeded()
        let server = NoopMCPServer(configuration: LocalAccessConfiguration(databasePath: url.path))
        let response = try XCTUnwrap(try server.handle(RPCRequest(
            id: .int(2),
            method: "tools/call",
            params: .object([
                "name": .string("metric_series"),
                "arguments": .object([
                    "key": .string("hrv"),
                    "from_day": .string("2026-06-10"),
                    "to_day": .string("2026-06-11"),
                ]),
            ])
        )))

        let structured = try XCTUnwrap(response.objectValue?["result"]?.objectValue?["structuredContent"]?.objectValue)
        XCTAssertEqual(structured["returned"], .int(2))
        guard case .array(let points) = structured["points"] else {
            return XCTFail("Expected points array")
        }
        XCTAssertEqual(points.compactMap { $0.objectValue?["source"]?.stringValue }, ["my-whoop", "my-whoop-noop"])
    }
}
