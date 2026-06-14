import Dispatch
import Foundation
import NoopCodexBridgeCore

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
