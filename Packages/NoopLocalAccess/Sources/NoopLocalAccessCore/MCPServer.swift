import Foundation

public let noopLocalAccessServerName = "noop-local-access"
public let noopLocalAccessServerVersion = "0.1.0"
public let noopLocalAccessProtocolVersion = "2025-06-18"

public struct RPCRequest: Decodable, Equatable {
    public let id: JSONValue?
    public let method: String
    public let params: JSONValue?

    public init(id: JSONValue?, method: String, params: JSONValue?) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public final class NoopMCPServer {
    private let configuration: LocalAccessConfiguration
    private var dataAccess: NoopDataAccess?

    public init(configuration: LocalAccessConfiguration = .environment()) {
        self.configuration = configuration
    }

    public func handleLine(_ line: String) -> JSONValue {
        do {
            let request = try JSONDecoder().decode(RPCRequest.self, from: Data(line.utf8))
            return try handle(request) ?? .null
        } catch {
            return Self.errorResponse(id: .null, code: -32700, message: "Parse error: \(error)")
        }
    }

    public func handle(_ request: RPCRequest) throws -> JSONValue? {
        if request.id == nil, request.method.hasPrefix("notifications/") {
            return nil
        }
        guard let id = request.id else { return nil }

        do {
            let result = try result(for: request)
            return Self.response(id: id, result: result)
        } catch let error as LocalAccessError {
            return Self.errorResponse(id: id, code: error.rpcCode, message: error.description)
        } catch {
            return Self.errorResponse(id: id, code: -32603, message: "Internal error: \(error)")
        }
    }

    public static func response(id: JSONValue, result: JSONValue) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": result,
        ])
    }

    public static func errorResponse(id: JSONValue, code: Int, message: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object([
                "code": .int(code),
                "message": .string(message),
            ]),
        ])
    }

    private func result(for request: RPCRequest) throws -> JSONValue {
        switch request.method {
        case "initialize":
            return initializeResult()
        case "tools/list":
            return toolsList()
        case "tools/call":
            return try callTool(params: request.params)
        case "resources/list":
            return resourcesList()
        case "resources/read":
            return try readResource(params: request.params)
        case "resources/templates/list":
            return .object(["resourceTemplates": .array([])])
        case "prompts/list":
            return promptsList()
        case "prompts/get":
            return try getPrompt(params: request.params)
        case "ping":
            return .object([:])
        default:
            throw LocalAccessError.methodNotFound(request.method)
        }
    }

    private func initializeResult() -> JSONValue {
        .object([
            "protocolVersion": .string(noopLocalAccessProtocolVersion),
            "capabilities": .object([
                "tools": .object(["listChanged": .bool(false)]),
                "resources": .object(["listChanged": .bool(false)]),
                "prompts": .object(["listChanged": .bool(false)]),
            ]),
            "instructions": .string(Self.instructions),
            "serverInfo": .object([
                "name": .string(noopLocalAccessServerName),
                "version": .string(noopLocalAccessServerVersion),
            ]),
        ])
    }

    public static let instructions = """
    NOOP local access is read-only and returns personal health context from the user's on-device SQLite store. Use bounded tools, check data_freshness before stale-data claims, separate facts from inference, and do not diagnose medical conditions. No tool writes data or calls a network service.
    """

    private func data() throws -> NoopDataAccess {
        if let dataAccess { return dataAccess }
        do {
            let access = try NoopDataAccess.open(configuration: configuration)
            dataAccess = access
            return access
        } catch let error as LocalAccessError {
            throw error
        } catch {
            throw LocalAccessError.databaseUnavailable("NOOP database is not available: \(error)")
        }
    }

    private func callTool(params: JSONValue?) throws -> JSONValue {
        guard let object = params?.objectValue,
              let name = object["name"]?.stringValue
        else {
            throw LocalAccessError.invalidParams("tools/call requires a tool name")
        }
        let arguments = object["arguments"]?.objectValue ?? [:]
        let payload: JSONValue
        switch name {
        case "health_snapshot":
            payload = try data().healthSnapshot(days: boundedDays(arguments["days"], default: 14, max: 120))
        case "metric_series":
            guard let key = arguments["key"]?.stringValue else {
                throw LocalAccessError.invalidParams("metric_series requires key")
            }
            payload = try data().metricSeries(
                key: key,
                source: arguments["source"]?.stringValue ?? "my-whoop",
                days: boundedDays(arguments["days"], default: 90, max: 4000),
                fromDay: arguments["from_day"]?.stringValue,
                toDay: arguments["to_day"]?.stringValue,
                limit: boundedLimit(arguments["limit"], default: 500, max: 2000)
            )
        case "data_freshness":
            payload = try data().freshness()
        case "sleep_summary":
            payload = try data().sleepSummary(days: boundedDays(arguments["days"], default: 30, max: 4000))
        case "workout_summary":
            payload = try data().workoutSummary(days: boundedDays(arguments["days"], default: 90, max: 4000))
        default:
            throw LocalAccessError.toolNotFound(name)
        }
        return toolResult(payload)
    }

    private func readResource(params: JSONValue?) throws -> JSONValue {
        guard let uri = params?.objectValue?["uri"]?.stringValue else {
            throw LocalAccessError.invalidParams("resources/read requires uri")
        }
        let payload: JSONValue
        switch uri {
        case "noop://health/snapshot":
            payload = try data().healthSnapshot(days: 14)
        case "noop://data/freshness":
            payload = try data().freshness()
        case "noop://metrics/catalog":
            payload = NoopDataAccess.metricCatalog()
        case "noop://sources":
            payload = NoopDataAccess.sources()
        default:
            throw LocalAccessError.resourceNotFound(uri)
        }
        return .object([
            "contents": .array([
                .object([
                    "uri": .string(uri),
                    "mimeType": .string("application/json"),
                    "text": .string(prettyJSON(payload)),
                ]),
            ]),
        ])
    }

    private func getPrompt(params: JSONValue?) throws -> JSONValue {
        guard let name = params?.objectValue?["name"]?.stringValue else {
            throw LocalAccessError.invalidParams("prompts/get requires name")
        }

        let text: String
        let description: String
        switch name {
        case "weekly_health_review":
            description = "Review the last week of NOOP data"
            text = """
            Use the NOOP local access tools to review the last 7 days. Start with health_snapshot, then inspect any weak driver with metric_series. Separate facts, inferred patterns, and uncertainty. Do not diagnose medical conditions.
            """
        case "debug_data_freshness":
            description = "Find why a NOOP screen looks stale"
            text = """
            Use data_freshness, then compare health_snapshot with metric_series for the affected metric. Identify whether the issue is source freshness, import coverage, computed-source fallback, or a UI read-model problem.
            """
        case "explain_recovery":
            description = "Explain recovery drivers from local NOOP data"
            text = """
            Use health_snapshot and metric_series for recovery, hrv, rhr, resp_rate, strain, and sleep_total_min. Explain what changed against recent baseline, what is only correlation, and what action is low-risk today.
            """
        default:
            throw LocalAccessError.promptNotFound(name)
        }

        return .object([
            "description": .string(description),
            "messages": .array([
                .object([
                    "role": .string("user"),
                    "content": .object([
                        "type": .string("text"),
                        "text": .string(text),
                    ]),
                ]),
            ]),
        ])
    }
}

public func toolsList() -> JSONValue {
    .object([
        "tools": .array([
            tool(
                name: "health_snapshot",
                title: "Health Snapshot",
                description: "Return a bounded recent NOOP health snapshot with merged WHOOP imported/computed daily metrics and freshness metadata.",
                properties: [
                    "days": integerProperty("Trailing days to include, default 14, max 120."),
                ]
            ),
            tool(
                name: "metric_series",
                title: "Metric Series",
                description: "Return one bounded metric series from WHOOP, NOOP computed, Apple Health, nutrition, or mood sources.",
                properties: [
                    "key": stringProperty("Metric key, such as recovery, hrv, rhr, resp_rate, spo2, strain, sleep_total_min, steps, or active_kcal."),
                    "source": stringProperty("Source id. Defaults to my-whoop and resolves my-whoop + my-whoop-noop + compatible Apple Health fill-ins."),
                    "days": integerProperty("Trailing days if from_day/to_day are not provided, default 90, max 4000."),
                    "from_day": stringProperty("Inclusive YYYY-MM-DD start day."),
                    "to_day": stringProperty("Inclusive YYYY-MM-DD end day."),
                    "limit": integerProperty("Maximum returned points, default 500, max 2000."),
                ],
                required: ["key"]
            ),
            tool(
                name: "data_freshness",
                title: "Data Freshness",
                description: "Report local NOOP source freshness, storage counts, available metric keys, and latest heart-rate sample timestamp.",
                properties: [:]
            ),
            tool(
                name: "sleep_summary",
                title: "Sleep Summary",
                description: "Return bounded sleep sessions and aggregate sleep duration/efficiency from local NOOP data.",
                properties: [
                    "days": integerProperty("Trailing days to include, default 30, max 4000."),
                ]
            ),
            tool(
                name: "workout_summary",
                title: "Workout Summary",
                description: "Return bounded workout rows and aggregate effort/calorie/duration summaries from local NOOP data.",
                properties: [
                    "days": integerProperty("Trailing days to include, default 90, max 4000."),
                ]
            ),
        ]),
    ])
}

public func resourcesList() -> JSONValue {
    .object([
        "resources": .array([
            resource("noop://health/snapshot", name: "health_snapshot", title: "NOOP Health Snapshot", description: "Recent merged daily metrics and freshness", mimeType: "application/json"),
            resource("noop://data/freshness", name: "data_freshness", title: "NOOP Data Freshness", description: "Source coverage and latest sample timestamps", mimeType: "application/json"),
            resource("noop://metrics/catalog", name: "metrics_catalog", title: "NOOP Metrics Catalog", description: "Supported metric keys and source ids", mimeType: "application/json"),
            resource("noop://sources", name: "sources", title: "NOOP Sources", description: "Canonical local source identifiers", mimeType: "application/json"),
        ]),
    ])
}

public func promptsList() -> JSONValue {
    .object([
        "prompts": .array([
            prompt("weekly_health_review", title: "Weekly Health Review", description: "Review the last week of NOOP data with uncertainty separated from facts."),
            prompt("debug_data_freshness", title: "Debug Data Freshness", description: "Diagnose why a NOOP screen or metric is stale."),
            prompt("explain_recovery", title: "Explain Recovery", description: "Explain recovery drivers using local metrics and recent baselines."),
        ]),
    ])
}

private func tool(
    name: String,
    title: String,
    description: String,
    properties: [String: JSONValue],
    required: [String] = []
) -> JSONValue {
    .object([
        "name": .string(name),
        "title": .string(title),
        "description": .string(description),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": .bool(false),
        ]),
        "annotations": .object([
            "readOnlyHint": .bool(true),
            "openWorldHint": .bool(false),
        ]),
    ])
}

private func resource(_ uri: String, name: String, title: String, description: String, mimeType: String) -> JSONValue {
    .object([
        "uri": .string(uri),
        "name": .string(name),
        "title": .string(title),
        "description": .string(description),
        "mimeType": .string(mimeType),
    ])
}

private func prompt(_ name: String, title: String, description: String) -> JSONValue {
    .object([
        "name": .string(name),
        "title": .string(title),
        "description": .string(description),
        "arguments": .array([]),
    ])
}

private func stringProperty(_ description: String) -> JSONValue {
    .object([
        "type": .string("string"),
        "description": .string(description),
    ])
}

private func integerProperty(_ description: String) -> JSONValue {
    .object([
        "type": .string("integer"),
        "description": .string(description),
    ])
}

private func toolResult(_ payload: JSONValue) -> JSONValue {
    .object([
        "content": .array([
            .object([
                "type": .string("text"),
                "text": .string(prettyJSON(payload)),
            ]),
        ]),
        "structuredContent": payload,
        "isError": .bool(false),
    ])
}
