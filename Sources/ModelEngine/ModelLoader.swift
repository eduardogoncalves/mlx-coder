// Sources/ModelEngine/ModelLoader.swift
// Loads LLM from a local directory using MLX-Swift-LM

import Foundation
import Hub
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers

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
        var modelURL = URL(filePath: expandedPath)
        let modelsBaseURL = URL(filePath: NSString(string: "~").expandingTildeInPath)

        var usesLocalDirectory = FileManager.default.fileExists(atPath: expandedPath)
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

        // ── Local ~/models cache check ─────────────────────────────────────────
        // When a Hub ID is requested, first check if the model already exists
        // at ~/models/<org>/<model> from a prior download. If so, load from
        // disk directly — no network call needed.
        var resolvedFromLocalModels = false
        if usesHubID {
            let parts = path.split(separator: "/", maxSplits: 1)
            let localModelPath = modelsBaseURL
                .appendingPathComponent("models")
                .appendingPathComponent(String(parts[0]))
                .appendingPathComponent(String(parts[1]))

            if FileManager.default.fileExists(atPath: localModelPath.path) {
                modelURL = localModelPath
                usesLocalDirectory = true
                resolvedFromLocalModels = true
            }
        }

        // ── Git-accelerated download ──────────────────────────────────────────
        // When a Hub ID is requested and no local copy exists, try a shallow
        // `git clone` first. Git transfers a single server-compressed pack-file,
        // which is significantly faster than the MLX Hub's per-file HTTP
        // downloads. Falls back to the standard Hub download if git isn't
        // available or the clone fails for any reason.
        var gitClonedLocally = false
        if usesHubID && !resolvedFromLocalModels {
            let parts = path.split(separator: "/", maxSplits: 1)
            let localClonePath = modelsBaseURL
                .appendingPathComponent("models")
                .appendingPathComponent(String(parts[0]))
                .appendingPathComponent(String(parts[1]))

            if isGitAvailable() {
                await spinner.updateMessage("Cloning \(path) via git (shallow, no history)...")
                let cloneSuccess = await gitShallowClone(
                    repoURL: "https://huggingface.co/\(path)",
                    destination: localClonePath,
                    spinner: spinner
                )
                if cloneSuccess {
                    modelURL = localClonePath
                    usesLocalDirectory = true
                    gitClonedLocally = true
                } else {
                    await spinner.updateMessage("Git clone failed, falling back to Hugging Face Hub download...")
                }
            }
        }

        // Load using MLX-Swift-LM. If a Hub ID is passed, MLX downloads as needed.
        let configuration: ModelConfiguration
        if usesLocalDirectory {
            configuration = ModelConfiguration(directory: modelURL)
        } else {
            configuration = ModelConfiguration(id: path)
        }

        let progressTracker = DownloadProgressTracker()

        let skipHubProgress = gitClonedLocally || resolvedFromLocalModels

        // Use the MLXLMCommon free function which automatically routes through all registered
        // model factories (MLXVLM first, then MLXLLM), so VLMs and LLMs are handled uniformly.
        let container = try await loadModelContainer(
            from: MLXHubDownloader(downloadBase: modelsBaseURL),
            using: MLXTokenizerLoader(),
            configuration: configuration,
            progressHandler: { progress in
                guard !skipHubProgress else { return }
                let message = progressTracker.formattedStatus(for: progress)
                Task { await spinner.updateMessage(message) }
            }
        )

        if !gitClonedLocally && !resolvedFromLocalModels && usesHubID {
            pruneHuggingFaceCache(forModelID: path)
        }

        return container
    }

    // MARK: - Git-accelerated Download Helpers

    /// Returns `true` when `git` and `git-lfs` are both reachable on $PATH.
    private static func isGitAvailable() -> Bool {
        func canRun(_ launchPath: String, _ args: [String]) -> Bool {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.arguments = [launchPath] + args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }
        return canRun("git", ["--version"]) && canRun("git", ["lfs", "version"])
    }

    /// Performs a shallow `git clone` of a Hugging Face repo, then fetches
    /// LFS objects.  Returns `true` on success.
    ///
    /// The clone uses `--depth 1` (no history) and `--filter=blob:none`
    /// so the initial git transfer contains only tree/commit objects.
    /// `git lfs pull` then fetches the actual weight files via the HF
    /// LFS server, which is still faster than individual HTTP GETs
    /// because LFS can batch requests and resume partial transfers.
    ///
    /// Progress output from both `git clone --progress` and `git lfs pull`
    /// is captured from stderr and parsed to update the spinner with
    /// percentage and download speed.
    ///
    /// After a successful download the `.git` directory is removed to
    /// save disk space (the model directory becomes a plain folder).
    private static func gitShallowClone(
        repoURL: String,
        destination: URL,
        spinner: Spinner
    ) async -> Bool {
        let fileManager = FileManager.default

        // Ensure parent directory exists (e.g. ~/models/mlx-community)
        let parentDir = destination.deletingLastPathComponent()
        try? fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)

        // Prevent git-lfs from downloading during clone; we do it explicitly after.
        var env = ProcessInfo.processInfo.environment
        env["GIT_LFS_SKIP_SMUDGE"] = "1"

        // Step 1 — shallow clone without LFS blobs
        let cloneProcess = Process()
        cloneProcess.executableURL = URL(filePath: "/usr/bin/env")
        cloneProcess.arguments = [
            "git", "clone",
            "--depth", "1",
            "--filter=blob:none",
            "--no-checkout",
            "--progress",
            repoURL,
            destination.path
        ]
        cloneProcess.environment = env
        cloneProcess.standardOutput = FileHandle.nullDevice

        let clonePipe = Pipe()
        cloneProcess.standardError = clonePipe

        do {
            try cloneProcess.run()
        } catch {
            return false
        }

        // Parse clone progress in a background task
        let cloneProgressTask = Task.detached { [spinner] in
            Self.streamProgressFromPipe(clonePipe, prefix: "Cloning repo", spinner: spinner)
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            cloneProcess.terminationHandler = { _ in cont.resume() }
        }
        cloneProgressTask.cancel()
        guard cloneProcess.terminationStatus == 0 else {
            try? fileManager.removeItem(at: destination)
            return false
        }

        // Step 1b — checkout the working tree
        let checkoutProcess = Process()
        checkoutProcess.executableURL = URL(filePath: "/usr/bin/env")
        checkoutProcess.arguments = ["git", "-C", destination.path, "checkout"]
        checkoutProcess.environment = env
        checkoutProcess.standardOutput = FileHandle.nullDevice
        checkoutProcess.standardError = FileHandle.nullDevice
        do {
            try checkoutProcess.run()
        } catch {
            try? fileManager.removeItem(at: destination)
            return false
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            checkoutProcess.terminationHandler = { _ in cont.resume() }
        }
        guard checkoutProcess.terminationStatus == 0 else {
            try? fileManager.removeItem(at: destination)
            return false
        }

        // Step 2 — pull LFS objects (the actual weight files)
        await spinner.updateMessage("Downloading model weights via git-lfs...")

        let lfsProcess = Process()
        lfsProcess.executableURL = URL(filePath: "/usr/bin/env")
        lfsProcess.arguments = ["git", "-C", destination.path, "lfs", "pull"]
        lfsProcess.standardOutput = FileHandle.nullDevice

        let lfsPipe = Pipe()
        lfsProcess.standardError = lfsPipe

        do {
            try lfsProcess.run()
        } catch {
            try? fileManager.removeItem(at: destination)
            return false
        }

        // Parse LFS progress in a background task
        let lfsProgressTask = Task.detached { [spinner] in
            Self.streamProgressFromPipe(lfsPipe, prefix: "Downloading weights", spinner: spinner)
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lfsProcess.terminationHandler = { _ in cont.resume() }
        }
        lfsProgressTask.cancel()
        guard lfsProcess.terminationStatus == 0 else {
            try? fileManager.removeItem(at: destination)
            return false
        }

        // Step 3 — remove .git to save disk space; model dir becomes a plain folder.
        let dotGit = destination.appendingPathComponent(".git")
        try? fileManager.removeItem(at: dotGit)

        return true
    }

    // MARK: - Git Progress Parsing

    /// Reads stderr from a git process pipe and updates the spinner with
    /// parsed progress information.
    ///
    /// Git and git-lfs write progress to stderr using `\r` to overwrite
    /// the current line. Example outputs:
    ///   git clone:  `Receiving objects:  42% (21/50), 1.20 MiB | 3.50 MiB/s`
    ///   git lfs:    `Downloading LFS objects:  67% (4/6), 2.1 GB | 48.2 MB/s`
    private static func streamProgressFromPipe(
        _ pipe: Pipe,
        prefix: String,
        spinner: Spinner
    ) {
        let handle = pipe.fileHandleForReading
        var buffer = Data()

        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }  // EOF
            buffer.append(chunk)

            // Git uses \r (carriage return) to overwrite progress lines.
            // Split on both \r and \n to get the latest fragment.
            guard let text = String(data: buffer, encoding: .utf8) else { continue }

            // Find the last meaningful progress line
            let lines = text.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            if let lastLine = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                let parsed = parseGitProgressLine(lastLine, prefix: prefix)
                Task { await spinner.updateMessage(parsed) }
            }

            // Keep only the tail after the last separator to avoid unbounded growth
            if let lastSep = text.lastIndex(where: { $0 == "\r" || $0 == "\n" }) {
                let tail = String(text[text.index(after: lastSep)...])
                buffer = tail.data(using: .utf8) ?? Data()
            }
        }
    }

    /// Extracts percentage, size, and speed from a git/git-lfs progress line.
    ///
    /// Input examples:
    ///   `Receiving objects:  42% (21/50), 1.20 MiB | 3.50 MiB/s`
    ///   `Downloading LFS objects:  67% (4/6), 2.1 GB | 48.2 MB/s`
    ///   `Filtering content:  80% (8/10), 512.0 KB | 1.2 MB/s`
    ///
    /// Returns a human-readable string like:
    ///   `Downloading weights: 67% (4/6 files) 2.1 GB at 48.2 MB/s`
    private static func parseGitProgressLine(_ line: String, prefix: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Try to extract percentage — matches "NN%" anywhere
        var pctPart = ""
        if let pctRange = trimmed.range(of: #"\d+%"#, options: .regularExpression) {
            pctPart = String(trimmed[pctRange])
        }

        // Try to extract (N/M) counts
        var countsPart = ""
        if let countsRange = trimmed.range(of: #"\(\d+/\d+\)"#, options: .regularExpression) {
            let raw = String(trimmed[countsRange])
            // Turn (4/6) into "4/6 files"
            let inner = raw.dropFirst().dropLast()
            countsPart = "(\(inner) files)"
        }

        // Try to extract size info (everything after the counts/pct, before the pipe)
        var sizePart = ""
        if let pipeIndex = trimmed.firstIndex(of: "|") {
            // Look for size between ) and |
            let beforePipe: Substring
            if let closeParen = trimmed.lastIndex(of: ")"), closeParen < pipeIndex {
                beforePipe = trimmed[trimmed.index(after: closeParen)..<pipeIndex]
            } else {
                beforePipe = trimmed[trimmed.startIndex..<pipeIndex]
            }
            let sizeCandidate = beforePipe.trimmingCharacters(in: CharacterSet(charactersIn: ", "))
            if !sizeCandidate.isEmpty && sizeCandidate.rangeOfCharacter(from: .decimalDigits) != nil {
                sizePart = sizeCandidate
            }
        }

        // Try to extract speed (everything after |)
        var speedPart = ""
        if let pipeIndex = trimmed.firstIndex(of: "|") {
            let afterPipe = String(trimmed[trimmed.index(after: pipeIndex)...]).trimmingCharacters(in: .whitespaces)
            if !afterPipe.isEmpty {
                speedPart = "at \(afterPipe)"
            }
        }

        // Build the spinner message
        var parts = [prefix + ":"]
        if !pctPart.isEmpty { parts.append(pctPart) }
        if !countsPart.isEmpty { parts.append(countsPart) }
        if !sizePart.isEmpty { parts.append(sizePart) }
        if !speedPart.isEmpty { parts.append(speedPart) }

        let result = parts.joined(separator: " ")
        // If we couldn't parse anything meaningful, show the raw line
        return result == prefix + ":" ? "\(prefix): \(trimmed)" : result
    }

    private static func pruneHuggingFaceCache(forModelID modelID: String) {
        let fileManager = FileManager.default
        let normalizedRepo = modelID.replacingOccurrences(of: "/", with: "--")
        let cacheFolderName = "models--\(normalizedRepo)"

        let cacheRoots: [URL] = [
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library")
                .appendingPathComponent("Caches")
                .appendingPathComponent("huggingface")
                .appendingPathComponent("hub"),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache")
                .appendingPathComponent("huggingface")
                .appendingPathComponent("hub")
        ]

        for root in cacheRoots {
            let candidate = root.appendingPathComponent(cacheFolderName)
            if fileManager.fileExists(atPath: candidate.path) {
                try? fileManager.removeItem(at: candidate)
            }
        }
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
    private var firstProgressTime: Date?
    private var lastKnownFilename: String?
    private var lastKnownCompletedBytes: Int64?
    private var lastKnownTotalBytes: Int64?

    /// Minimum elapsed time before a speed estimate is shown, to avoid
    /// misleadingly high values from a tiny early-burst sample.
    private static let minimumElapsedTimeForSpeedCalculation: TimeInterval = 0.5

    /// MLX/HF snapshot progress sometimes uses synthetic weights of 1 per file
    /// when the server does not provide a real byte size. In that case the raw
    /// `Progress` values are file counts, not byte counts.
    private static let syntheticCountProgressThreshold: Int64 = 1_024

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
        if firstProgressTime == nil {
            firstProgressTime = now
        }

        let completed = progress.completedUnitCount
        let total = progress.totalUnitCount

        // Total unknown – we are still resolving repo metadata.
        guard total > 0 else {
            if let firstProgressTime {
                let resolvingSeconds = Int(max(0, now.timeIntervalSince(firstProgressTime)))
                return "Resolving Hugging Face files... (\(resolvingSeconds)s)"
            }
            return "Preparing Hugging Face download..."
        }

        // Download fully complete – hand off to the weight-loading phase
        let pct = Int(Double(completed) / Double(total) * 100)
        if pct >= 100 {
            return "Loading model weights..."
        }

        if let detailed = formattedPerFileStatus(
            progress: progress,
            completedFiles: completed,
            totalFiles: total
        ) {
            return detailed
        }

        // When the Progress tracks individual files, or when the Hub falls back
        // to synthetic unit weights for unknown file sizes, the unit counts are
        // file counts rather than bytes. Display file counts in that case.
        if progress.kind == .file || Self.usesCountBasedProgress(progress) {
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

    private static func usesCountBasedProgress(_ progress: Progress) -> Bool {
        let total = progress.totalUnitCount
        guard total > 0, total <= syntheticCountProgressThreshold else {
            return false
        }

        let completed = progress.completedUnitCount
        return completed >= 0 && completed <= total
    }

    private func formattedPerFileStatus(progress: Progress, completedFiles: Int64, totalFiles: Int64) -> String? {
        let filenameKey = ProgressUserInfoKey("mlxCurrentFilename")
        let completedBytesKey = ProgressUserInfoKey("mlxCurrentFileCompletedBytes")
        let totalBytesKey = ProgressUserInfoKey("mlxCurrentFileTotalBytes")

        if let filename = progress.userInfo[filenameKey] as? String {
            lastKnownFilename = filename
        }

        if let completedBytesNumber = progress.userInfo[completedBytesKey] as? NSNumber {
            lastKnownCompletedBytes = completedBytesNumber.int64Value
        }

        if let totalBytesNumber = progress.userInfo[totalBytesKey] as? NSNumber {
            lastKnownTotalBytes = max(1, totalBytesNumber.int64Value)
        }

        guard
            let filename = lastKnownFilename,
            let fileCompleted = lastKnownCompletedBytes,
            let fileTotal = lastKnownTotalBytes
        else {
            return nil
        }

        let filePct = Int(Double(max(0, min(fileCompleted, fileTotal))) / Double(fileTotal) * 100)
        let completedStr = Self.formatBytes(fileCompleted)
        let totalStr = Self.formatBytes(fileTotal)
        let clampedCompletedFiles = max(0, min(completedFiles, totalFiles))

        return "Downloading: \(clampedCompletedFiles) / \(totalFiles) files \(filename) \(completedStr) of \(totalStr) (\(filePct)%)"
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

// MARK: - Downloader / TokenizerLoader bridges for mlx-swift-lm 3.x

/// Adapts `Tokenizers.Tokenizer` (from swift-transformers) to `MLXLMCommon.Tokenizer`.
private struct MLXTokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    // swift-transformers uses `decode(tokens:)` label; MLXLMCommon uses `decode(tokenIds:)`.
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

/// Loads a tokenizer from a local directory using `Tokenizers.AutoTokenizer`.
struct MLXTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        return MLXTokenizerBridge(upstream)
    }
}

/// Downloads model snapshots from Hugging Face Hub using `Hub.HubApi`.
struct MLXHubDownloader: MLXLMCommon.Downloader {
    private let hubApi: HubApi

    init(downloadBase: URL? = nil) {
        self.hubApi = HubApi(downloadBase: downloadBase)
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        let rev = revision ?? "main"
        return try await hubApi.snapshot(
            from: id,
            revision: rev,
            matching: patterns,
            progressHandler: progressHandler
        )
    }
}
