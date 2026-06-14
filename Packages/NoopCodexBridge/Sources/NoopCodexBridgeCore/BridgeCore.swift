import Darwin
import Foundation
import Network

public struct BridgeConfiguration: Sendable {
    public let host: String
    public let port: UInt16
    public let codexPath: String
    public let modelOverride: String?
    public let workdir: String
    public let timeoutSeconds: TimeInterval

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        host = environment["NOOP_CODEX_BRIDGE_HOST"].flatMap { $0.isEmpty ? nil : $0 } ?? "127.0.0.1"
        port = UInt16(environment["NOOP_CODEX_BRIDGE_PORT"] ?? "") ?? 37337
        codexPath = Self.resolveCodexPath(environment: environment)
        modelOverride = environment["NOOP_CODEX_MODEL"].flatMap { $0.isEmpty ? nil : $0 }
        workdir = environment["NOOP_CODEX_WORKDIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "/tmp/noop-codex-bridge"
        timeoutSeconds = TimeInterval(environment["NOOP_CODEX_TIMEOUT_SECONDS"] ?? "") ?? 120
    }

    public var baseURL: String {
        "http://\(host):\(port)/v1"
    }

    private static func resolveCodexPath(environment: [String: String]) -> String {
        let fm = FileManager.default
        if let explicit = environment["CODEX_CLI_PATH"], fm.isExecutableFile(atPath: explicit) {
            return explicit
        }

        let appBundlePath = "/Applications/Codex.app/Contents/Resources/codex"
        if fm.isExecutableFile(atPath: appBundlePath) {
            return appBundlePath
        }

        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(dir)/codex"
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return appBundlePath
    }
}

public struct OpenAIChatMessage: Decodable, Sendable {
    public let role: String
    public let content: String
}

public struct OpenAIChatRequest: Decodable, Sendable {
    public let model: String?
    public let messages: [OpenAIChatMessage]
}

public enum PromptBuilder {
    public static func makePrompt(from request: OpenAIChatRequest) -> String {
        let systemMessages = request.messages
            .filter { $0.role.lowercased() == "system" }
            .map(\.content)
        let conversation = request.messages.filter { $0.role.lowercased() != "system" }

        var lines: [String] = [
            "You are replying through NOOP's local Codex bridge for a read-only coaching chat.",
            "",
            "Hard constraints:",
            "- Do not run shell commands, inspect files, modify files, or ask for approvals.",
            "- Answer only from the text provided in this prompt.",
            "- Treat biometric details as private user-provided context.",
            "- Do not diagnose medical conditions.",
            "- Return only the assistant message with no metadata.",
        ]

        if !systemMessages.isEmpty {
            lines.append("")
            lines.append("NOOP coach instructions:")
            lines.append(systemMessages.joined(separator: "\n\n"))
        }

        lines.append("")
        lines.append("Conversation and local NOOP context:")

        for message in conversation {
            let role = normalizedRole(message.role)
            lines.append("")
            lines.append("\(role):")
            lines.append(message.content)
        }

        lines.append("")
        lines.append("Return only the assistant's next reply.")
        return lines.joined(separator: "\n")
    }

    private static func normalizedRole(_ role: String) -> String {
        switch role.lowercased() {
        case "assistant": return "Assistant"
        case "user": return "User"
        default: return role.capitalized
        }
    }
}

public enum BridgeError: LocalizedError {
    case badRequest(String)
    case codexNotFound(String)
    case codexFailed(Int32)
    case codexTimedOut
    case emptyCodexReply

    public var errorDescription: String? {
        switch self {
        case .badRequest(let detail):
            return detail
        case .codexNotFound(let path):
            return "Codex CLI was not found at \(path). Open Codex or set CODEX_CLI_PATH."
        case .codexFailed(let code):
            return "Codex CLI exited with status \(code)."
        case .codexTimedOut:
            return "Codex CLI did not finish before the bridge timeout."
        case .emptyCodexReply:
            return "Codex CLI returned an empty reply."
        }
    }
}

public protocol CodexRunning: Sendable {
    func complete(prompt: String, requestedModel: String?) throws -> String
    func version() -> String
}

public final class CodexExecRunner: CodexRunning, @unchecked Sendable {
    private let configuration: BridgeConfiguration
    private let fileManager: FileManager

    public init(configuration: BridgeConfiguration, fileManager: FileManager = .default) {
        self.configuration = configuration
        self.fileManager = fileManager
    }

    public func version() -> String {
        guard fileManager.isExecutableFile(atPath: configuration.codexPath) else {
            return "missing"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.codexPath)
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")

        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty ?? "unknown"
        } catch {
            return "unknown"
        }
    }

    public func complete(prompt: String, requestedModel: String?) throws -> String {
        guard fileManager.isExecutableFile(atPath: configuration.codexPath) else {
            throw BridgeError.codexNotFound(configuration.codexPath)
        }

        try fileManager.createDirectory(
            atPath: configuration.workdir,
            withIntermediateDirectories: true
        )

        let outputPath = "\(configuration.workdir)/reply-\(UUID().uuidString).txt"
        defer { try? fileManager.removeItem(atPath: outputPath) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.codexPath)
        process.currentDirectoryURL = URL(fileURLWithPath: configuration.workdir, isDirectory: true)
        process.arguments = codexArguments(outputPath: outputPath, requestedModel: requestedModel)

        let input = Pipe()
        let nullOutput = FileHandle(forWritingAtPath: "/dev/null")
        let nullError = FileHandle(forWritingAtPath: "/dev/null")
        process.standardInput = input
        process.standardOutput = nullOutput
        process.standardError = nullError
        defer {
            try? nullOutput?.close()
            try? nullError?.close()
        }

        try process.run()
        if let data = prompt.data(using: .utf8) {
            input.fileHandleForWriting.write(data)
        }
        try? input.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(configuration.timeoutSeconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }

        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.4)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            throw BridgeError.codexTimedOut
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BridgeError.codexFailed(process.terminationStatus)
        }

        let reply = try String(contentsOfFile: outputPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else {
            throw BridgeError.emptyCodexReply
        }
        return reply
    }

    private func codexArguments(outputPath: String, requestedModel: String?) -> [String] {
        var args = ["-s", "read-only", "-a", "never"]

        if let model = selectedCLIModel(requestedModel) {
            args.append(contentsOf: ["-m", model])
        }

        args.append(contentsOf: [
            "exec",
            "--ephemeral",
            "--ignore-user-config",
            "--ignore-rules",
            "--skip-git-repo-check",
            "-C", configuration.workdir,
            "--color", "never",
            "--output-last-message", outputPath,
            "-",
        ])

        return args
    }

    private func selectedCLIModel(_ requestedModel: String?) -> String? {
        if let override = configuration.modelOverride {
            return override
        }

        let trimmed = (requestedModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch trimmed.lowercased() {
        case "codex-local", "codex app-server", "codex default", "codex-config-default":
            return nil
        default:
            return trimmed
        }
    }
}

public final class BridgeHTTPServer: @unchecked Sendable {
    private let configuration: BridgeConfiguration
    private let runner: CodexRunning
    private let listenerQueue = DispatchQueue(label: "noop.codex.bridge.listener")
    private let workerQueue = DispatchQueue(label: "noop.codex.bridge.worker", attributes: .concurrent)
    private var listener: NWListener?

    public init(configuration: BridgeConfiguration, runner: CodexRunning) {
        self.configuration = configuration
        self.runner = runner
    }

    public func start() throws {
        let port = NWEndpoint.Port(rawValue: configuration.port)!
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(configuration.host),
            port: port
        )

        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: listenerQueue)
        self.listener = listener
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: listenerQueue)
        receive(from: connection, accumulated: Data())
    }

    private func receive(from connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }

            var next = accumulated
            if let data {
                next.append(data)
            }

            if next.count > 1_000_000 {
                self.send(error: "Request body is too large.", status: 413, on: connection)
                return
            }

            if let request = HTTPRequest.parse(next) {
                self.workerQueue.async {
                    let response = self.route(request)
                    self.send(response: response, on: connection)
                }
            } else {
                self.receive(from: connection, accumulated: next)
            }
        }
    }

    private func route(_ request: HTTPRequest) -> HTTPResponse {
        if let origin = request.headers["origin"], !Self.isAllowedOrigin(origin) {
            return jsonError("Browser origin is not allowed for the local Codex bridge.", status: 403)
        }

        if request.method == "OPTIONS" {
            return HTTPResponse(status: 204, body: Data())
        }

        switch (request.method, request.path) {
        case ("GET", "/health"), ("GET", "/v1/health"):
            return json([
                "status": FileManager.default.isExecutableFile(atPath: configuration.codexPath) ? "ready" : "missing",
                "transport": "codex-exec",
                "base_url": configuration.baseURL,
                "codex_cli": configuration.codexPath,
                "codex_version": runner.version(),
                "model": configuration.modelOverride ?? "codex-config-default",
            ])

        case ("GET", "/models"), ("GET", "/v1/models"):
            return json([
                "object": "list",
                "data": [
                    [
                        "id": "codex-local",
                        "object": "model",
                        "created": Int(Date().timeIntervalSince1970),
                        "owned_by": "codex",
                    ],
                ],
            ])

        case ("POST", "/chat/completions"), ("POST", "/v1/chat/completions"):
            return chatResponse(for: request)

        default:
            return jsonError("Route not found.", status: 404)
        }
    }

    private func chatResponse(for request: HTTPRequest) -> HTTPResponse {
        do {
            let chat = try JSONDecoder().decode(OpenAIChatRequest.self, from: request.body)
            guard !chat.messages.isEmpty else {
                throw BridgeError.badRequest("The chat request did not include any messages.")
            }

            let prompt = PromptBuilder.makePrompt(from: chat)
            let reply = try runner.complete(prompt: prompt, requestedModel: chat.model)
            return json([
                "id": "chatcmpl-noop-codex-\(UUID().uuidString)",
                "object": "chat.completion",
                "created": Int(Date().timeIntervalSince1970),
                "model": chat.model ?? "codex-local",
                "choices": [
                    [
                        "index": 0,
                        "message": [
                            "role": "assistant",
                            "content": reply,
                        ],
                        "finish_reason": "stop",
                    ],
                ],
            ])
        } catch let error as BridgeError {
            return jsonError(error.localizedDescription, status: statusCode(for: error))
        } catch {
            return jsonError("Could not process the chat request.", status: 400)
        }
    }

    private func statusCode(for error: BridgeError) -> Int {
        switch error {
        case .badRequest:
            return 400
        case .codexNotFound:
            return 503
        case .codexTimedOut:
            return 504
        case .codexFailed, .emptyCodexReply:
            return 502
        }
    }

    private func json(_ object: [String: Any], status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data()
        return HTTPResponse(status: status, body: data)
    }

    private func jsonError(_ message: String, status: Int) -> HTTPResponse {
        json([
            "error": [
                "message": message,
                "type": "noop_codex_bridge_error",
            ],
        ], status: status)
    }

    private func send(error message: String, status: Int, on connection: NWConnection) {
        send(response: jsonError(message, status: status), on: connection)
    }

    private func send(response: HTTPResponse, on connection: NWConnection) {
        let headers = [
            "HTTP/1.1 \(response.status) \(HTTPResponse.reasonPhrase(for: response.status))",
            "Content-Type: application/json; charset=utf-8",
            "Content-Length: \(response.body.count)",
            "Connection: close",
            "Access-Control-Allow-Origin: http://127.0.0.1",
            "Access-Control-Allow-Headers: Content-Type, Authorization",
            "Access-Control-Allow-Methods: GET, POST, OPTIONS",
            "",
            "",
        ].joined(separator: "\r\n")

        var data = Data(headers.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func isAllowedOrigin(_ origin: String) -> Bool {
        guard let url = URL(string: origin), let host = url.host?.lowercased() else {
            return false
        }
        return host == "127.0.0.1" || host == "::1" || host == "localhost"
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    static func parse(_ data: Data) -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else { return nil }

        let headerEnd = headerRange.upperBound
        guard let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return nil
        }

        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard data.count >= headerEnd + contentLength else { return nil }

        let body: Data = contentLength > 0
            ? Data(data[headerEnd..<(headerEnd + contentLength)])
            : Data()

        let rawPath = String(requestParts[1])
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
        return HTTPRequest(
            method: String(requestParts[0]).uppercased(),
            path: path,
            headers: headers,
            body: body
        )
    }
}

struct HTTPResponse {
    let status: Int
    let body: Data

    static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return "OK"
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
