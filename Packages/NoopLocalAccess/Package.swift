// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NoopLocalAccess",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "NoopLocalAccessCore", targets: ["NoopLocalAccessCore"]),
        .executable(name: "noop-local-access", targets: ["noop-local-access"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
    ],
    targets: [
        .target(
            name: "NoopLocalAccessCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .executableTarget(
            name: "noop-local-access",
            dependencies: ["NoopLocalAccessCore"]
        ),
        .testTarget(
            name: "NoopLocalAccessCoreTests",
            dependencies: [
                "NoopLocalAccessCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ]
)
