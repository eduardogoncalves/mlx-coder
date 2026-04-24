// Sources/MLXCLib/MLXCLib.swift
// Swift implementation of the C ABI declared in include/mlxclib.h.
//
// Architecture
//   MLXCLibSession  — per-session state, protected by NSLock.
//   ApprovalGate    — suspends an async task until Zig calls mlxclib_approval_respond().
//   @_cdecl funcs   — thin wrappers that unpack Unmanaged<MLXCLibSession> and delegate.
//
// The Swift code is intentionally self-contained: it re-declares the three small
// bridge types (TokenizerBridge, TokenizerLoader, HubDownloader) that mirror the
// ones in Sources/ModelEngine/ModelLoader.swift so that the MLXCLib library target
// does not need to depend on the MLXCoder executable.

import Foundation
import Hub
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

// MARK: - Bridge helpers (mirror of ModelLoader.swift bridges) ----------------

/// Adapts `Tokenizers.Tokenizer` (swift-transformers 1.x) to the
/// `MLXLMCommon.Tokenizer` protocol required by mlx-swift-lm 3.x.
private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

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

/// Loads a tokenizer from a local model directory using `AutoTokenizer`.
private struct LibTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        return TokenizerBridge(upstream)
    }
}

/// Downloads model snapshots from Hugging Face Hub.
private struct LibHubDownloader: MLXLMCommon.Downloader {
    private let hubApi: HubApi

    init() {
        let base = URL(filePath: NSString(string: "~").expandingTildeInPath)
        self.hubApi = HubApi(downloadBase: base)
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        try await hubApi.snapshot(
            from: id,
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: progressHandler
        )
    }
}

// MARK: - Approval gate --------------------------------------------------------

/// Suspends the async generation task until Zig responds to a tool-approval request.
/// Thread-safe via NSLock.
final class ApprovalGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CheckedContinuation<(approved: Bool, suggestion: String?), Never>?

    /// Block the current async task until `respond(approved:suggestion:)` is called.
    func wait() async -> (approved: Bool, suggestion: String?) {
        await withCheckedContinuation { continuation in
            lock.lock()
            pending = continuation
            lock.unlock()
        }
    }

    /// Unblock the waiting task.  Safe to call from any thread.
    func respond(approved: Bool, suggestion: String?) {
        lock.lock()
        let cont = pending
        pending = nil
        lock.unlock()
        cont?.resume(returning: (approved: approved, suggestion: suggestion))
    }
}

// MARK: - Inference session ---------------------------------------------------

/// Holds all mutable state for one MLXCLib inference session.
/// Every method is safe to call from any thread; internal state is protected
/// by NSLock.  Marked @unchecked Sendable because of the NSLock pattern.
final class MLXCLibSession: @unchecked Sendable {

    // MARK: Model state

    private let modelLock = NSLock()
    private var modelContainer: ModelContainer?

    // MARK: Active generation

    private let taskLock = NSLock()
    private var activeTask: Task<Void, Never>?

    // MARK: Approval

    private let approvalLock = NSLock()
    private var approvalCB: (@Sendable (String, String?) -> Void)?
    let gate = ApprovalGate()

    // MARK: Stats

    private let statsLock = NSLock()
    private var statLatencyMs:   Double  = 0
    private var statTokenPerSec: Double  = 0
    private var statTotalTokens: UInt64  = 0

    // MARK: - Model loading

    func loadModel(path: String, onDone: @escaping @Sendable (Bool, String?) -> Void) {
        Task.detached { [weak self] in
            guard let self else { onDone(false, "Session deallocated"); return }
            do {
                let expandedPath = NSString(string: path).expandingTildeInPath
                let modelURL     = URL(filePath: expandedPath)
                let configuration: ModelConfiguration

                if FileManager.default.fileExists(atPath: expandedPath) {
                    configuration = ModelConfiguration(directory: modelURL)
                } else {
                    // Treat as a Hugging Face Hub identifier.
                    configuration = ModelConfiguration(id: path)
                }

                let container = try await loadModelContainer(
                    from: LibHubDownloader(),
                    using: LibTokenizerLoader(),
                    configuration: configuration,
                    progressHandler: { _ in }   // progress not surfaced through C ABI
                )

                self.storeModel(container)

                onDone(true, nil)
            } catch {
                onDone(false, error.localizedDescription)
            }
        }
    }

    // MARK: - Token generation

    func generate(
        prompt: String,
        onToken: @escaping @Sendable (UnsafePointer<CChar>, Int) -> Void,
        onDone:  @escaping @Sendable (String?) -> Void
    ) {
        fputs("[Swift] generate() called with prompt: \(prompt)\n", stderr)
        let task = Task.detached { [weak self] in
            fputs("[Swift] Task.detached started\n", stderr)
            guard let self else { 
                fputs("[Swift] self deallocated\n", stderr)
                onDone("Session deallocated")
                return 
            }

            let container = readModel()
            fputs("[Swift] readModel() returned: \(container != nil ? "ok" : "nil")\n", stderr)

            guard let container else {
                fputs("[Swift] No container, calling onDone\n", stderr)
                onDone("No model loaded. Call mlxclib_load_model() first.")
                return
            }

            let t0 = Date()
            nonisolated(unsafe) var tokenCount = 0

            do {
                fputs("[Swift] Calling container.perform\n", stderr)
                try await container.perform { ctx in
                    fputs("[Swift] Inside container.perform\n", stderr)
                    if Task.isCancelled { throw CancellationError() }

                    // Build a safe, non-empty token sequence.
                    let inputIDs = ctx.tokenizer.encode(text: prompt, addSpecialTokens: true)
                    fputs("[Swift] Tokenized into \(inputIDs.count) tokens\n", stderr)
                    guard !inputIDs.isEmpty else {
                        throw NSError(
                            domain: "MLXCLib",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Tokenizer produced an empty token sequence for the given prompt."]
                        )
                    }

                    let input      = LMInput(tokens: MLXArray(inputIDs))
                    let parameters = GenerateParameters(temperature: 0.6, topP: 1.0)

                    // Incremental detokenisation: accumulate token IDs and emit only
                    // the new suffix after each decode to avoid partial UTF-8 sequences.
                    var accumulatedIDs: [Int] = []
                    var lastText = ""

                    fputs("[Swift] Starting token generation\n", stderr)
                    let tokenStream = try MLXLMCommon.generateTokens(
                        input: input,
                        parameters: parameters,
                        context: ctx
                    )

                    for await item in tokenStream {
                        fputs("[Swift] Got item from tokenStream\n", stderr)
                        if Task.isCancelled { throw CancellationError() }

                        switch item {
                        case .token(let id):
                            accumulatedIDs.append(id)
                            let text  = ctx.tokenizer.decode(tokenIds: accumulatedIDs, skipSpecialTokens: true)

                            // Skip while there is a replacement character (incomplete UTF-8).
                            guard !text.hasSuffix("\u{FFFD}") else { continue }

                            let delta = String(text.suffix(text.count - lastText.count))
                            lastText  = text

                            if !delta.isEmpty {
                                fputs("[Swift] Calling onToken with \(delta.utf8.count) bytes: \(delta)\n", stderr)
                                delta.withCString { onToken($0, delta.utf8.count) }
                                fputs("[Swift] onToken returned\n", stderr)
                            }

                            tokenCount &+= 1

                        default:
                            break
                        }
                    }
                }

                let elapsed = max(-t0.timeIntervalSinceNow, 1e-9)
                updateStats(tokenCount: UInt64(tokenCount), elapsed: elapsed)

                fputs("[Swift] Generation complete, calling onDone\n", stderr)
                onDone(nil)

            } catch is CancellationError {
                fputs("[Swift] Generation cancelled\n", stderr)
                onDone(nil)     // clean cancellation — not an error
            } catch {
                fputs("[Swift] Generation error: \(error.localizedDescription)\n", stderr)
                onDone(error.localizedDescription)
            }
        }

        taskLock.lock()
        activeTask = task
        taskLock.unlock()
    }

    // MARK: - Cancellation

    func cancel() {
        taskLock.lock()
        let t = activeTask
        activeTask = nil
        taskLock.unlock()
        t?.cancel()
    }

    // MARK: - Approval

    func setApprovalCallback(_ cb: (@Sendable (String, String?) -> Void)?) {
        approvalLock.lock()
        approvalCB = cb
        approvalLock.unlock()
    }

    /// Synchronous helper: read the approval callback under lock.
    private func readApprovalCallback() -> (@Sendable (String, String?) -> Void)? {
        approvalLock.lock()
        defer { approvalLock.unlock() }
        return approvalCB
    }

    /// Request approval for `toolName`.  Blocks the calling async task until
    /// `gate.respond(approved:suggestion:)` is called by the Zig side.
    func requestApproval(toolName: String, argsJSON: String?) async -> (Bool, String?) {
        let cb = readApprovalCallback()

        // Fire the C callback so Zig can show its approval modal.
        cb?(toolName, argsJSON)

        // Suspend this async task until Zig calls mlxclib_approval_respond().
        let result = await gate.wait()
        return (result.approved, result.suggestion)
    }

    // MARK: - Stats

    // Synchronous helpers for lock-protected access.
    // NSLock.lock()/unlock() may not be called directly inside async task bodies
    // in Swift 6; wrapping them in sync methods keeps the compiler happy while
    // preserving the same thread-safety guarantees.
    private func storeModel(_ container: ModelContainer) {
        modelLock.lock()
        modelContainer = container
        modelLock.unlock()
    }

    private func readModel() -> ModelContainer? {
        modelLock.lock()
        defer { modelLock.unlock() }
        return modelContainer
    }

    private func updateStats(tokenCount: UInt64, elapsed: Double) {
        statsLock.lock()
        statTotalTokens  &+= tokenCount
        statTokenPerSec   = Double(tokenCount) / elapsed
        statLatencyMs     = (elapsed / Double(max(tokenCount, 1))) * 1_000
        statsLock.unlock()
    }

    // MARK: - Persisted stats (public read)

    struct StatsSnapshot {
        var latencyMs:    Double
        var tokensPerSec: Double
        var totalTokens:  UInt64
        var modelLoaded:  Bool
    }

    func stats() -> StatsSnapshot {
        statsLock.lock()
        defer { statsLock.unlock() }
        modelLock.lock()
        defer { modelLock.unlock() }
        return StatsSnapshot(
            latencyMs:    statLatencyMs,
            tokensPerSec: statTokenPerSec,
            totalTokens:  statTotalTokens,
            modelLoaded:  modelContainer != nil
        )
    }
}

// MARK: - C ABI ---------------------------------------------------------------
//
// Each function unpacks the opaque MLXCSession pointer (which is a retained
// Unmanaged<MLXCLibSession>) and delegates to the session.
//
// Memory model for the session handle:
//   mlxclib_session_create  — passRetained  (+1 retain)
//   mlxclib_session_destroy — release       (-1 retain, deallocates when 0)

// Convenience type aliases for the @convention(c) callback signatures used in
// @_cdecl functions.  These must match the C typedefs in mlxclib.h exactly.
// Must be public because @_cdecl public functions use them as parameter types
// and Swift requires at least public visibility there.
public typealias CTokenCB    = @convention(c) (UnsafePointer<CChar>?,    Int,  UnsafeMutableRawPointer?) -> Void
public typealias CDoneCB     = @convention(c) (UnsafePointer<CChar>?,          UnsafeMutableRawPointer?) -> Void
public typealias CLoadCB     = @convention(c) (Bool, UnsafePointer<CChar>?,    UnsafeMutableRawPointer?) -> Void
public typealias CApprovalCB = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void

// ---------------------------------------------------------------------------
// Session lifecycle
// ---------------------------------------------------------------------------

@_cdecl("mlxclib_session_create")
public func mlxclib_session_create() -> UnsafeMutableRawPointer? {
    Unmanaged.passRetained(MLXCLibSession()).toOpaque()
}

@_cdecl("mlxclib_session_destroy")
public func mlxclib_session_destroy(_ sessionPtr: UnsafeMutableRawPointer?) {
    guard let sessionPtr else { return }
    Unmanaged<MLXCLibSession>.fromOpaque(sessionPtr).release()
}

// ---------------------------------------------------------------------------
// Model loading
// ---------------------------------------------------------------------------

@_cdecl("mlxclib_load_model")
public func mlxclib_load_model(
    _ sessionPtr:  UnsafeMutableRawPointer?,
    _ modelPath:   UnsafePointer<CChar>?,
    _ callback:    CLoadCB?,
    _ userData:    UnsafeMutableRawPointer?
) {
    guard let sessionPtr, let modelPath, let callback else { return }
    let session = Unmanaged<MLXCLibSession>.fromOpaque(sessionPtr).takeUnretainedValue()
    let path    = String(cString: modelPath)
    nonisolated(unsafe) let ud = userData

    session.loadModel(path: path) { success, errMsg in
        if let errMsg {
            errMsg.withCString { callback(success, $0, ud) }
        } else {
            callback(success, nil, ud)
        }
    }
}

// ---------------------------------------------------------------------------
// Token generation
// ---------------------------------------------------------------------------

@_cdecl("mlxclib_generate")
public func mlxclib_generate(
    _ sessionPtr: UnsafeMutableRawPointer?,
    _ promptPtr:  UnsafePointer<CChar>?,
    _ tokenCB:    CTokenCB?,
    _ doneCB:     CDoneCB?,
    _ userData:   UnsafeMutableRawPointer?
) {
    fputs("[mlxclib_generate] called\n", stderr)
    guard let sessionPtr, let promptPtr, let doneCB else {
        fputs("[mlxclib_generate] missing args\n", stderr)
        return
    }
    fputs("[mlxclib_generate] args OK\n", stderr)
    let session = Unmanaged<MLXCLibSession>.fromOpaque(sessionPtr).takeUnretainedValue()
    let prompt  = String(cString: promptPtr)
    let tcb     = tokenCB
    nonisolated(unsafe) let ud = userData

    fputs("[mlxclib_generate] calling session.generate with prompt: \(prompt)\n", stderr)
    session.generate(
        prompt: prompt,
        onToken: { cStr, len in
            fputs("[mlxclib_generate->onToken] calling callback\n", stderr)
            tcb?(cStr, len, ud)
        },
        onDone: { errMsg in
            fputs("[mlxclib_generate->onDone] calling done callback\n", stderr)
            if let errMsg {
                errMsg.withCString { doneCB($0, ud) }
            } else {
                doneCB(nil, ud)
            }
        }
    )
}

@_cdecl("mlxclib_cancel")
public func mlxclib_cancel(_ sessionPtr: UnsafeMutableRawPointer?) {
    guard let sessionPtr else { return }
    Unmanaged<MLXCLibSession>.fromOpaque(sessionPtr).takeUnretainedValue().cancel()
}

// ---------------------------------------------------------------------------
// Tool-approval flow
// ---------------------------------------------------------------------------

@_cdecl("mlxclib_set_approval_handler")
public func mlxclib_set_approval_handler(
    _ sessionPtr: UnsafeMutableRawPointer?,
    _ callback:   CApprovalCB?,
    _ userData:   UnsafeMutableRawPointer?
) {
    guard let sessionPtr else { return }
    let session = Unmanaged<MLXCLibSession>.fromOpaque(sessionPtr).takeUnretainedValue()
    nonisolated(unsafe) let ud = userData

    if let callback {
        session.setApprovalCallback { toolName, argsJSON in
            toolName.withCString { toolNameC in
                if let argsJSON {
                    argsJSON.withCString { argsC in callback(toolNameC, argsC, ud) }
                } else {
                    callback(toolNameC, nil, ud)
                }
            }
        }
    } else {
        session.setApprovalCallback(nil)
    }
}

@_cdecl("mlxclib_approval_respond")
public func mlxclib_approval_respond(
    _ sessionPtr:    UnsafeMutableRawPointer?,
    _ approved:      Bool,
    _ suggestionPtr: UnsafePointer<CChar>?
) {
    guard let sessionPtr else { return }
    let session    = Unmanaged<MLXCLibSession>.fromOpaque(sessionPtr).takeUnretainedValue()
    let suggestion = suggestionPtr.map { String(cString: $0) }
    session.gate.respond(approved: approved, suggestion: suggestion)
}

// ---------------------------------------------------------------------------
// Observability
// ---------------------------------------------------------------------------

/// MLXCStats layout must stay in sync with the typedef in mlxclib.h.
@frozen
public struct MLXCStatsSwift {
    public var token_latency_ms: Double   // offset  0 (8 bytes)
    public var tokens_per_sec:   Double   // offset  8 (8 bytes)
    public var tokens_generated: UInt64   // offset 16 (8 bytes)
    public var model_loaded:     Int32    // offset 24 (4 bytes)
    public var _pad:             Int32    // offset 28 (4 bytes) — reserved
}

@_cdecl("mlxclib_get_stats")
public func mlxclib_get_stats(
    _ sessionPtr: UnsafeMutableRawPointer?,
    _ outPtr:     UnsafeMutableRawPointer?
) {
    guard let sessionPtr, let outPtr else { return }
    let session = Unmanaged<MLXCLibSession>.fromOpaque(sessionPtr).takeUnretainedValue()
    let s       = session.stats()

    let stats   = MLXCStatsSwift(
        token_latency_ms: s.latencyMs,
        tokens_per_sec:   s.tokensPerSec,
        tokens_generated: s.totalTokens,
        model_loaded:     s.modelLoaded ? 1 : 0,
        _pad:             0
    )
    withUnsafeBytes(of: stats) { src in
        outPtr.copyMemory(from: src.baseAddress!, byteCount: src.count)
    }
}
