// swift-tools-version: 6.3

import PackageDescription

/// Swift 6 language mode implies complete strict-concurrency checking. PackageDescription
/// has no separate `strictConcurrency` setting at tools version 6.3, and `-strict-concurrency`
/// via unsafeFlags would make the package unusable as a dependency.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
]

let package = Package(
    name: "AgentHarnessKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "AgentHarnessKit", targets: ["AgentHarnessKit"]),
        .library(name: "AgentHarnessKitALM", targets: ["AgentHarnessKitALM"]),
        .library(name: "AgentHarnessKitContext", targets: ["AgentHarnessKitContext"]),
        .library(name: "AgentHarnessKitMCP", targets: ["AgentHarnessKitMCP"]),
        .library(name: "AgentHarnessKitTesting", targets: ["AgentHarnessKitTesting"]),
    ],
    dependencies: [
        // Provider and transport layer for AgentHarnessKitALM only. ALM's traits (MLX,
        // CoreML, Llama, AsyncHTTPClient) stay off: we rely on its default (empty) set.
        .package(url: "https://github.com/huggingface/AnyLanguageModel", .upToNextMinor(from: "1.3.0")),
        // AgentHarnessKitContext only. GRDB gate passed on macOS and Linux (docs/ARCHITECTURE.md section 4).
        .package(url: "https://github.com/groue/grdb.swift", .upToNextMajor(from: "7.12.0")),
    ],
    targets: [
        // Core: messages, tools, loop, streaming, checkpointing, sub-agents, approval.
        // No provider, database or Apple-only dependency.
        .target(
            name: "AgentHarnessKit",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "AgentHarnessKitALM",
            dependencies: [
                "AgentHarnessKit",
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "AgentHarnessKitContext",
            dependencies: ["AgentHarnessKit", .product(name: "GRDB", package: "grdb.swift")],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "AgentHarnessKitMCP",
            dependencies: ["AgentHarnessKit"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "AgentHarnessKitTesting",
            dependencies: ["AgentHarnessKit"],
            swiftSettings: swiftSettings
        ),
        // Child process for the cross-process resume test; not a product.
        .executableTarget(
            name: "CheckpointResumeProbe",
            dependencies: ["AgentHarnessKit"],
            path: "Tests/CheckpointResumeProbe",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AgentHarnessKitTests",
            dependencies: ["AgentHarnessKit", "AgentHarnessKitTesting", "CheckpointResumeProbe"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AgentHarnessKitContextTests",
            dependencies: ["AgentHarnessKit", "AgentHarnessKitContext", "AgentHarnessKitTesting"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AgentHarnessKitMCPTests",
            dependencies: ["AgentHarnessKit", "AgentHarnessKitMCP", "AgentHarnessKitTesting"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "AgentHarnessKitALMTests",
            dependencies: [
                "AgentHarnessKit",
                "AgentHarnessKitALM",
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
            ],
            swiftSettings: swiftSettings
        ),
    ]
)
