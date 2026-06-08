// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhoopProtocol",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "WhoopProtocol", targets: ["WhoopProtocol"]),
        .executable(name: "whoop-decode", targets: ["whoop-decode"]),
    ],
    targets: [
        .target(
            name: "WhoopProtocol",
            resources: [.process("Resources/whoop_protocol.json")]
        ),
        .executableTarget(
            name: "whoop-decode",
            dependencies: ["WhoopProtocol"]
        ),
        .testTarget(
            name: "WhoopProtocolTests",
            dependencies: ["WhoopProtocol"],
            resources: [.process("Resources")]
        ),
    ]
)
