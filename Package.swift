// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TokenUsage",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TokenUsage", targets: ["TokenUsageApp"]),
        .library(name: "TokenUsageCore", targets: ["TokenUsageCore"])
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite"
        ),
        .target(
            name: "TokenUsageCore",
            dependencies: ["CSQLite"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "TokenUsageApp",
            dependencies: ["TokenUsageCore"]
        ),
        .testTarget(
            name: "TokenUsageCoreTests",
            dependencies: ["TokenUsageCore"]
        )
    ]
)
