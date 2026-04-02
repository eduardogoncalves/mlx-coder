// Sources/ModelEngine/ModelLoader.swift
// Loads LLM from a local directory using MLX-Swift-LM

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM

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
        let spinnerMessage = usesHubID ? "Checking Hugging Face model..." : "Loading model from disk..."
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

        let progressTracker = DownloadProgressTracker()

        // Use the MLXLMCommon free function which automatically routes through all registered
        // model factories (MLXVLM first, then MLXLLM), so VLMs and LLMs are handled uniformly.
        let container = try await loadModelContainer(
            hub: .init(downloadBase: modelsBaseURL),
            configuration: configuration,
            progressHandler: { progress in
                guard usesHubID else { return }
                let message = progressTracker.formattedStatus(for: progress)
                Task { await spinner.updateMessage(message) }
            }
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

// MARK: - Download Progress

/// Tracks download progress for Hub model downloads and formats status messages
/// with bytes downloaded, total size, percentage, and current speed.
private final class DownloadProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var startTime: Date?

    /// Minimum elapsed time before a speed estimate is shown, to avoid
    /// misleadingly high values from a tiny early-burst sample.
    private static let minimumElapsedTimeForSpeedCalculation: TimeInterval = 0.5

    /// Returns a human-readable status string based on the current `Progress` snapshot.
    ///
    /// This method is called from a fire-and-forget `Task` that updates the `Spinner`
    /// actor. Because `Spinner.updateMessage` simply overwrites the stored message, any
    /// out-of-order delivery is harmless — the spinner always displays whatever was set
    /// most recently when it next redraws (every ~80 ms).
    func formattedStatus(for progress: Progress) -> String {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        if startTime == nil {
            startTime = now
        }

        let completed = progress.completedUnitCount
        let total = progress.totalUnitCount

        // Total unknown – just show a generic message
        guard total > 0 else {
            return "Downloading model from Hugging Face..."
        }

        // Download fully complete – hand off to the weight-loading phase
        let pct = Int(Double(completed) / Double(total) * 100)
        if pct >= 100 {
            return "Loading model weights..."
        }

        // When the Progress tracks individual files (kind == .file), unit counts
        // represent file counts, not bytes.  Display "X / Y files" in that case.
        if progress.kind == .file {
            return "Downloading: \(completed) / \(total) files (\(pct)%)"
        }

        let completedStr = Self.formatBytes(completed)
        let totalStr = Self.formatBytes(total)

        var speedPart = ""
        if let start = startTime {
            let elapsed = now.timeIntervalSince(start)
            if elapsed > Self.minimumElapsedTimeForSpeedCalculation && completed > 0 {
                let bytesPerSec = Double(completed) / elapsed
                speedPart = " at \(Self.formatBytes(Int64(bytesPerSec)))/s"
            }
        }

        return "Downloading: \(completedStr) / \(totalStr) (\(pct)%)\(speedPart)"
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let value = Double(bytes)
        if value >= 1_073_741_824 {
            return String(format: "%.1f GB", value / 1_073_741_824)
        } else if value >= 1_048_576 {
            return String(format: "%.1f MB", value / 1_048_576)
        } else if value >= 1_024 {
            return String(format: "%.1f KB", value / 1_024)
        } else {
            return "\(bytes) B"
        }
    }
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
