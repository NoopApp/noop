import Dispatch
import Foundation
import NoopCodexBridgeCore

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--help") || arguments.contains("-h") {
    let usage = """
    Usage: noop-codex-bridge

    Starts the local NOOP Codex bridge on 127.0.0.1:37337 by default.
    Configure with NOOP_CODEX_BRIDGE_HOST, NOOP_CODEX_BRIDGE_PORT,
    CODEX_CLI_PATH, NOOP_CODEX_MODEL, NOOP_CODEX_WORKDIR, and
    NOOP_CODEX_TIMEOUT_SECONDS.

    """
    FileHandle.standardOutput.write(Data(usage.utf8))
    exit(0)
}

if let argument = arguments.first {
    let line = "Unknown argument: \(argument). Run noop-codex-bridge --help.\n"
    FileHandle.standardError.write(Data(line.utf8))
    exit(64)
}

let configuration = BridgeConfiguration()
let runner = CodexExecRunner(configuration: configuration)
let server = BridgeHTTPServer(configuration: configuration, runner: runner)

do {
    try server.start()
    let line = "NOOP Codex bridge listening at \(configuration.baseURL) using \(configuration.codexPath)\n"
    FileHandle.standardError.write(Data(line.utf8))
    dispatchMain()
} catch {
    let line = "NOOP Codex bridge failed to start: \(error.localizedDescription)\n"
    FileHandle.standardError.write(Data(line.utf8))
    exit(1)
}
