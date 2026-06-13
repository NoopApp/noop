import Foundation
import NoopLocalAccessCore

@main
enum NoopLocalAccessMain {
    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        let command = args.first ?? "mcp"
        if !args.isEmpty { args.removeFirst() }

        switch command {
        case "mcp":
            runMCP(configuration: .environment())
        case "codex-config":
            print(codexConfig(arguments: args))
        case "--help", "-h", "help":
            print(helpText)
        default:
            fputs("Unknown command: \(command)\n\n\(helpText)\n", stderr)
            Foundation.exit(64)
        }
    }

    private static func runMCP(configuration: LocalAccessConfiguration) {
        let server = NoopMCPServer(configuration: configuration)
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let response = server.handleLine(trimmed)
            guard response != .null else { continue }
            write(response)
        }
    }

    private static func write(_ value: JSONValue) {
        do {
            let data = try JSONEncoder().encode(value)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            fputs("[noop-local-access] failed to encode response: \(error)\n", stderr)
        }
    }

    private static func codexConfig(arguments: [String]) -> String {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        var dbPath: String?
        var iterator = arguments.makeIterator()
        while let arg = iterator.next() {
            if arg == "--db-path" {
                dbPath = iterator.next()
            }
        }

        var lines = [
            "[mcp_servers.noop]",
            "command = \"\(toml(executable))\"",
            "args = [\"mcp\"]",
            "startup_timeout_sec = 10",
            "tool_timeout_sec = 60",
            "default_tools_approval_mode = \"prompt\"",
        ]
        if let dbPath, !dbPath.isEmpty {
            lines.append("")
            lines.append("[mcp_servers.noop.env]")
            lines.append("NOOP_DB_PATH = \"\(toml(dbPath))\"")
        }
        return lines.joined(separator: "\n")
    }

    private static func toml(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static let helpText = """
    Usage:
      noop-local-access mcp
      noop-local-access codex-config [--db-path /absolute/path/to/whoop.sqlite]

    Environment:
      NOOP_DB_PATH    Explicit NOOP SQLite path. Optional; otherwise the official macOS app container is used.
      NOOP_BUNDLE_ID  Optional non-default bundle id. Not needed for the official app.
      NOOP_DEVICE_ID  Optional source id. Defaults to my-whoop.

    The MCP server is read-only, stdio-based, and exposes bounded local NOOP data tools.
    """
}
