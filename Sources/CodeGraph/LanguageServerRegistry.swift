// Sources/CodeGraph/LanguageServerRegistry.swift
// Per-language routing table (plan §13.1, §13.3): file extension → base
// (sync) extractor, generalized in M5b (Phase C) to also carry an optional
// LSP server spec (binary, args, install hint) so `LSPBridge`'s existing
// generic JSON-RPC transport can be reused for languages beyond C#.
//
// Phase B (M5a) only needs the base-extractor half of this table. It is
// intentionally the single place that knows "which extension maps to which
// language" so `CodeGraphIndexer` doesn't hardcode a Swift-only switch
// anymore — see `CodeGraphIndexer.language(forPath:)` /
// `CodeGraphIndexer.extractor(for:config:)`.

import Foundation

/// One row of the registry: everything the indexer needs to go from a file
/// extension to an extraction strategy.
public struct LanguageServerRegistryEntry: Sendable {
    /// `cg_files.language` value for this row (matches `TreeSitterLanguageID.rawValue`
    /// for tree-sitter-backed languages, or a bespoke id like `"swift"` for
    /// the lexical-only fallback path).
    public let language: String
    /// Base-tier extractor used when tree-sitter is unavailable/disabled for
    /// this language (nil ⇒ no fallback; the file is simply skipped, same as
    /// M1–M4 behavior for every non-Swift language today).
    public let lexicalFallback: SymbolExtractor?
    /// Base-tier tree-sitter extractor, used when `CodeGraphConfig.treeSitter`
    /// is on and this language has a vendored tier-1 grammar (plan §13.2).
    public let treeSitterLanguageID: TreeSitterLanguageID?
    /// LSP server spec for M5b call-hierarchy enrichment (Phase C). `nil` in
    /// Phase B for every language — populated once `LanguageServerRegistry`
    /// grows the LSP half of the table.
    public let lspServer: LSPServerSpec?

    public init(
        language: String,
        lexicalFallback: SymbolExtractor? = nil,
        treeSitterLanguageID: TreeSitterLanguageID? = nil,
        lspServer: LSPServerSpec? = nil
    ) {
        self.language = language
        self.lexicalFallback = lexicalFallback
        self.treeSitterLanguageID = treeSitterLanguageID
        self.lspServer = lspServer
    }
}

/// Static extension → language routing table. A `struct` (not an actor) —
/// every entry is `Sendable` and the table itself never mutates after
/// `standard`, so it's safe to read from any isolation context without
/// synchronization (mirrors `BuildOutputFilter`'s plain-`enum`-of-statics
/// style elsewhere in this module).
public struct LanguageServerRegistry: Sendable {
    private let entriesByExtension: [String: LanguageServerRegistryEntry]

    public init(entriesByExtension: [String: LanguageServerRegistryEntry]) {
        self.entriesByExtension = entriesByExtension
    }

    /// The registry used everywhere in production. A distinct `init` is kept
    /// public so tests can construct a scoped-down table without touching
    /// this one.
    public static let standard: LanguageServerRegistry = {
        var table: [String: LanguageServerRegistryEntry] = [:]
        let swiftEntry = LanguageServerRegistryEntry(
            language: "swift",
            lexicalFallback: LexicalSymbolExtractor(),
            treeSitterLanguageID: .swift,
            lspServer: LSPServerSpec.sourcekitLSP
        )
        table["swift"] = swiftEntry

        let csharpEntry = LanguageServerRegistryEntry(
            language: "csharp",
            lexicalFallback: nil, // no C# lexical extractor exists (M1 was Swift-only)
            treeSitterLanguageID: .csharp,
            lspServer: LSPServerSpec.csharpLS
        )
        table["cs"] = csharpEntry

        let jsEntry = LanguageServerRegistryEntry(
            language: "javascript",
            lexicalFallback: nil,
            treeSitterLanguageID: .javascript,
            lspServer: LSPServerSpec.typescriptLanguageServer
        )
        table["js"] = jsEntry
        table["jsx"] = jsEntry

        let tsEntry = LanguageServerRegistryEntry(
            language: "typescript",
            lexicalFallback: nil,
            treeSitterLanguageID: .typescript,
            lspServer: LSPServerSpec.typescriptLanguageServer
        )
        table["ts"] = tsEntry

        return LanguageServerRegistry(entriesByExtension: table)
    }()

    public func entry(forPath path: String) -> LanguageServerRegistryEntry? {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return entriesByExtension[ext]
    }

    /// All extensions this registry knows how to route (used by
    /// `CodeGraphIndexer.discoverSourceFiles` for candidate discovery —
    /// discovery is intentionally always "generous": whether a discovered
    /// file is actually extracted still depends on `CodeGraphConfig` at
    /// enqueue/extract time).
    public var knownExtensions: Set<String> { Set(entriesByExtension.keys) }

    /// Resolve the extractor to use for `path`, given the current config.
    /// Encodes the base-tier fallback order from plan §13.1: tree-sitter (if
    /// enabled and a grammar is vendored) → lexical fallback (if any) → nil
    /// (file skipped, unchanged from M1–M4 behavior).
    public func extractor(forPath path: String, treeSitterEnabled: Bool) -> SymbolExtractor? {
        guard let entry = entry(forPath: path) else { return nil }
        if treeSitterEnabled, let languageID = entry.treeSitterLanguageID {
            return TreeSitterExtractor(languageID: languageID)
        }
        return entry.lexicalFallback
    }

    /// `cg_files.language` for `path`, independent of whether an extractor
    /// is actually available for it right now (drives the indexer's pending
    /// set: "known extension, maybe-fallback-only" vs. truly unsupported).
    public func language(forPath path: String) -> String? {
        entry(forPath: path)?.language
    }
}
