// Sources/ModelEngine/ModelLoader.swift
// Loads LLM from a local directory using MLX-Swift-LM

import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Loads a model from a local filesystem path.
/// The model runs in-process — no HTTP server, no external API.
public final class ModelLoader: Sendable {

    private static func looksLikeHubModelID(_ value: String) -> Bool {
        // Accept common Hugging Face-style identifiers like owner/model-name.
        // Exclude explicit local paths.
        if value.hasPrefix("/") || value.hasPrefix("~") || value.hasPrefix(".") {
            return false
        }
        let parts = value.split(separator: "/")
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
    }

    /// Load model from the given directory path.
    ///
    /// - Parameters:
    ///   - path: Absolute path to the model directory (e.g. ~/models/Qwen/Qwen3.5-9B-4bit)
    ///   - memoryLimit: Maximum memory in bytes (nil = no limit)
    ///   - cacheLimit: Maximum cache size in bytes (nil = no limit)
    /// - Returns: A loaded `ModelContainer` ready for generation
    public static func load(
        from path: String,
        memoryLimit: Int? = nil,
        cacheLimit: Int? = nil
    ) async throws -> ModelContainer {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let modelURL = URL(filePath: expandedPath)
        let modelsBaseURL = URL(filePath: NSString(string: "~").expandingTildeInPath)

        let usesLocalDirectory = FileManager.default.fileExists(atPath: expandedPath)
        let usesHubID = !usesLocalDirectory && looksLikeHubModelID(path)

        if !usesLocalDirectory && !usesHubID {
            throw ModelLoaderError.modelDirectoryNotFound(expandedPath)
        }

        // Configure memory limits
        if let memoryLimit {
            MLX.Memory.memoryLimit = memoryLimit
        }
        if let cacheLimit {
            MLX.Memory.cacheLimit = cacheLimit
        }

        // ── Metal shader pre-warm ─────────────────────────────────────────────
        // When the binary is built with -DMLX_PREWARM_SHADERS (the release
        // script sets this flag) we force Metal to compile and cache all MLX
        // GPU compute pipelines before touching the real model weights.
        //
        // Without this, the *first* matrix-multiply after model load triggers
        // lazy Metal shader compilation inside a live command encoder, which
        // can exceed the driver's allotted compile window and crash with:
        //   "Metal command buffer execution timed out"
        // or a silent GPU fault depending on macOS version.
        #if MLX_PREWARM_SHADERS
        prewarmMetalPipelines()
        #endif

        // Start spinner
        let spinnerMessage = usesHubID ? "Downloading/loading model from Hugging Face..." : "Loading model from disk..."
        let spinner = Spinner(message: spinnerMessage)
        await spinner.start()

        defer {
            Task { await spinner.stop() }
        }

        // Load using MLX-Swift-LM. If a Hub ID is passed, MLX downloads as needed.
        let configuration: ModelConfiguration
        if usesHubID {
            configuration = ModelConfiguration(id: path)
        } else {
            configuration = ModelConfiguration(directory: modelURL)
        }
        let container = try await LLMModelFactory.shared.loadContainer(
            hub: .init(downloadBase: modelsBaseURL),
            configuration: configuration
        )

        return container
    }

    // ── Metal shader pre-warm helper ──────────────────────────────────────────
    /// Runs a tiny, disposable MLX computation so that the Metal driver
    /// compiles and caches all required GPU compute pipelines before the
    /// real model is loaded.  This prevents first-inference crashes caused
    /// by lazy shader compilation inside a live command encoder.
    ///
    /// Compiled in only when the binary is built with `-DMLX_PREWARM_SHADERS`
    /// (set by `scripts/release.sh`).
    #if MLX_PREWARM_SHADERS
    private static func prewarmMetalPipelines() {
        // A 1×1 matmul triggers Metal pipeline compilation for the core GEMM
        // kernels used by every transformer layer.
        // MLXArray(_ values: [Float], _ shape: [Int]) is the correct Float
        // initialiser; MLXArray(converting:) only accepts [Double].
        let a = MLXArray([Float(1.0)], [1, 1])
        let b = MLXArray([Float(1.0)], [1, 1])
        // MLX is lazy-evaluated; eval() is a synchronous GPU flush.
        MLX.eval(MLX.matmul(a, b))
    }
    #endif
}

// MARK: - Errors

public enum ModelLoaderError: LocalizedError {
    case modelDirectoryNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .modelDirectoryNotFound(let path):
            return "Model directory not found: \(path)"
        }
    }
}
