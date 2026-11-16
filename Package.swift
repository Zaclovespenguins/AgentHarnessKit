// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "AgentSpike",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.executable(name: "spike", targets: ["spike"])],
    dependencies: [
        .package(url: "https://github.com/huggingface/AnyLanguageModel", .upToNextMinor(from: "1.3.0")),
    ],
    targets: [
        .target(name: "SpikeCore", dependencies: [.product(name: "AnyLanguageModel", package: "AnyLanguageModel")]),
        .executableTarget(name: "spike", dependencies: ["SpikeCore"]),
        .testTarget(name: "SpikeCoreTests", dependencies: ["SpikeCore"]),
    ]
)
