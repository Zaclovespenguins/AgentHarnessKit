// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "GRDBGate",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "GRDBGateCore", targets: ["GRDBGateCore"]),
        .executable(name: "grdb-gate", targets: ["grdb-gate"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/grdb.swift", .upToNextMajor(from: "7.12.0")),
        .package(url: "https://github.com/huggingface/AnyLanguageModel", .upToNextMinor(from: "1.3.0")),
    ],
    targets: [
        .target(
            name: "GRDBGateCore",
            dependencies: [.product(name: "GRDB", package: "grdb.swift")]
        ),
        .executableTarget(
            name: "grdb-gate",
            dependencies: [
                "GRDBGateCore",
                .product(name: "GRDB", package: "grdb.swift"),
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
            ]
        ),
        .testTarget(
            name: "GRDBGateCoreTests",
            dependencies: [
                "GRDBGateCore",
                .product(name: "GRDB", package: "grdb.swift"),
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
            ]
        ),
    ]
)
