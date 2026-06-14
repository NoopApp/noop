// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NoopCodexBridge",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "NoopCodexBridgeCore", targets: ["NoopCodexBridgeCore"]),
        .executable(name: "noop-codex-bridge", targets: ["noop-codex-bridge"]),
    ],
    targets: [
        .target(name: "NoopCodexBridgeCore"),
        .executableTarget(
            name: "noop-codex-bridge",
            dependencies: ["NoopCodexBridgeCore"]
        ),
        .testTarget(
            name: "NoopCodexBridgeCoreTests",
            dependencies: ["NoopCodexBridgeCore"]
        ),
    ]
)
