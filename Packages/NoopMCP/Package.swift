// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NoopMCP",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "noop-mcp", targets: ["NoopMCP"]),
    ],
    dependencies: [
        .package(path: "../WhoopStore"),
    ],
    targets: [
        .executableTarget(
            name: "NoopMCP",
            dependencies: ["WhoopStore"]
        ),
    ]
)
