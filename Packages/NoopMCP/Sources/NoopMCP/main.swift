import Foundation
import WhoopStore

private let serverName = "noop-mcp"
private let serverVersion = "0.1.0"
private let protocolVersion = "2025-06-18"

// MARK: - JSON-RPC substrate

private enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let values):
            try container.encode(values)
        case .object(let value):
            try container.encode(value)
        }
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        switch self {
        case .int(let value):
            return value
        case .double(let value):
            return Int(value)
        case .string(let value):
            return Int(value)
        default:
            return nil
        }
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }
}

private struct RPCRequest: Decodable {
    let id: JSONValue?
    let method: String
    let params: JSONValue?
}

private enum MCPError: Error, CustomStringConvertible {
    case invalidParams(String)
    case methodNotFound(String)
    case toolNotFound(String)
    case resourceNotFound(String)
    case promptNotFound(String)
    case databaseUnavailable(String)

    var description: String {
        switch self {
        case .invalidParams(let message):
            return message
        case .methodNotFound(let method):
            return "Unsupported MCP method: \(method)"
        case .toolNotFound(let tool):
            return "Unknown NOOP tool: \(tool)"
        case .resourceNotFound(let uri):
            return "Unknown NOOP resource: \(uri)"
        case .promptNotFound(let name):
            return "Unknown NOOP prompt: \(name)"
        case .databaseUnavailable(let message):
            return message
        }
    }

    var code: Int {
        switch self {
        case .methodNotFound:
            return -32601
        case .invalidParams, .toolNotFound, .resourceNotFound, .promptNotFound:
            return -32602
        case .databaseUnavailable:
            return -32603
        }
    }
}

@main
private enum NoopMCPMain {
    static func main() async {
        let server = NoopMCPServer()
        let decoder = JSONDecoder()

        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            do {
                let request = try decoder.decode(RPCRequest.self, from: Data(trimmed.utf8))
                if let response = await server.handle(request) {
                    write(response)
                }
            } catch {
                write(Self.errorResponse(id: .null, code: -32700, message: "Parse error: \(error)"))
            }
        }
    }

    private static func write(_ value: JSONValue) {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(value)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            fputs("[noop-mcp] failed to encode response: \(error)\n", stderr)
        }
    }

    static func response(id: JSONValue, result: JSONValue) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": result,
        ])
    }

    static func errorResponse(id: JSONValue, code: Int, message: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object([
                "code": .int(code),
                "message": .string(message),
            ]),
        ])
    }
}

// MARK: - MCP methods

private final class NoopMCPServer {
    private var dataAccess: NoopDataAccess?

    func handle(_ request: RPCRequest) async -> JSONValue? {
        if request.id == nil, request.method.hasPrefix("notifications/") {
            return nil
        }
        guard let id = request.id else { return nil }

        do {
            let result = try await result(for: request)
            return NoopMCPMain.response(id: id, result: result)
        } catch let error as MCPError {
            return NoopMCPMain.errorResponse(id: id, code: error.code, message: error.description)
        } catch {
            return NoopMCPMain.errorResponse(id: id, code: -32603, message: "Internal error: \(error)")
        }
    }

    private func result(for request: RPCRequest) async throws -> JSONValue {
        switch request.method {
        case "initialize":
            return initializeResult()
        case "tools/list":
            return toolsList()
        case "tools/call":
            return try await callTool(params: request.params)
        case "resources/list":
            return resourcesList()
        case "resources/read":
            return try await readResource(params: request.params)
        case "resources/templates/list":
            return .object(["resourceTemplates": .array([])])
        case "prompts/list":
            return promptsList()
        case "prompts/get":
            return try getPrompt(params: request.params)
        case "ping":
            return .object([:])
        default:
            throw MCPError.methodNotFound(request.method)
        }
    }

    private func initializeResult() -> JSONValue {
        .object([
            "protocolVersion": .string(protocolVersion),
            "capabilities": .object([
                "tools": .object(["listChanged": .bool(false)]),
                "resources": .object(["listChanged": .bool(false)]),
                "prompts": .object(["listChanged": .bool(false)]),
            ]),
            "serverInfo": .object([
                "name": .string(serverName),
                "version": .string(serverVersion),
            ]),
        ])
    }

    private func data() async throws -> NoopDataAccess {
        if let dataAccess { return dataAccess }
        do {
            let access = try await NoopDataAccess.open()
            dataAccess = access
            return access
        } catch {
            throw MCPError.databaseUnavailable("NOOP database is not available: \(error)")
        }
    }

    private func callTool(params: JSONValue?) async throws -> JSONValue {
        guard let object = params?.objectValue,
              let name = object["name"]?.stringValue
        else {
            throw MCPError.invalidParams("tools/call requires a tool name")
        }
        let arguments = object["arguments"]?.objectValue ?? [:]
        let payload: JSONValue
        switch name {
        case "health_snapshot":
            payload = try await data().healthSnapshot(days: boundedDays(arguments["days"], default: 14, max: 120))
        case "metric_series":
            guard let key = arguments["key"]?.stringValue else {
                throw MCPError.invalidParams("metric_series requires key")
            }
            payload = try await data().metricSeries(
                key: key,
                source: arguments["source"]?.stringValue ?? "my-whoop",
                days: boundedDays(arguments["days"], default: 90, max: 4000),
                fromDay: arguments["from_day"]?.stringValue,
                toDay: arguments["to_day"]?.stringValue,
                limit: boundedLimit(arguments["limit"], default: 500, max: 2000)
            )
        case "data_freshness":
            payload = try await data().freshness()
        case "sleep_summary":
            payload = try await data().sleepSummary(days: boundedDays(arguments["days"], default: 30, max: 4000))
        case "workout_summary":
            payload = try await data().workoutSummary(days: boundedDays(arguments["days"], default: 90, max: 4000))
        default:
            throw MCPError.toolNotFound(name)
        }
        return toolResult(payload)
    }

    private func readResource(params: JSONValue?) async throws -> JSONValue {
        guard let uri = params?.objectValue?["uri"]?.stringValue else {
            throw MCPError.invalidParams("resources/read requires uri")
        }
        let payload: JSONValue
        switch uri {
        case "noop://health/snapshot":
            payload = try await data().healthSnapshot(days: 14)
        case "noop://data/freshness":
            payload = try await data().freshness()
        case "noop://metrics/catalog":
            payload = NoopDataAccess.metricCatalog()
        case "noop://sources":
            payload = NoopDataAccess.sources()
        default:
            throw MCPError.resourceNotFound(uri)
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
            throw MCPError.invalidParams("prompts/get requires name")
        }

        let text: String
        let description: String
        switch name {
        case "weekly_health_review":
            description = "Review the last week of NOOP health data"
            text = """
            Use the NOOP MCP tools to review the last 7 days. Start with health_snapshot, then inspect any weak driver with metric_series. Separate facts, inferred patterns, and uncertainty. Do not diagnose medical conditions.
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
            throw MCPError.promptNotFound(name)
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

// MARK: - Tool/resource manifests

private func toolsList() -> JSONValue {
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

private func resourcesList() -> JSONValue {
    .object([
        "resources": .array([
            resource("noop://health/snapshot", name: "health_snapshot", title: "NOOP Health Snapshot", description: "Recent merged daily metrics and freshness", mimeType: "application/json"),
            resource("noop://data/freshness", name: "data_freshness", title: "NOOP Data Freshness", description: "Source coverage and latest sample timestamps", mimeType: "application/json"),
            resource("noop://metrics/catalog", name: "metrics_catalog", title: "NOOP Metrics Catalog", description: "Supported metric keys and source ids", mimeType: "application/json"),
            resource("noop://sources", name: "sources", title: "NOOP Sources", description: "Canonical local source identifiers", mimeType: "application/json"),
        ]),
    ])
}

private func promptsList() -> JSONValue {
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

// MARK: - NOOP data access

private final class NoopDataAccess {
    private let store: WhoopStore
    private let deviceId: String
    private var computedDeviceId: String { deviceId + "-noop" }

    private init(store: WhoopStore, deviceId: String) {
        self.store = store
        self.deviceId = deviceId
    }

    static func open() async throws -> NoopDataAccess {
        let env = ProcessInfo.processInfo.environment
        let path = try DatabasePathResolver.resolve(env: env)
        let store = try await WhoopStore(path: path)
        let deviceId = env["NOOP_DEVICE_ID"].flatMap { $0.isEmpty ? nil : $0 } ?? "my-whoop"
        return NoopDataAccess(store: store, deviceId: deviceId)
    }

    func healthSnapshot(days: Int) async throws -> JSONValue {
        let (fromDay, toDay) = dayRange(days: days)
        let daily = try await mergedDaily(from: fromDay, to: toDay)
        let apple = try await store.appleDaily(deviceId: "apple-health", from: fromDay, to: toDay)
        let latestHR = try await store.latestHRSampleTs(deviceId: deviceId)

        let logical = logicalDayKey(Date())
        let displayed = daily.last(where: { $0.row.day == logical }) ?? daily.last

        return .object([
            "generatedAt": .string(iso(Date())),
            "logicalToday": .string(logical),
            "sources": Self.sources(),
            "freshness": freshnessPayload(latestHR: latestHR, apple: apple, daily: daily),
            "today": displayed.map { dailyJSON($0.row, source: $0.source) } ?? .null,
            "recentDays": .array(daily.suffix(days).map { dailyJSON($0.row, source: $0.source) }),
            "appleDaily": .array(apple.map(appleDailyJSON)),
        ])
    }

    func metricSeries(
        key: String,
        source: String,
        days: Int,
        fromDay explicitFrom: String?,
        toDay explicitTo: String?,
        limit: Int
    ) async throws -> JSONValue {
        let (fromDay, toDay) = explicitFrom != nil || explicitTo != nil
            ? (explicitFrom ?? dayRange(days: days).from, explicitTo ?? dayRange(days: days).to)
            : dayRange(days: days)
        let candidates = Self.sourceCandidates(forKey: key, preferredSource: source, actualWhoopSource: deviceId)
        var mergedByDay: [String: JSONValue] = [:]
        var usedSources: [String] = []

        for candidate in candidates {
            let rows = try await store.metricSeries(
                deviceId: candidate.source,
                key: candidate.key,
                from: fromDay,
                to: toDay
            )
            if !rows.isEmpty { usedSources.append(candidate.source) }
            for row in rows where mergedByDay[row.day] == nil {
                mergedByDay[row.day] = .object([
                    "day": .string(row.day),
                    "key": .string(row.key),
                    "value": .double(row.value),
                    "source": .string(candidate.source),
                    "sourceKey": .string(candidate.key),
                ])
            }
        }

        let points = mergedByDay.keys.sorted().compactMap { mergedByDay[$0] }
        let boundedPoints = Array(points.suffix(limit))
        return .object([
            "key": .string(key),
            "requestedSource": .string(source),
            "range": .object(["from": .string(fromDay), "to": .string(toDay)]),
            "resolution": .object([
                "candidates": .array(candidates.map { .object(["source": .string($0.source), "key": .string($0.key)]) }),
                "usedSources": .array(orderedUnique(usedSources).map { .string($0) }),
            ]),
            "returned": .int(boundedPoints.count),
            "points": .array(boundedPoints),
        ])
    }

    func freshness() async throws -> JSONValue {
        let latestHR = try await store.latestHRSampleTs(deviceId: deviceId)
        let stats = try await store.storageStats()
        let now = Date()
        let (fromDay, toDay) = dayRange(days: 4000)
        let importedDaily = try await store.dailyMetrics(deviceId: deviceId, from: fromDay, to: toDay)
        let computedDaily = try await store.dailyMetrics(deviceId: computedDeviceId, from: fromDay, to: toDay)
        let appleDaily = try await store.appleDaily(deviceId: "apple-health", from: fromDay, to: toDay)
        let importedKeys = try await store.metricKeys(deviceId: deviceId)
        let computedKeys = try await store.metricKeys(deviceId: computedDeviceId)
        let appleKeys = try await store.metricKeys(deviceId: "apple-health")

        return .object([
            "generatedAt": .string(iso(now)),
            "deviceId": .string(deviceId),
            "computedDeviceId": .string(computedDeviceId),
            "latestHeartRateSample": timestampJSON(latestHR, now: now),
            "storage": .object([
                "decodedRows": .int(stats.decodedRows),
                "rawBatches": .int(stats.rawBatches),
                "rawBytes": .int(stats.rawBytes),
            ]),
            "coverage": .object([
                "dailyImported": coverageJSON(importedDaily.map(\.day)),
                "dailyComputed": coverageJSON(computedDaily.map(\.day)),
                "appleDaily": coverageJSON(appleDaily.map(\.day)),
            ]),
            "metricKeys": .object([
                deviceId: .array(importedKeys.map { .string($0) }),
                computedDeviceId: .array(computedKeys.map { .string($0) }),
                "apple-health": .array(appleKeys.map { .string($0) }),
            ]),
        ])
    }

    func sleepSummary(days: Int) async throws -> JSONValue {
        let (fromTs, toTs) = timestampRange(days: days)
        let imported = try await store.sleepSessions(deviceId: deviceId, from: fromTs, to: toTs, limit: 5000)
        let computed = try await store.sleepSessions(deviceId: computedDeviceId, from: fromTs, to: toTs, limit: 5000)
        let merged = mergeSleep(imported: imported, computed: computed)
        let durations = merged.map { max(0, $0.endTs - $0.startTs) / 60 }
        let efficiencies = merged.compactMap(\.efficiency)

        return .object([
            "range": .object(["fromTs": .int(fromTs), "toTs": .int(toTs), "days": .int(days)]),
            "count": .int(merged.count),
            "averageDurationMin": optionalDouble(mean(durations.map(Double.init))),
            "averageEfficiency": optionalDouble(mean(efficiencies)),
            "sessions": .array(merged.suffix(200).map(sleepJSON)),
        ])
    }

    func workoutSummary(days: Int) async throws -> JSONValue {
        let (fromTs, toTs) = timestampRange(days: days)
        let imported = try await store.workouts(deviceId: deviceId, from: fromTs, to: toTs, limit: 5000)
        let apple = try await store.workouts(deviceId: "apple-health", from: fromTs, to: toTs, limit: 5000)
        let computed = try await store.workouts(deviceId: computedDeviceId, from: fromTs, to: toTs, limit: 5000)
        let rows = (imported + apple + computed).sorted { $0.startTs < $1.startTs }
        let durationMin = rows.reduce(0.0) { total, row in
            total + ((row.durationS ?? Double(max(0, row.endTs - row.startTs))) / 60.0)
        }
        let calories = rows.compactMap(\.energyKcal).reduce(0, +)
        let strain = rows.compactMap(\.strain).reduce(0, +)

        return .object([
            "range": .object(["fromTs": .int(fromTs), "toTs": .int(toTs), "days": .int(days)]),
            "count": .int(rows.count),
            "totalDurationMin": .double(durationMin),
            "totalEnergyKcal": .double(calories),
            "totalStrain": .double(strain),
            "workouts": .array(rows.suffix(300).map(workoutJSON)),
        ])
    }

    static func metricCatalog() -> JSONValue {
        .object([
            "sources": sources(),
            "keys": .array([
                "avg_hr", "max_hr", "energy_kcal", "recovery", "hrv", "rhr", "resp_rate",
                "spo2", "skin_temp", "sleep_performance", "sleep_total_min", "sleep_efficiency",
                "sleep_deep_min", "sleep_rem_min", "sleep_light_min", "sleep_need_min",
                "sleep_debt_min", "strain", "steps", "active_kcal", "weight", "vo2max",
                "body_fat", "lean_mass", "bmi", "stress", "mood", "calories_in",
                "protein_g", "carbs_g", "fat_g",
            ].map { .string($0) }),
            "resolutionRule": .string("my-whoop resolves imported my-whoop first, then my-whoop-noop computed rows, then compatible Apple Health fill-ins for rhr/hrv/spo2/resp_rate."),
        ])
    }

    static func sources() -> JSONValue {
        .object([
            "whoopImported": .string("my-whoop"),
            "noopComputed": .string("my-whoop-noop"),
            "appleHealth": .string("apple-health"),
            "nutrition": .string("nutrition-csv"),
            "mood": .string("noop-mood"),
            "journal": .string("noop-journal"),
        ])
    }

    private func mergedDaily(from: String, to: String) async throws -> [(row: DailyMetric, source: String)] {
        var byDay: [String: (DailyMetric, String)] = [:]
        for row in try await store.dailyMetrics(deviceId: computedDeviceId, from: from, to: to) {
            byDay[row.day] = (row, computedDeviceId)
        }
        for row in try await store.dailyMetrics(deviceId: deviceId, from: from, to: to) {
            byDay[row.day] = (row, deviceId)
        }
        return byDay.values.sorted { $0.0.day < $1.0.day }
    }

    private func mergeSleep(imported: [CachedSleepSession], computed: [CachedSleepSession]) -> [CachedSleepSession] {
        var importedDays = Set<String>()
        for session in imported {
            importedDays.insert(dayString(Date(timeIntervalSince1970: TimeInterval(session.endTs))))
        }
        let computedKept = computed.filter {
            !importedDays.contains(dayString(Date(timeIntervalSince1970: TimeInterval($0.endTs))))
        }
        return (imported + computedKept).sorted { $0.startTs < $1.startTs }
    }

    private func freshnessPayload(latestHR: Int?, apple: [AppleDaily], daily: [(row: DailyMetric, source: String)]) -> JSONValue {
        .object([
            "latestHeartRateSample": timestampJSON(latestHR, now: Date()),
            "latestDailyMetricDay": daily.last.map { .string($0.row.day) } ?? .null,
            "latestAppleHealthDay": apple.last.map { .string($0.day) } ?? .null,
            "dailyRows": .int(daily.count),
            "appleDailyRows": .int(apple.count),
        ])
    }

    private static func sourceCandidates(forKey key: String, preferredSource: String, actualWhoopSource: String) -> [MetricSourceCandidate] {
        if preferredSource == "my-whoop" || preferredSource == actualWhoopSource {
            var candidates = [
                MetricSourceCandidate(source: actualWhoopSource, key: key),
                MetricSourceCandidate(source: actualWhoopSource + "-noop", key: key),
            ]
            if let appleKey = appleCompatibleKey(forWhoopKey: key) {
                candidates.append(MetricSourceCandidate(source: "apple-health", key: appleKey))
            }
            return orderedUnique(candidates)
        }
        return [MetricSourceCandidate(source: preferredSource, key: key)]
    }

    private static func appleCompatibleKey(forWhoopKey key: String) -> String? {
        switch key {
        case "rhr":
            return "resting_hr"
        case "hrv", "spo2", "resp_rate":
            return key
        default:
            return nil
        }
    }
}

private struct MetricSourceCandidate: Hashable {
    let source: String
    let key: String
}

private enum DatabasePathResolver {
    static func resolve(env: [String: String]) throws -> String {
        if let explicit = env["NOOP_DB_PATH"], !explicit.isEmpty {
            return expandHome(explicit)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let bundleId = env["NOOP_BUNDLE_ID"].flatMap { $0.isEmpty ? nil : $0 } ?? "com.noopapp.noop.personal"
        let candidates = [
            "\(home)/Library/Containers/\(bundleId)/Data/Library/Application Support/OpenWhoop/whoop.sqlite",
            "\(home)/Library/Containers/com.noopapp.noop.personal/Data/Library/Application Support/OpenWhoop/whoop.sqlite",
            "\(home)/Library/Containers/com.noopapp.noop/Data/Library/Application Support/OpenWhoop/whoop.sqlite",
            "\(home)/Library/Application Support/OpenWhoop/whoop.sqlite",
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        throw MCPError.databaseUnavailable("No whoop.sqlite found. Set NOOP_DB_PATH to the NOOP database.")
    }

    private static func expandHome(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + String(path.dropFirst())
    }
}

// MARK: - Encoding helpers

private func dailyJSON(_ row: DailyMetric, source: String) -> JSONValue {
    .object([
        "day": .string(row.day),
        "source": .string(source),
        "totalSleepMin": optionalDouble(row.totalSleepMin),
        "efficiency": optionalDouble(row.efficiency),
        "deepMin": optionalDouble(row.deepMin),
        "remMin": optionalDouble(row.remMin),
        "lightMin": optionalDouble(row.lightMin),
        "disturbances": optionalInt(row.disturbances),
        "restingHr": optionalInt(row.restingHr),
        "avgHrv": optionalDouble(row.avgHrv),
        "recovery": optionalDouble(row.recovery),
        "strain": optionalDouble(row.strain),
        "exerciseCount": optionalInt(row.exerciseCount),
        "spo2Pct": optionalDouble(row.spo2Pct),
        "skinTempDevC": optionalDouble(row.skinTempDevC),
        "respRateBpm": optionalDouble(row.respRateBpm),
        "steps": optionalInt(row.steps),
        "activeKcalEst": optionalDouble(row.activeKcalEst),
    ])
}

private func appleDailyJSON(_ row: AppleDaily) -> JSONValue {
    .object([
        "day": .string(row.day),
        "steps": optionalInt(row.steps),
        "activeKcal": optionalDouble(row.activeKcal),
        "basalKcal": optionalDouble(row.basalKcal),
        "vo2max": optionalDouble(row.vo2max),
        "avgHr": optionalInt(row.avgHr),
        "maxHr": optionalInt(row.maxHr),
        "walkingHr": optionalInt(row.walkingHr),
        "weightKg": optionalDouble(row.weightKg),
    ])
}

private func sleepJSON(_ row: CachedSleepSession) -> JSONValue {
    .object([
        "startTs": .int(row.startTs),
        "endTs": .int(row.endTs),
        "start": .string(iso(Date(timeIntervalSince1970: TimeInterval(row.startTs)))),
        "end": .string(iso(Date(timeIntervalSince1970: TimeInterval(row.endTs)))),
        "durationMin": .double(Double(max(0, row.endTs - row.startTs)) / 60.0),
        "efficiency": optionalDouble(row.efficiency),
        "restingHr": optionalInt(row.restingHr),
        "avgHrv": optionalDouble(row.avgHrv),
        "hasStages": .bool(row.stagesJSON != nil),
    ])
}

private func workoutJSON(_ row: WorkoutRow) -> JSONValue {
    .object([
        "startTs": .int(row.startTs),
        "endTs": .int(row.endTs),
        "start": .string(iso(Date(timeIntervalSince1970: TimeInterval(row.startTs)))),
        "end": .string(iso(Date(timeIntervalSince1970: TimeInterval(row.endTs)))),
        "sport": .string(row.sport),
        "source": .string(row.source),
        "durationS": optionalDouble(row.durationS),
        "energyKcal": optionalDouble(row.energyKcal),
        "avgHr": optionalInt(row.avgHr),
        "maxHr": optionalInt(row.maxHr),
        "strain": optionalDouble(row.strain),
        "distanceM": optionalDouble(row.distanceM),
        "hasZones": .bool(row.zonesJSON != nil),
        "hasNotes": .bool(row.notes != nil),
    ])
}

private func timestampJSON(_ ts: Int?, now: Date) -> JSONValue {
    guard let ts else { return .null }
    let date = Date(timeIntervalSince1970: TimeInterval(ts))
    return .object([
        "ts": .int(ts),
        "iso": .string(iso(date)),
        "ageSeconds": .int(max(0, Int(now.timeIntervalSince(date)))),
    ])
}

private func coverageJSON(_ days: [String]) -> JSONValue {
    .object([
        "count": .int(days.count),
        "firstDay": days.min().map { .string($0) } ?? .null,
        "lastDay": days.max().map { .string($0) } ?? .null,
    ])
}

private func optionalDouble(_ value: Double?) -> JSONValue {
    value.map { .double($0) } ?? .null
}

private func optionalInt(_ value: Int?) -> JSONValue {
    value.map { .int($0) } ?? .null
}

private func boundedDays(_ value: JSONValue?, default defaultValue: Int, max maxValue: Int) -> Int {
    guard let raw = value?.intValue else { return defaultValue }
    return min(max(raw, 1), maxValue)
}

private func boundedLimit(_ value: JSONValue?, default defaultValue: Int, max maxValue: Int) -> Int {
    guard let raw = value?.intValue else { return defaultValue }
    return min(max(raw, 1), maxValue)
}

private func orderedUnique<T: Hashable>(_ values: [T]) -> [T] {
    var seen = Set<T>()
    var result: [T] = []
    for value in values where !seen.contains(value) {
        seen.insert(value)
        result.append(value)
    }
    return result
}

private func mean(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / Double(values.count)
}

private func dayRange(days: Int) -> (from: String, to: String) {
    let now = Date()
    return (
        from: dayString(now.addingTimeInterval(-Double(max(1, days) - 1) * 86_400)),
        to: dayString(now.addingTimeInterval(86_400))
    )
}

private func timestampRange(days: Int) -> (from: Int, to: Int) {
    let now = Int(Date().timeIntervalSince1970)
    return (now - max(1, days) * 86_400, now + 86_400)
}

private func dayString(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

private func logicalDayKey(_ now: Date) -> String {
    dayString(now.addingTimeInterval(-4 * 3_600))
}

private func iso(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

private func prettyJSON(_ value: JSONValue) -> String {
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    } catch {
        return "{\"error\":\"failed to encode JSON\"}"
    }
}
