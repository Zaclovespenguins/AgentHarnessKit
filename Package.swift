// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "AgentSpike",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.executable(name: "spike", targets: ["spike"])],
    dependencies: [
        .package(url: "https://github.com/huggingface/AnyLanguageModel", .upToNextMinor(from: "1.3.0")),
        .package(url: "https://github.com/apple/swift-http-types", from: "1.5.0"),
    ],
    targets: [
        .target(name: "SpikeCore", dependencies: [.product(name: "AnyLanguageModel", package: "AnyLanguageModel"), .product(name: "HTTPTypes", package: "swift-http-types")]),
        .executableTarget(name: "spike", dependencies: ["SpikeCore"]),
        .testTarget(name: "SpikeCoreTests", dependencies: ["SpikeCore"]),
    ]
)
