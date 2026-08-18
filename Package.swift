// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "mlx-coder",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.4"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.7.1"),
        .package(url: "https://github.com/jpsim/Yams", from: "6.2.1"),
        .package(url: "https://github.com/eduardogoncalves/swift-coder-tui", branch: "main"),
        .package(url: "https://github.com/scinfu/SwiftSoup", from: "2.9.0"),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3"
        ),
        // Vendored tree-sitter runtime + tier-1 grammars (plan §13.2, §13.6).
        // Not SPM package dependencies — plain C sources fetched/pinned by
        // `scripts/sync-grammars.sh` into `grammars/manifest.json`. Each
        // grammar target compiles only its generated `parser.c` (+
        // `scanner.c` where the grammar has an external scanner); the
        // `CTreeSitter` runtime target compiles only `lib.c`, which
        // `#include`s the rest of `lib/src` as a single translation unit —
        // see the `sources:` restriction below, which is what keeps SPM from
        // also trying to compile those files individually.
        .target(
            name: "CTreeSitter",
            path: "Sources/CTreeSitter",
            sources: ["lib.c"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "CTreeSitterSwift",
            dependencies: ["CTreeSitter"],
            path: "Sources/CTreeSitterSwift",
            sources: ["src/parser.c", "src/scanner.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("src")]
        ),
        .target(
            name: "CTreeSitterCSharp",
            dependencies: ["CTreeSitter"],
            path: "Sources/CTreeSitterCSharp",
            sources: ["src/parser.c", "src/scanner.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("src")]
        ),
        .target(
            name: "CTreeSitterJavaScript",
            dependencies: ["CTreeSitter"],
            path: "Sources/CTreeSitterJavaScript",
            sources: ["src/parser.c", "src/scanner.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("src")]
        ),
        .target(
            name: "CTreeSitterTypeScript",
            dependencies: ["CTreeSitter"],
            path: "Sources/CTreeSitterTypeScript",
            sources: ["typescript/src/parser.c", "typescript/src/scanner.c"],
            publicHeadersPath: "include",
            // The vendored `common/scanner.h` shared with tsx/ (not vendored
            // here — tier-1 scope is `.ts` only) does `#include
            // "tree_sitter/parser.h"` with no relative prefix, so (unlike
            // the other three grammars, whose own scanner.c sits directly
            // beside their `tree_sitter/` dir and resolves it via the
            // plain same-directory quote-include rule) this one needs the
            // explicit search path.
            cSettings: [.headerSearchPath("typescript/src")]
        ),
        .executableTarget(
            name: "MLXCoder",
            dependencies: [
                .product(name: "MLX",           package: "mlx-swift"),
                .product(name: "MLXRandom",     package: "mlx-swift"),
                .product(name: "MLXLLM",        package: "mlx-swift-lm"),
                .product(name: "MLXVLM",        package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon",   package: "mlx-swift-lm"),
                .product(name: "MLXEmbedders",  package: "mlx-swift-lm"),
                .product(name: "Hub",           package: "swift-transformers"),
                .product(name: "Tokenizers",    package: "swift-transformers"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Yams",          package: "Yams"),
                .product(name: "SwiftCoderTUI", package: "swift-coder-tui"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                "CSQLite",
                "CTreeSitter",
                "CTreeSitterSwift",
                "CTreeSitterCSharp",
                "CTreeSitterJavaScript",
                "CTreeSitterTypeScript",
            ],
            path: "Sources",
            exclude: [
                "CTreeSitter",
                "CTreeSitterSwift",
                "CTreeSitterCSharp",
                "CTreeSitterJavaScript",
                "CTreeSitterTypeScript",
                "CodeModeWorker",
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "TestGenerable",
            path: "TestSources/TestGenerable"
        ),
        // Minimal sibling executable for `execute_code` ("Code Mode"): runs a
        // model-generated script in JavaScriptCore, isolated in its own
        // process (no MLX/model loading, so it starts in milliseconds). Tool
        // calls the script makes are proxied back to the parent MLXCoder
        // process over a newline-delimited JSON protocol on stdio — see
        // Sources/ToolSystem/CodeMode/CodeModeSandboxProcess.swift.
        .executableTarget(
            name: "CodeModeWorker",
            path: "Sources/CodeModeWorker",
            linkerSettings: [
                .linkedFramework("JavaScriptCore")
            ]
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
        .testTarget(
            name: "AgentCoreTests",
            dependencies: ["MLXCoder"],
            path: "Tests/AgentCoreTests"
        ),
        .testTarget(
            name: "CodeGraphTests",
            dependencies: ["MLXCoder"],
            path: "Tests/CodeGraphTests"
        ),
    ]
)
