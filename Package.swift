// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "mlx-coder",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.1")),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", branch: "main"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "6.2.1"),
    ],
    targets: [
        .executableTarget(
            name: "MLXCoder",
            dependencies: [
                .product(name: "MLX",           package: "mlx-swift"),
                .product(name: "MLXLLM",        package: "mlx-swift-lm"),
                .product(name: "MLXVLM",        package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon",   package: "mlx-swift-lm"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Yams",          package: "Yams"),
            ],
            path: "Sources"
        ),
        .executableTarget(
            name: "TestGenerable",
            path: "TestSources/TestGenerable"
        ),
        .testTarget(
            name: "ModelEngineTests",
            dependencies: ["MLXCoder"],
            path: "Tests/ModelEngineTests"
        ),
        .testTarget(
            name: "ToolSystemTests",
            dependencies: ["MLXCoder"],
            path: "Tests/ToolSystemTests"
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["MLXCoder"],
            path: "Tests/IntegrationTests"
        ),
        .testTarget(
            name: "ProjectDetectorTests",
            dependencies: ["MLXCoder"],
            path: "Tests/ProjectDetectorTests"
        ),
    ]
)
