import AppKit
import Darwin
import Foundation
import OSLog

private let codexLog = Logger(subsystem: "com.noopapp.noop", category: "CodexAppServer")

/// Basic ChatGPT account metadata returned by `codex app-server`.
struct CodexAccount: Equatable, Sendable {
    let email: String
    let planType: String

    /// Human-readable account label for the Coach connection pill.
    var displayLabel: String {
        planType.isEmpty || planType == "unknown" ? email : "\(email) · \(planType)"
    }
}

/// Official macOS/Linux Codex CLI install command from OpenAI's Codex CLI docs.
let codexInstallCommand = "curl -fsSL https://chatgpt.com/codex/install.sh | sh"

/// Small wrapper around `codex app-server` for subscription-backed Coach calls.
enum CodexAppServer {
    /// Returns the currently signed-in ChatGPT account, if Codex has one.
    static func readAccount() async throws -> CodexAccount? {
        try await Task.detached(priority: .userInitiated) {
            let session = try CodexAppServerSession()
            defer { session.close() }
            try session.initialize()
            return try session.readAccount(refreshToken: true)
        }.value
    }

    /// Starts ChatGPT login in the browser and waits for Codex to report completion.
    static func signIn() async throws -> CodexAccount? {
        try await Task.detached(priority: .userInitiated) {
            let session = try CodexAppServerSession()
            defer { session.close() }
            try session.initialize()
            if let account = try session.readAccount(refreshToken: true) {
                return account
            }

            let result = try session.request("account/login/start", params: [
                "type": "chatgpt"
            ])
            guard let authURLString = result["authUrl"] as? String,
                  let authURL = URL(string: authURLString),
                  let loginId = result["loginId"] as? String else {
                throw CodexAppServerError.protocolError("Codex did not return a login URL.")
            }

            _ = await MainActor.run {
                NSWorkspace.shared.open(authURL)
            }

            try session.waitForLogin(loginId: loginId)
            return try session.readAccount(refreshToken: true)
        }.value
    }

    /// Logs out of the active Codex account.
    static func signOut() async throws {
        try await Task.detached(priority: .userInitiated) {
            let session = try CodexAppServerSession()
            defer { session.close() }
            try session.initialize()
            _ = try session.request("account/logout", params: [:])
        }.value
    }

    /// Lists ChatGPT/Codex models available to the signed-in account.
    static func listModels() async throws -> [String] {
        try await Task.detached(priority: .userInitiated) {
            let session = try CodexAppServerSession()
            defer { session.close() }
            try session.initialize()
            guard try session.readAccount(refreshToken: true) != nil else {
                throw CodexAppServerError.loginRequired
            }
            return try session.listModels()
        }.value
    }

    /// Runs a single locked-down Coach turn through an ephemeral Codex thread.
    static func complete(model: String,
                         systemPrompt: String,
                         messages: [(role: ChatMessage.Role, content: String)]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let session = try CodexAppServerSession()
            defer { session.close() }
            try session.initialize()
            guard try session.readAccount(refreshToken: true) != nil else {
                throw CodexAppServerError.loginRequired
            }
            return try session.complete(model: model, systemPrompt: systemPrompt, messages: messages)
        }.value
    }
}

/// Errors surfaced by the local Codex app-server bridge.
enum CodexAppServerError: LocalizedError {
    case codexNotFound
    case codexPermissionDenied
    case loginRequired
    case loginFailed(String)
    case protocolError(String)
    case serverError(String)
    case processError(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "Codex CLI was not found. Install it first: \(codexInstallCommand)"
        case .codexPermissionDenied:
            return "macOS blocked NOOP from running Codex from the default install paths. Update Codex or reinstall it with the official install command, then try again."
        case .loginRequired:
            return "Sign in with ChatGPT first to use the Codex-backed coach."
        case .loginFailed(let detail):
            return detail.isEmpty ? "ChatGPT sign-in did not complete." : "ChatGPT sign-in failed: \(detail)"
        case .protocolError(let detail):
            return detail
        case .serverError(let detail):
            return detail
        case .processError(let detail):
            return detail
        case .timeout(let detail):
            return detail
        }
    }
}

/// Blocking JSONL client for one short-lived `codex app-server` process.
private final class CodexAppServerSession {
    private let process: Process
    private let stdin: FileHandle
    private let stdout: FileHandle
    private let stderr: FileHandle
    private var nextId = 1
    private var readBuffer = Data()

    /// Starts `codex app-server` over stdio.
    init() throws {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let proc = Process()

        if let codexURL = Self.defaultCodexExecutableURL() {
            proc.executableURL = codexURL
            proc.arguments = ["app-server"]
            codexLog.info("Starting Codex app-server with executable: \(codexURL.path, privacy: .public)")
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = ["codex", "app-server"]
            codexLog.info("Starting Codex app-server through /usr/bin/env")
        }
        proc.standardInput = inputPipe
        proc.standardOutput = outputPipe
        proc.standardError = errorPipe

        var env = ProcessInfo.processInfo.environment
        env["RUST_LOG"] = env["RUST_LOG"] ?? "warn"
        env["PATH"] = Self.codexSearchPath(existingPath: env["PATH"])
        env["CODEX_HOME"] = Self.userCodexHome()
        proc.environment = env
        codexLog.info("Using CODEX_HOME: \(env["CODEX_HOME"] ?? "", privacy: .public)")

        do {
            try proc.run()
            codexLog.info("Codex app-server process launched with pid: \(proc.processIdentifier)")
        } catch {
            if error.localizedDescription.localizedCaseInsensitiveContains("operation not permitted") {
                throw CodexAppServerError.codexPermissionDenied
            }
            throw CodexAppServerError.processError("Could not start Codex app-server: \(error.localizedDescription)")
        }

        self.process = proc
        self.stdin = inputPipe.fileHandleForWriting
        self.stdout = outputPipe.fileHandleForReading
        self.stderr = errorPipe.fileHandleForReading
    }

    /// Sends the required app-server initialize handshake.
    func initialize() throws {
        _ = try request("initialize", params: [
            "clientInfo": [
                "name": "noop",
                "title": "NOOP Coach",
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            ],
            "capabilities": [
                "experimentalApi": true,
                "optOutNotificationMethods": [
                    "thread/started",
                    "item/started",
                    "thread/status/changed",
                    "thread/tokenUsage/updated"
                ]
            ]
        ])
        try notify("initialized", params: [:])
        codexLog.info("Codex app-server initialized")
    }

    /// Closes the transport and terminates the child process.
    func close() {
        try? stdin.close()
        if process.isRunning {
            process.terminate()
        }
    }

    /// Sends a JSON-RPC request and waits for its matching response.
    func request(_ method: String, params: [String: Any]) throws -> [String: Any] {
        let id = nextId
        nextId += 1
        codexLog.info("Codex request started: \(method, privacy: .public)")
        try send(["id": id, "method": method, "params": params])

        while true {
            let message = try readMessage(timeout: 45, context: method)
            if numericId(message["id"]) == id {
                let value = try result(from: message, method: method)
                codexLog.info("Codex request completed: \(method, privacy: .public)")
                return value
            }
            try handleOutOfBand(message)
        }
    }

    /// Sends a JSON-RPC notification.
    func notify(_ method: String, params: [String: Any]) throws {
        try send(["method": method, "params": params])
    }

    /// Reads account metadata from Codex.
    func readAccount(refreshToken: Bool) throws -> CodexAccount? {
        let result = try request("account/read", params: ["refreshToken": refreshToken])
        guard let account = result["account"] as? [String: Any],
              account["type"] as? String == "chatgpt",
              let email = account["email"] as? String else {
            return nil
        }
        return CodexAccount(email: email, planType: account["planType"] as? String ?? "unknown")
    }

    /// Waits until Codex reports that the browser login finished.
    func waitForLogin(loginId: String) throws {
        codexLog.info("Waiting for ChatGPT login completion")
        while true {
            let message = try readMessage(timeout: 180, context: "ChatGPT login")
            if message["method"] as? String == "account/login/completed",
               let params = message["params"] as? [String: Any],
               (params["loginId"] as? String) == loginId {
                if (params["success"] as? Bool) == true {
                    codexLog.info("ChatGPT login completed")
                    return
                }
                throw CodexAppServerError.loginFailed(params["error"] as? String ?? "")
            }
            try handleOutOfBand(message)
        }
    }

    /// Reads all available model ids from the Codex model catalog.
    func listModels() throws -> [String] {
        var cursor: String?
        var ids: [String] = []

        repeat {
            var params: [String: Any] = ["limit": 100, "includeHidden": false]
            if let cursor { params["cursor"] = cursor }
            let result = try request("model/list", params: params)
            let rows = result["data"] as? [[String: Any]] ?? []
            ids.append(contentsOf: rows.compactMap { row in
                guard (row["hidden"] as? Bool) != true else { return nil }
                return (row["model"] as? String) ?? (row["id"] as? String)
            })
            cursor = result["nextCursor"] as? String
        } while cursor != nil

        return Array(Set(ids)).sorted()
    }

    /// Starts an ephemeral thread, injects prior messages, and returns the final assistant text.
    func complete(model: String,
                  systemPrompt: String,
                  messages: [(role: ChatMessage.Role, content: String)]) throws -> String {
        guard let last = messages.last, last.role == .user else {
            throw CodexAppServerError.protocolError("Codex Coach calls must end with a user message.")
        }

        let cwd = try Self.lockedTemporaryDirectory()
        let threadResult = try request("thread/start", params: [
            "model": model,
            "baseInstructions": systemPrompt,
            "cwd": cwd,
            "ephemeral": true,
            "approvalPolicy": "never",
            "approvalsReviewer": "user",
            "sandbox": "read-only",
            "personality": "none",
            "config": [
                "web_search": "disabled",
                "sandbox_mode": "read-only",
                "approval_policy": "never"
            ]
        ])

        guard let thread = threadResult["thread"] as? [String: Any],
              let threadId = thread["id"] as? String else {
            throw CodexAppServerError.protocolError("Codex did not create a thread.")
        }

        let priorItems = messages.dropLast().map(Self.responsesItem)
        if !priorItems.isEmpty {
            _ = try request("thread/inject_items", params: [
                "threadId": threadId,
                "items": Array(priorItems)
            ])
        }

        _ = try request("turn/start", params: [
            "threadId": threadId,
            "model": model,
            "cwd": cwd,
            "approvalPolicy": "never",
            "approvalsReviewer": "user",
            "sandboxPolicy": [
                "type": "readOnly",
                "networkAccess": false
            ],
            "input": [
                ["type": "text", "text": last.content]
            ]
        ])

        return try waitForTurn(threadId: threadId)
    }

    /// Collects streamed assistant text until the active turn completes.
    private func waitForTurn(threadId: String) throws -> String {
        var streamed = ""
        var completedText: String?

        while true {
            let message = try readMessage(timeout: 180, context: "Coach reply")
            let method = message["method"] as? String
            let params = (message["params"] as? [String: Any]) ?? [:]

            if method == "item/agentMessage/delta",
               let delta = params["delta"] as? String {
                streamed += delta
                continue
            }

            if method == "item/completed",
               let item = params["item"] as? [String: Any],
               item["type"] as? String == "agentMessage",
               let text = item["text"] as? String,
               (item["phase"] as? String == "final_answer" || completedText == nil) {
                completedText = text
                continue
            }

            if method == "turn/completed",
               params["threadId"] as? String == threadId {
                if let turn = params["turn"] as? [String: Any],
                   turn["status"] as? String == "failed",
                   let error = turn["error"] as? [String: Any],
                   let detail = error["message"] as? String {
                    throw CodexAppServerError.serverError(detail)
                }
                let text = (completedText ?? streamed).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw CodexAppServerError.protocolError("Codex returned no coach reply.") }
                return text
            }

            try handleOutOfBand(message)
        }
    }

    /// Converts a NOOP chat message into a raw Responses API message item for Codex history.
    private static func responsesItem(_ message: (role: ChatMessage.Role, content: String)) -> [String: Any] {
        let contentType = message.role == .assistant ? "output_text" : "input_text"
        return [
            "type": "message",
            "role": message.role.rawValue,
            "content": [
                ["type": contentType, "text": message.content]
            ]
        ]
    }

    /// Returns a PATH that covers GUI app launches plus common Codex install locations.
    private static func codexSearchPath(existingPath: String?) -> String {
        let home = realUserHomeDirectory()
        let existing = (existingPath ?? "")
            .split(separator: ":")
            .map(String.init)
        let paths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ] + existing

        return Array(NSOrderedSet(array: paths)).compactMap { $0 as? String }.joined(separator: ":")
    }

    /// Finds Codex in OpenAI's direct-install path plus the standard Homebrew and npm prefixes.
    private static func defaultCodexExecutableURL() -> URL? {
        let home = realUserHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.codex/packages/standalone/current/bin/codex",
            "\(home)/.codex/packages/standalone/current/codex"
        ]

        return candidates
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Returns the user's normal Codex home so NOOP can reuse an existing ChatGPT/Codex login.
    private static func userCodexHome() -> String {
        "\(realUserHomeDirectory())/.codex"
    }

    /// Returns the real Unix home directory instead of the sandbox container home.
    private static func realUserHomeDirectory() -> String {
        guard let passwd = getpwuid(getuid()),
              let dir = passwd.pointee.pw_dir else {
            return "/Users/\(NSUserName())"
        }
        return String(cString: dir)
    }

    /// Creates an empty temp directory used as the read-only Codex cwd.
    private static func lockedTemporaryDirectory() throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("noop-codex-coach", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    /// Sends one JSON object as a JSONL app-server message.
    private func send(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        stdin.write(data)
        stdin.write(Data([0x0A]))
    }

    /// Reads and parses the next JSONL app-server message.
    private func readMessage(timeout: Int32, context: String) throws -> [String: Any] {
        while true {
            if let newline = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer[..<newline]
                readBuffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                guard let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                    throw CodexAppServerError.protocolError("Codex sent an unreadable message.")
                }
                return object
            }

            var descriptor = pollfd(fd: stdout.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, timeout * 1000)
            if ready == 0 {
                codexLog.error("Timed out waiting for Codex app-server during \(context, privacy: .public)")
                throw CodexAppServerError.timeout("Timed out waiting for Codex while \(context). Try again; if it keeps happening, run `codex` once in Terminal and confirm it is signed in.")
            }
            if ready < 0 {
                throw CodexAppServerError.processError("Codex app-server poll failed.")
            }

            var bytes = [UInt8](repeating: 0, count: 4096)
            let byteCount = Darwin.read(stdout.fileDescriptor, &bytes, bytes.count)
            if byteCount > 0 {
                readBuffer.append(bytes, count: byteCount)
                continue
            }

            if byteCount == 0 {
                let stderrText = String(data: stderr.availableData, encoding: .utf8) ?? ""
                if stderrText.localizedCaseInsensitiveContains("operation not permitted") {
                    throw CodexAppServerError.codexPermissionDenied
                }
                if stderrText.localizedCaseInsensitiveContains("codex")
                    && (stderrText.localizedCaseInsensitiveContains("no such file")
                        || stderrText.localizedCaseInsensitiveContains("not found")) {
                    throw CodexAppServerError.codexNotFound
                }
                codexLog.error("Codex app-server exited: \(stderrText, privacy: .public)")
                throw CodexAppServerError.processError(stderrText.isEmpty ? "Codex app-server exited." : stderrText)
            }

            if errno == EINTR {
                continue
            }
            throw CodexAppServerError.processError("Codex app-server read failed.")
        }
    }

    /// Extracts a request result or throws a readable JSON-RPC error.
    private func result(from message: [String: Any], method: String) throws -> [String: Any] {
        if let error = message["error"] as? [String: Any] {
            let detail = error["message"] as? String ?? "\(method) failed."
            throw CodexAppServerError.serverError(detail)
        }
        return message["result"] as? [String: Any] ?? [:]
    }

    /// Rejects server-initiated tool or approval requests so Coach stays non-agentic.
    private func handleOutOfBand(_ message: [String: Any]) throws {
        guard message["method"] is String, message["id"] != nil else { return }
        codexLog.warning("Rejecting Codex out-of-band request: \(message["method"] as? String ?? "unknown", privacy: .public)")
        try send([
            "id": message["id"]!,
            "error": [
                "code": -32000,
                "message": "NOOP Coach does not grant tool or approval requests."
            ]
        ])
    }

    /// Converts JSON-RPC ids emitted as numbers into Swift ints.
    private func numericId(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let int = value as? Int { return int }
        return nil
    }
}
