import Foundation

struct CodexBridgeHealth: Decodable, Equatable {
    let status: String
    let transport: String
    let baseURL: String
    let codexCLI: String
    let codexVersion: String
    let model: String
    let bridgeVersion: String?
    let pid: Int?
    let uptimeSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case status
        case transport
        case baseURL = "base_url"
        case codexCLI = "codex_cli"
        case codexVersion = "codex_version"
        case model
        case bridgeVersion = "bridge_version"
        case pid
        case uptimeSeconds = "uptime_seconds"
    }

    var isReady: Bool { status == "ready" }

    static func decode(_ data: Data) throws -> CodexBridgeHealth {
        try JSONDecoder().decode(CodexBridgeHealth.self, from: data)
    }
}

enum CodexBridgeRuntimeState: Equatable {
    case unknown
    case stopped
    case starting
    case ready(CodexBridgeHealth)
    case degraded(CodexBridgeHealth)
    case missingBundledHelper(String)
    case failed(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var health: CodexBridgeHealth? {
        switch self {
        case .ready(let health), .degraded(let health):
            return health
        default:
            return nil
        }
    }

    var title: String {
        switch self {
        case .unknown:
            return "Not checked"
        case .stopped:
            return "Stopped"
        case .starting:
            return "Starting"
        case .ready:
            return "Ready"
        case .degraded:
            return "Needs Codex"
        case .missingBundledHelper:
            return "Missing helper"
        case .failed:
            return "Failed"
        }
    }

    var detail: String {
        switch self {
        case .unknown:
            return "NOOP has not checked the bundled bridge yet."
        case .stopped:
            return "The local bridge is not running. Start it from Coach."
        case .starting:
            return "NOOP is starting the bundled bridge helper."
        case .ready(let health):
            let version = health.codexVersion.isEmpty ? "Codex CLI available" : health.codexVersion
            return "Bridge \(health.bridgeVersion ?? "1.0.0") is listening on \(health.baseURL) with \(version)."
        case .degraded(let health):
            return "The bridge is reachable, but Codex CLI is not executable at \(health.codexCLI)."
        case .missingBundledHelper(let path):
            return "The app bundle does not contain \(path). Rebuild NOOP."
        case .failed(let message):
            return message
        }
    }
}

@MainActor
final class CodexBridgeSupervisor {
    private let session: URLSession
    private let bundle: Bundle
    private var process: Process?

    init(session: URLSession = .shared, bundle: Bundle = .main) {
        self.session = session
        self.bundle = bundle
    }

    var bundledHelperPath: String {
        bundle.bundleURL
            .appendingPathComponent("Contents/Helpers/noop-codex-bridge")
            .path
    }

    func refresh() async -> CodexBridgeRuntimeState {
        do {
            let health = try await fetchHealth()
            return health.isReady ? .ready(health) : .degraded(health)
        } catch {
            return .stopped
        }
    }

    func start() async -> CodexBridgeRuntimeState {
        let existing = await refresh()
        if existing.health != nil {
            return existing
        }

        let helperPath = bundledHelperPath
        guard FileManager.default.isExecutableFile(atPath: helperPath) else {
            return .missingBundledHelper(helperPath)
        }

        do {
            try launchHelper(at: helperPath)
        } catch {
            return .failed("NOOP could not start the bundled bridge: \(error.localizedDescription)")
        }

        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            let state = await refresh()
            if state.health != nil {
                return state
            }
            if let process, !process.isRunning {
                return .failed("The bundled bridge exited with status \(process.terminationStatus).")
            }
        }

        return .failed("The bundled bridge started, but NOOP could not reach it on \(AIProvider.codexLocalAuthority).")
    }

    func restart() async -> CodexBridgeRuntimeState {
        if let process, process.isRunning {
            process.terminate()
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        process = nil
        return await start()
    }

    func stop() -> CodexBridgeRuntimeState {
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        return .stopped
    }

    private func fetchHealth() async throws -> CodexBridgeHealth {
        var req = URLRequest(url: AIProvider.codexLocalHealthURL)
        req.httpMethod = "GET"
        req.timeoutInterval = 2

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try CodexBridgeHealth.decode(data)
    }

    private func launchHelper(at path: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.environment = bridgeEnvironment()
        process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try process.run()
        self.process = process
    }

    private func bridgeEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["NOOP_CODEX_BRIDGE_HOST"] = AIProvider.codexLocalHost
        env["NOOP_CODEX_BRIDGE_PORT"] = "\(AIProvider.codexLocalPort)"
        env["NOOP_CODEX_BRIDGE_TOKEN"] = CodexBridgeAccess.token
        if env["NOOP_CODEX_WORKDIR"] == nil {
            env["NOOP_CODEX_WORKDIR"] = NSTemporaryDirectory() + "noop-codex-bridge"
        }
        return env
    }
}
