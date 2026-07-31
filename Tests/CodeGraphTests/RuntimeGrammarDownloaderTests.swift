// Tests/CodeGraphTests/RuntimeGrammarDownloaderTests.swift
// M5c on-demand tier-2 grammar download/compile/dlopen (plan §13.5).
// Network, compilation, and dynamic loading are ALL mocked here — no real
// download, no real clang invocation, no real dlopen — per the plan's
// explicit requirement ("Tests MUST mock network/compile — do not require
// real downloads").

import XCTest
@testable import MLXCoder

// MARK: - Fakes

private actor FakeGrammarFetcher: GrammarNetworkFetching {
    private let contentByURL: [String: Data]
    private(set) var fetchCount = 0

    init(contentByURL: [String: Data]) {
        self.contentByURL = contentByURL
    }

    func fetch(url: URL) async throws -> Data {
        fetchCount += 1
        guard let data = contentByURL[url.absoluteString] else {
            throw RuntimeGrammarError.downloadFailed(path: url.absoluteString)
        }
        return data
    }
}

private actor FakeGrammarCompiler: GrammarCompiling {
    private(set) var compileCount = 0
    var shouldFail = false

    func setShouldFail(_ value: Bool) { shouldFail = value }

    func compile(sourceFiles: [URL], headerSearchPaths: [URL], outputDylib: URL) async throws {
        compileCount += 1
        if shouldFail { throw RuntimeGrammarError.compileFailed("forced test failure") }
        // Simulate a successful compile by writing a placeholder file — the
        // fake loader below never actually dlopens it, it just checks
        // existence + returns a canned handle.
        try FileManager.default.createDirectory(at: outputDylib.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fake dylib".utf8).write(to: outputDylib)
    }
}

/// Returns a distinct non-null `OpaquePointer` for any dylib path that
/// exists on disk (as the fake compiler writes), simulating a successful
/// `dlopen`+`dlsym`+call — never touches real `dlopen`.
private struct FakeGrammarLoader: GrammarDynamicLoading {
    var shouldFail = false

    func loadLanguage(dylibPath: URL, symbol: String) -> OpaquePointer? {
        guard !shouldFail, FileManager.default.fileExists(atPath: dylibPath.path) else { return nil }
        // A fixed non-null bit pattern — never dereferenced, just used as a
        // "the language loaded" sentinel by these tests.
        return OpaquePointer(bitPattern: 0x1)
    }
}

private actor RecordingConsentProvider: GrammarDownloadConsentProvider {
    private let decision: Bool
    private(set) var requestedLanguages: [String] = []

    init(decision: Bool) { self.decision = decision }

    func requestConsent(forLanguage language: String) async -> Bool {
        requestedLanguages.append(language)
        return decision
    }
}

// MARK: - Fixture entry (mirrors the real "lua" tier2 manifest entry shape)

private func makeLuaEntry(abi: Int = 15) -> RuntimeGrammarManifestEntry {
    RuntimeGrammarManifestEntry(
        language: "lua",
        repo: "tree-sitter-grammars/tree-sitter-lua",
        commit: "deadbeef",
        srcdir: "src",
        symbol: "tree_sitter_lua",
        abi: abi,
        hasScanner: true,
        files: [
            "src/parser.c": RuntimeGrammarManagerTests.sha256Hex(Data("PARSER".utf8)),
            "src/scanner.c": RuntimeGrammarManagerTests.sha256Hex(Data("SCANNER".utf8)),
        ]
    )
}

private func urlFor(_ entry: RuntimeGrammarManifestEntry, _ path: String) -> String {
    "https://raw.githubusercontent.com/\(entry.repo)/\(entry.commit)/\(path)"
}

final class RuntimeGrammarManagerTests: XCTestCase {

    static func sha256Hex(_ data: Data) -> String {
        RuntimeGrammarManager.sha256Hex(data)
    }

    private var cacheDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        cacheDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("test-workspaces", isDirectory: true)
            .appendingPathComponent("grammar-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: cacheDir)
        try await super.tearDown()
    }

    // MARK: - Unsupported language

    func testUnknownLanguageReturnsNilWithoutTouchingNetwork() async {
        let fetcher = FakeGrammarFetcher(contentByURL: [:])
        let manager = RuntimeGrammarManager(
            manifestEntries: [:], policy: "always", cacheDir: cacheDir,
            fetcher: fetcher, compiler: FakeGrammarCompiler(), loader: FakeGrammarLoader()
        )
        let result = await manager.ensureGrammar(language: "cobol")
        XCTAssertNil(result)
        let fetchCount = await fetcher.fetchCount
        XCTAssertEqual(fetchCount, 0)
    }

    // MARK: - ABI compatibility (plan §13.3 #3)

    func testABIOutOfRangeIsRefusedBeforeAnyNetworkCall() async {
        let entry = makeLuaEntry(abi: 99) // deliberately incompatible
        let fetcher = FakeGrammarFetcher(contentByURL: [:])
        let manager = RuntimeGrammarManager(
            manifestEntries: ["lua": entry], policy: "always", cacheDir: cacheDir,
            fetcher: fetcher, compiler: FakeGrammarCompiler(), loader: FakeGrammarLoader()
        )
        let result = await manager.ensureGrammar(language: "lua")
        XCTAssertNil(result)
        let fetchCount = await fetcher.fetchCount
        XCTAssertEqual(fetchCount, 0, "ABI check must happen before any download")
    }

    // MARK: - Consent (plan §13.3 #1)

    func testPolicyNeverDeclinesWithoutPromptingOrDownloading() async {
        let entry = makeLuaEntry()
        let fetcher = FakeGrammarFetcher(contentByURL: [:])
        let consent = RecordingConsentProvider(decision: true)
        let manager = RuntimeGrammarManager(
            manifestEntries: ["lua": entry], policy: "never", cacheDir: cacheDir,
            fetcher: fetcher, compiler: FakeGrammarCompiler(), loader: FakeGrammarLoader(),
            consentProvider: consent
        )
        let result = await manager.ensureGrammar(language: "lua")
        XCTAssertNil(result)
        let requested = await consent.requestedLanguages
        XCTAssertTrue(requested.isEmpty, "policy=never must never consult the consent provider")
        let fetchCount = await fetcher.fetchCount
        XCTAssertEqual(fetchCount, 0)
    }

    func testPolicyAskConsultsProviderAndDeclinesOnRefusal() async {
        let entry = makeLuaEntry()
        let fetcher = FakeGrammarFetcher(contentByURL: [:])
        let consent = RecordingConsentProvider(decision: false)
        let manager = RuntimeGrammarManager(
            manifestEntries: ["lua": entry], policy: "ask", cacheDir: cacheDir,
            fetcher: fetcher, compiler: FakeGrammarCompiler(), loader: FakeGrammarLoader(),
            consentProvider: consent
        )
        let result = await manager.ensureGrammar(language: "lua")
        XCTAssertNil(result)
        let requested = await consent.requestedLanguages
        XCTAssertEqual(requested, ["lua"])
        let fetchCount = await fetcher.fetchCount
        XCTAssertEqual(fetchCount, 0, "declining consent must skip the download entirely")
    }

    func testDecliningDefaultProviderNeverDownloads() async {
        // The safe-by-default provider used when nothing interactive is wired up.
        let entry = makeLuaEntry()
        let fetcher = FakeGrammarFetcher(contentByURL: [:])
        let manager = RuntimeGrammarManager(
            manifestEntries: ["lua": entry], policy: "ask", cacheDir: cacheDir,
            fetcher: fetcher, compiler: FakeGrammarCompiler(), loader: FakeGrammarLoader()
        )
        let result = await manager.ensureGrammar(language: "lua")
        XCTAssertNil(result)
    }

    // MARK: - Happy path (policy=always, consent never consulted)

    func testPolicyAlwaysDownloadsVerifiesCompilesAndLoads() async {
        let entry = makeLuaEntry()
        let parserData = Data("PARSER".utf8)
        let scannerData = Data("SCANNER".utf8)
        let fetcher = FakeGrammarFetcher(contentByURL: [
            urlFor(entry, "src/parser.c"): parserData,
            urlFor(entry, "src/scanner.c"): scannerData,
        ])
        let compiler = FakeGrammarCompiler()
        let consent = RecordingConsentProvider(decision: true)
        let manager = RuntimeGrammarManager(
            manifestEntries: ["lua": entry], policy: "always", cacheDir: cacheDir,
            fetcher: fetcher, compiler: compiler, loader: FakeGrammarLoader(),
            consentProvider: consent
        )

        let result = await manager.ensureGrammar(language: "lua")
        XCTAssertNotNil(result)
        let requested = await consent.requestedLanguages
        XCTAssertTrue(requested.isEmpty, "policy=always must never consult the consent provider")
        let compileCount = await compiler.compileCount
        XCTAssertEqual(compileCount, 1)

        // Second call hits the in-memory cache — no re-fetch, no re-compile.
        let second = await manager.ensureGrammar(language: "lua")
        XCTAssertNotNil(second)
        let fetchCountAfter = await fetcher.fetchCount
        let compileCountAfter = await compiler.compileCount
        XCTAssertEqual(fetchCountAfter, 2, "still just the first ensureGrammar's two files")
        XCTAssertEqual(compileCountAfter, 1, "second call must be served from the in-memory cache")
    }

    func testOnDiskDylibCacheIsReusedAcrossManagerInstances() async {
        let entry = makeLuaEntry()
        let fetcher = FakeGrammarFetcher(contentByURL: [
            urlFor(entry, "src/parser.c"): Data("PARSER".utf8),
            urlFor(entry, "src/scanner.c"): Data("SCANNER".utf8),
        ])
        let compiler = FakeGrammarCompiler()
        let firstManager = RuntimeGrammarManager(
            manifestEntries: ["lua": entry], policy: "always", cacheDir: cacheDir,
            fetcher: fetcher, compiler: compiler, loader: FakeGrammarLoader()
        )
        let first = await firstManager.ensureGrammar(language: "lua")
        XCTAssertNotNil(first)

        // A brand-new manager instance (simulating a new process) with a
        // fetcher that would fail any request — the on-disk dylib cache
        // (keyed by name+hash, plan §13.3 #4) must be reused without any
        // network access.
        let failingFetcher = FakeGrammarFetcher(contentByURL: [:])
        let secondManager = RuntimeGrammarManager(
            manifestEntries: ["lua": entry], policy: "always", cacheDir: cacheDir,
            fetcher: failingFetcher, compiler: FakeGrammarCompiler(), loader: FakeGrammarLoader()
        )
        let second = await secondManager.ensureGrammar(language: "lua")
        XCTAssertNotNil(second, "expected the on-disk cached dylib to be reused")
        let failingFetchCount = await failingFetcher.fetchCount
        XCTAssertEqual(failingFetchCount, 0)
    }

    // MARK: - sha256 verification (plan §13.3 #2)

    func testHashMismatchIsRefusedAndNeverCompiled() async {
        let entry = makeLuaEntry()
        // Serve WRONG content for parser.c (doesn't match the manifest's pin).
        let fetcher = FakeGrammarFetcher(contentByURL: [
            urlFor(entry, "src/parser.c"): Data("TAMPERED".utf8),
            urlFor(entry, "src/scanner.c"): Data("SCANNER".utf8),
        ])
        let compiler = FakeGrammarCompiler()
        let manager = RuntimeGrammarManager(
            manifestEntries: ["lua": entry], policy: "always", cacheDir: cacheDir,
            fetcher: fetcher, compiler: compiler, loader: FakeGrammarLoader()
        )
        let result = await manager.ensureGrammar(language: "lua")
        XCTAssertNil(result)
        let compileCount = await compiler.compileCount
        XCTAssertEqual(compileCount, 0, "a hash mismatch must never reach the compiler")
    }

    // MARK: - Compile / dlopen failure degrade gracefully

    func testCompileFailureDegradesToNilWithoutThrowing() async {
        let entry = makeLuaEntry()
        let fetcher = FakeGrammarFetcher(contentByURL: [
            urlFor(entry, "src/parser.c"): Data("PARSER".utf8),
            urlFor(entry, "src/scanner.c"): Data("SCANNER".utf8),
        ])
        let compiler = FakeGrammarCompiler()
        await compiler.setShouldFail(true)
        let manager = RuntimeGrammarManager(
            manifestEntries: ["lua": entry], policy: "always", cacheDir: cacheDir,
            fetcher: fetcher, compiler: compiler, loader: FakeGrammarLoader()
        )
        let result = await manager.ensureGrammar(language: "lua")
        XCTAssertNil(result)
    }

    func testDlopenFailureDegradesToNilWithoutThrowing() async {
        let entry = makeLuaEntry()
        let fetcher = FakeGrammarFetcher(contentByURL: [
            urlFor(entry, "src/parser.c"): Data("PARSER".utf8),
            urlFor(entry, "src/scanner.c"): Data("SCANNER".utf8),
        ])
        let manager = RuntimeGrammarManager(
            manifestEntries: ["lua": entry], policy: "always", cacheDir: cacheDir,
            fetcher: fetcher, compiler: FakeGrammarCompiler(), loader: FakeGrammarLoader(shouldFail: true)
        )
        let result = await manager.ensureGrammar(language: "lua")
        XCTAssertNil(result)
    }

    // MARK: - Manifest parsing

    func testLoadTier2ParsesTheRealCheckedInManifest() {
        let manifestURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("grammars/manifest.json")
        let entries = RuntimeGrammarManifest.loadTier2(from: manifestURL)
        guard let lua = entries["lua"] else { return XCTFail("expected a 'lua' tier2 entry in grammars/manifest.json") }
        XCTAssertEqual(lua.symbol, "tree_sitter_lua")
        XCTAssertTrue(RuntimeGrammarManager.supportedABIRange.contains(lua.abi))
        XCTAssertFalse(lua.files.isEmpty)
    }

    func testLoadTier2ToleratesMissingFile() {
        let entries = RuntimeGrammarManifest.loadTier2(from: URL(fileURLWithPath: "/nonexistent/manifest.json"))
        XCTAssertEqual(entries, [:])
    }
}
