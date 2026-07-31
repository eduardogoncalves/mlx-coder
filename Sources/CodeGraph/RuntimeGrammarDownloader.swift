// Sources/CodeGraph/RuntimeGrammarDownloader.swift
// M5c — on-demand runtime grammar download/compile for the long-tail tier-2
// languages (plan §13.2 tier-2, §13.3). Every network/compile/dlopen
// dependency is behind a small protocol so `RuntimeGrammarManagerTests` can
// mock all three (per plan §13.5: "Tests MUST mock network/compile — do not
// require real downloads").
//
// Safety rails (plan §13.3, non-negotiable):
//  1. Consent always — `ensureGrammar` never downloads without going through
//     `policy` (`CodeGraphConfig.grammarDownload`) + `consentProvider`.
//  2. Pin + verify — only `RuntimeGrammarManifestEntry.commit` over HTTPS;
//     every fetched file's sha256 is checked against the manifest before
//     it's used for anything (including being written to the compile dir).
//  3. ABI pin — `entry.abi` must fall inside `runtimeABIRange` (the linked
//     `CTreeSitter` runtime's supported `TREE_SITTER_LANGUAGE_VERSION` /
//     `TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION` range) or the grammar is
//     refused before any network I/O happens.
//  4. Cache by name+hash — `<language>-<combinedHash>.dylib` under
//     `~/.mlx-coder/grammars/`; a pin change changes the hash, so it's
//     recompiled rather than silently reusing stale native code.
//  5. Graceful degrade — every failure path (declined, unsupported, hash
//     mismatch, ABI out of range, compile failure, dlopen failure) returns
//     `nil` from `ensureGrammar`, never throws into the turn.

import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Manifest model (tier2 section of grammars/manifest.json)

public struct RuntimeGrammarManifestEntry: Sendable, Equatable {
    public let language: String
    public let repo: String
    public let commit: String
    public let srcdir: String
    public let symbol: String
    public let abi: Int
    public let hasScanner: Bool
    /// repo-relative path (from `srcdir`'s parent, e.g. `"src/parser.c"`) → sha256.
    public let files: [String: String]

    public init(language: String, repo: String, commit: String, srcdir: String, symbol: String, abi: Int, hasScanner: Bool, files: [String: String]) {
        self.language = language
        self.repo = repo
        self.commit = commit
        self.srcdir = srcdir
        self.symbol = symbol
        self.abi = abi
        self.hasScanner = hasScanner
        self.files = files
    }
}

public enum RuntimeGrammarManifest {
    /// Parses the `tier2` object of `grammars/manifest.json`. Tolerant of a
    /// missing/malformed file or section — returns `[:]` rather than
    /// throwing, matching this module's "degrade, never throw" discipline;
    /// an empty tier-2 table just means every tier-2 language request is
    /// `unsupported` (plan §13.3 #5).
    public static func loadTier2(from url: URL) -> [String: RuntimeGrammarManifestEntry] {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tier2 = json["tier2"] as? [String: Any] else {
            return [:]
        }
        var result: [String: RuntimeGrammarManifestEntry] = [:]
        for (language, raw) in tier2 {
            guard let dict = raw as? [String: Any],
                  let repo = dict["repo"] as? String,
                  let commit = dict["commit"] as? String,
                  let srcdir = dict["srcdir"] as? String,
                  let symbol = dict["symbol"] as? String,
                  let abi = dict["abi"] as? Int,
                  let files = dict["files"] as? [String: String]
            else { continue }
            let hasScanner = dict["hasScanner"] as? Bool ?? false
            result[language] = RuntimeGrammarManifestEntry(
                language: language, repo: repo, commit: commit, srcdir: srcdir,
                symbol: symbol, abi: abi, hasScanner: hasScanner, files: files
            )
        }
        return result
    }
}

// MARK: - Errors

public enum RuntimeGrammarError: Error, CustomStringConvertible {
    case declined
    case unsupported(language: String)
    case abiIncompatible(language: String, abi: Int, supported: ClosedRange<Int>)
    case downloadFailed(path: String)
    case hashMismatch(path: String, expected: String, actual: String)
    case compileFailed(String)
    case loadFailed(language: String)

    public var description: String {
        switch self {
        case .declined: return "grammar download declined"
        case .unsupported(let language): return "no tier-2 manifest entry for language '\(language)'"
        case .abiIncompatible(let language, let abi, let supported):
            return "grammar '\(language)' ABI \(abi) outside supported range \(supported)"
        case .downloadFailed(let path): return "failed to download \(path)"
        case .hashMismatch(let path, let expected, let actual):
            return "sha256 mismatch for \(path): expected \(expected), got \(actual)"
        case .compileFailed(let detail): return "grammar compile failed: \(detail)"
        case .loadFailed(let language): return "dlopen/dlsym failed for grammar '\(language)'"
        }
    }
}

// MARK: - Consent (plan §13.3 #1)

/// Called only when the persisted policy (`CodeGraphConfig.grammarDownload`)
/// is `"ask"`. `"always"`/`"never"` are resolved by `RuntimeGrammarManager`
/// without consulting this at all — this protocol exists purely for the
/// interactive one-off prompt.
public protocol GrammarDownloadConsentProvider: Sendable {
    func requestConsent(forLanguage language: String) async -> Bool
}

/// Safe default: declines every request. Production call sites that want an
/// interactive prompt (reusing the existing `AgentFrontend`
/// `ApprovalRequest`/`InteractiveInput` surface named in plan §13.2) inject
/// their own provider; this default guarantees "ask" never silently
/// downloads when nothing is wired up to actually ask.
public struct DecliningGrammarDownloadConsentProvider: GrammarDownloadConsentProvider {
    public init() {}
    public func requestConsent(forLanguage language: String) async -> Bool { false }
}

// MARK: - Network / compile / dlopen seams (mocked in tests)

public protocol GrammarNetworkFetching: Sendable {
    /// Fetches `url` (always an HTTPS raw-file URL built from a manifest
    /// entry's pinned `repo`/`commit`) and returns its bytes.
    func fetch(url: URL) async throws -> Data
}

public struct URLSessionGrammarFetcher: GrammarNetworkFetching {
    public init() {}
    public func fetch(url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RuntimeGrammarError.downloadFailed(path: url.absoluteString)
        }
        return data
    }
}

public protocol GrammarCompiling: Sendable {
    /// Compiles `sourceFiles` (verified `.c` files only) into a dynamic
    /// library at `outputDylib`, with `headerSearchPaths` added so
    /// `#include "tree_sitter/parser.h"`-style relative includes resolve
    /// (mirrors the tier-1 SPM C targets' own header layout).
    func compile(sourceFiles: [URL], headerSearchPaths: [URL], outputDylib: URL) async throws
}

/// Real `clang -dynamiclib` compiler — the production default. Never called
/// by tests (they inject a fake `GrammarCompiling`), so it doesn't need to
/// be sandboxed against test execution; it degrades to
/// `RuntimeGrammarError.compileFailed` (never throws into the turn — the
/// caller, `RuntimeGrammarManager.ensureGrammar`, swallows it) if `clang`
/// is unavailable.
public struct ClangGrammarCompiler: GrammarCompiling {
    public init() {}

    public func compile(sourceFiles: [URL], headerSearchPaths: [URL], outputDylib: URL) async throws {
        guard !sourceFiles.isEmpty else {
            throw RuntimeGrammarError.compileFailed("no source files to compile")
        }
        try FileManager.default.createDirectory(at: outputDylib.deletingLastPathComponent(), withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var args = ["clang", "-dynamiclib", "-O2", "-fPIC"]
        for headerPath in headerSearchPaths {
            args.append(contentsOf: ["-I", headerPath.path])
        }
        args.append(contentsOf: sourceFiles.map(\.path))
        args.append(contentsOf: ["-o", outputDylib.path])
        process.arguments = args

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            throw RuntimeGrammarError.compileFailed("clang not available: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw RuntimeGrammarError.compileFailed(stderr.isEmpty ? "clang exited \(process.terminationStatus)" : stderr)
        }
    }
}

/// `OpaquePointer` (the imported Swift type for `TSLanguage *`) isn't
/// `Sendable` by default — Swift can't generically reason about arbitrary
/// raw pointers being safe to share across isolation domains. A
/// `TSLanguage*` specifically *is* safe: tree-sitter grammars are immutable
/// static data tables meant to be read concurrently from many parsers, so
/// this thin `@unchecked Sendable` box is a deliberate, narrow escape
/// hatch — not a blanket "trust me" on arbitrary pointers.
public struct TSLanguageHandle: @unchecked Sendable {
    public let pointer: OpaquePointer
    public init(_ pointer: OpaquePointer) { self.pointer = pointer }
}

public protocol GrammarDynamicLoading: Sendable {
    /// `dlopen`s `dylibPath` and resolves+calls `tree_sitter_<symbol>()`.
    /// Returns `nil` on any failure (missing file, dlopen failure, symbol
    /// not found) rather than throwing — the caller treats "couldn't load"
    /// identically whether it's a cache-corruption or a fresh compile gone
    /// wrong (plan §13.3 #5).
    func loadLanguage(dylibPath: URL, symbol: String) -> OpaquePointer?
}

public struct DlopenGrammarLoader: GrammarDynamicLoading {
    public init() {}
    public func loadLanguage(dylibPath: URL, symbol: String) -> OpaquePointer? {
        guard let handle = dlopen(dylibPath.path, RTLD_NOW) else { return nil }
        guard let sym = dlsym(handle, symbol) else { return nil }
        typealias GetLanguageFn = @convention(c) () -> OpaquePointer?
        let getLanguage = unsafeBitCast(sym, to: GetLanguageFn.self)
        return getLanguage()
    }
}

// MARK: - Manager

/// Owns the on-demand tier-2 grammar lifecycle: consent → fetch → verify →
/// compile → cache → dlopen. One instance is meant to live for the
/// process's lifetime so successfully-loaded (and declined) languages are
/// remembered rather than re-negotiated per file.
public actor RuntimeGrammarManager {
    /// `TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION...TREE_SITTER_LANGUAGE_VERSION`
    /// for the vendored `CTreeSitter` runtime pin (`grammars/manifest.json`'s
    /// `runtime` section / `scripts/sync-grammars.sh`'s `RUNTIME_ABI_MIN/MAX`
    /// — keep these three in sync if the runtime pin is ever bumped).
    public static let supportedABIRange: ClosedRange<Int> = 13...15

    private let manifestEntries: [String: RuntimeGrammarManifestEntry]
    private let cacheDir: URL
    private let policy: String
    private let fetcher: GrammarNetworkFetching
    private let compiler: GrammarCompiling
    private let loader: GrammarDynamicLoading
    private let consentProvider: GrammarDownloadConsentProvider
    private let abiRange: ClosedRange<Int>

    private var loaded: [String: OpaquePointer] = [:]
    private var declined: Set<String> = []
    /// Diagnostic for the most recent `nil`-returning `ensureGrammar` call
    /// (never surfaced as a thrown error — see the type's doc comment).
    public private(set) var lastError: RuntimeGrammarError?

    public init(
        manifestEntries: [String: RuntimeGrammarManifestEntry],
        policy: String,
        cacheDir: URL? = nil,
        fetcher: GrammarNetworkFetching = URLSessionGrammarFetcher(),
        compiler: GrammarCompiling = ClangGrammarCompiler(),
        loader: GrammarDynamicLoading = DlopenGrammarLoader(),
        consentProvider: GrammarDownloadConsentProvider = DecliningGrammarDownloadConsentProvider(),
        abiRange: ClosedRange<Int> = RuntimeGrammarManager.supportedABIRange
    ) {
        self.manifestEntries = manifestEntries
        self.policy = policy
        if let cacheDir {
            self.cacheDir = cacheDir
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            self.cacheDir = URL(fileURLWithPath: home)
                .appendingPathComponent(".mlx-coder", isDirectory: true)
                .appendingPathComponent("grammars", isDirectory: true)
        }
        self.fetcher = fetcher
        self.compiler = compiler
        self.loader = loader
        self.consentProvider = consentProvider
        self.abiRange = abiRange
    }

    /// Returns a loaded `TSLanguage*` for `language`, or `nil` if it's
    /// unsupported / declined / failed at any stage. Never throws — every
    /// failure is a graceful `nil` (plan §13.3 #5); check `lastError` after
    /// a `nil` result if a caller wants a diagnostic (e.g. `doctor`).
    public func ensureGrammar(language: String) async -> TSLanguageHandle? {
        if let cached = loaded[language] { return TSLanguageHandle(cached) }
        guard !declined.contains(language) else { return nil }

        guard let entry = manifestEntries[language] else {
            lastError = .unsupported(language: language)
            return nil
        }
        guard abiRange.contains(entry.abi) else {
            lastError = .abiIncompatible(language: language, abi: entry.abi, supported: abiRange)
            declined.insert(language)
            return nil
        }

        switch policy {
        case "never":
            lastError = .declined
            declined.insert(language)
            return nil
        case "ask":
            guard await consentProvider.requestConsent(forLanguage: language) else {
                lastError = .declined
                declined.insert(language)
                return nil
            }
        default:
            break // "always" (and any lenient-decode fallback, which CodeGraphConfig already normalizes to "ask")
        }

        do {
            let result = try await downloadCompileAndLoad(entry: entry)
            loaded[language] = result
            return TSLanguageHandle(result)
        } catch {
            lastError = error as? RuntimeGrammarError ?? .compileFailed("\(error)")
            declined.insert(language) // don't retry a doomed pin every single file this session
            return nil
        }
    }

    /// Test/lifecycle seam — forgets declined/cached-failure state so a
    /// language can be retried (e.g. after a manifest pin bump).
    public func resetDeclined() {
        declined.removeAll()
        lastError = nil
    }

    private func downloadCompileAndLoad(entry: RuntimeGrammarManifestEntry) async throws -> OpaquePointer {
        let combined = Self.combinedHash(for: entry)
        let dylibPath = cacheDir.appendingPathComponent("\(entry.language)-\(combined).dylib")

        // Re-verify the cached artifact against the sidecar hash recorded at
        // compile time before `dlopen`-ing it — a cached `.dylib` is native
        // code, and its filename alone (bound to the pin) doesn't detect
        // on-disk tampering after compile (Opus review #4). A missing/mismatched
        // sidecar falls through to a fresh, verified download+compile.
        if FileManager.default.fileExists(atPath: dylibPath.path),
           Self.cachedDylibIsIntact(dylibPath),
           let cached = loader.loadLanguage(dylibPath: dylibPath, symbol: entry.symbol) {
            return cached
        }

        let sourceDir = cacheDir.appendingPathComponent("src", isDirectory: true)
            .appendingPathComponent("\(entry.language)-\(combined)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        var compiledSources: [URL] = []
        for path in entry.files.keys.sorted() {
            guard let expectedSHA = entry.files[path] else { continue }
            guard let url = URL(string: "https://raw.githubusercontent.com/\(entry.repo)/\(entry.commit)/\(path)") else {
                throw RuntimeGrammarError.downloadFailed(path: path)
            }
            let data = try await fetcher.fetch(url: url)
            let actualSHA = Self.sha256Hex(data)
            guard actualSHA == expectedSHA else {
                throw RuntimeGrammarError.hashMismatch(path: path, expected: expectedSHA, actual: actualSHA)
            }
            let dest = sourceDir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: dest)
            if path.hasSuffix(".c") { compiledSources.append(dest) }
        }

        let headerSearchPath = sourceDir.appendingPathComponent(entry.srcdir, isDirectory: true)
        try await compiler.compile(sourceFiles: compiledSources, headerSearchPaths: [headerSearchPath], outputDylib: dylibPath)
        // Record the freshly-compiled artifact's hash so a later cache hit can
        // re-verify it before `dlopen` (Opus review #4).
        Self.recordDylibHash(dylibPath)

        guard let language = loader.loadLanguage(dylibPath: dylibPath, symbol: entry.symbol) else {
            throw RuntimeGrammarError.loadFailed(language: entry.language)
        }
        return language
    }

    /// Sidecar file holding the sha256 of the compiled `.dylib`, written at
    /// compile time and checked on a cache hit.
    private static func dylibSidecarURL(_ dylib: URL) -> URL {
        dylib.appendingPathExtension("sha256")
    }

    /// Best-effort: record the compiled dylib's hash next to it. Failure to
    /// write just means the next cache hit recompiles (safe).
    static func recordDylibHash(_ dylib: URL) {
        guard let data = try? Data(contentsOf: dylib) else { return }
        try? sha256Hex(data).write(to: dylibSidecarURL(dylib), atomically: true, encoding: .utf8)
    }

    /// True only if the cached dylib still matches its recorded sidecar hash.
    /// A missing sidecar (older cache) or any mismatch → false → recompile.
    static func cachedDylibIsIntact(_ dylib: URL) -> Bool {
        guard let expected = try? String(contentsOf: dylibSidecarURL(dylib), encoding: .utf8),
              let data = try? Data(contentsOf: dylib) else { return false }
        return sha256Hex(data) == expected
    }

    /// Cache key suffix: sha256 of the manifest entry's own per-file hashes
    /// (sorted, so key order is deterministic) — changes exactly when the
    /// pin (commit, or a file's content at that commit) changes, which is
    /// what "recompile on pin change" (plan §13.3 #4) hinges on.
    static func combinedHash(for entry: RuntimeGrammarManifestEntry) -> String {
        let joined = entry.files.keys.sorted().map { "\($0)=\(entry.files[$0] ?? "")" }.joined(separator: ";")
        return sha256Hex(Data((entry.commit + "|" + joined).utf8)).prefix(16).description
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
