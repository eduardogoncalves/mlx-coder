// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "mlx-coder",
    platforms: [.macOS("26.0")],
    products: [
        // Dynamic library consumed by the Zig (OpenTUI) host binary at link time.
        // The Zig build.zig must reference the path produced by `swift build -c release`.
        .library(
            name: "MLXCLib",
            type: .dynamic,
            targets: ["MLXCLib"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.3")),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.31.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.7.1"),
        .package(url: "https://github.com/jpsim/Yams", from: "6.2.1"),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3"
        ),
        // C ABI library that exposes the MLX inference engine to a Zig (OpenTUI) host.
        // Self-contained: does NOT depend on the MLXCoder executable target.
        .target(
            name: "MLXCLib",
            dependencies: [
                .product(name: "MLX",         package: "mlx-swift"),
                .product(name: "MLXLLM",      package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Hub",         package: "swift-transformers"),
                .product(name: "Tokenizers",  package: "swift-transformers"),
            ],
            path: "Sources/MLXCLib",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "MLXCoder",
            dependencies: [
                .product(name: "MLX",           package: "mlx-swift"),
                .product(name: "MLXRandom",     package: "mlx-swift"),
                .product(name: "MLXLLM",        package: "mlx-swift-lm"),
                .product(name: "MLXVLM",        package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon",   package: "mlx-swift-lm"),
                .product(name: "Hub",           package: "swift-transformers"),
                .product(name: "Tokenizers",    package: "swift-transformers"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Yams",          package: "Yams"),
                "CSQLite",
            ],
            path: "Sources",
            exclude: ["MLXCLib"],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
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
        .testTarget(
            name: "MemoryTests",
            dependencies: ["MLXCoder"],
            path: "Tests/MemoryTests"
        ),
    ]
)
