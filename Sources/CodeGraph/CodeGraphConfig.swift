// Sources/CodeGraph/CodeGraphConfig.swift
// Config for the auto-recorded code graph (plan §6). Mirrors
// `ContextRetrievalConfig`'s lenient-decode shape so a partial `codeGraph`
// object in config.json falls back to these defaults.

import Foundation

public struct CodeGraphConfig: Sendable, Equatable, Codable {
    /// Master switch. Ships **off** — zero behavior change until opted in
    /// (plan §6, §11).
    public var enabled: Bool
    /// Files larger than this are skipped (never read/extracted).
    public var maxFileBytes: Int
    /// Whether the end-of-turn hook enqueues a turn's modified files.
    /// When false, only the session-start scan and `doctor --rebuild-graph`
    /// populate the graph.
    public var indexOnMutation: Bool
    /// Default hop count for `code_graph_explore` when the model omits `depth`.
    public var exploreDepth: Int
    /// M5a (plan §13.4): enable the tree-sitter base tier
    /// (`LanguageServerRegistry`/`TreeSitterExtractor`) for languages with a
    /// vendored tier-1 grammar. Off by default — until opted in, extraction
    /// is byte-for-byte the M1–M4 Swift-only lexical path.
    public var treeSitter: Bool
    /// M5b (plan §13.4): enable async LSP call-hierarchy enrichment
    /// (`SemanticEdgeEnricher`), run off the critical path by the indexer.
    /// Off by default; meaningless (ignored) while `treeSitter` is also off.
    public var callEnrichment: Bool
    /// M5c (plan §13.4): consent policy for on-demand tier-2 grammar
    /// downloads (the long tail beyond Swift/C#/TS/JS). One of
    /// `"ask"` | `"always"` | `"never"`. Conservative default: always ask.
    ///
    /// **RESERVED / not yet active:** the download→verify→compile→load
    /// pipeline (`RuntimeGrammarDownloader`) is implemented and tested, but is
    /// not yet wired into `CodeGraphIndexer`'s live extraction path, and no
    /// tier-2 extractor consumes a dynamically-loaded grammar. Until that
    /// wiring lands, this policy has **no observable effect** — `"always"`
    /// will not download anything during indexing. Kept in the schema so
    /// config written now stays forward-compatible.
    public var grammarDownload: String

    public init(
        enabled: Bool = false,
        maxFileBytes: Int = 1_000_000,
        indexOnMutation: Bool = true,
        exploreDepth: Int = 1,
        treeSitter: Bool = false,
        callEnrichment: Bool = false,
        grammarDownload: String = "ask"
    ) {
        self.enabled = enabled
        self.maxFileBytes = max(1024, maxFileBytes)
        self.indexOnMutation = indexOnMutation
        self.exploreDepth = max(1, min(5, exploreDepth))
        self.treeSitter = treeSitter
        self.callEnrichment = callEnrichment
        switch grammarDownload {
        case "ask", "always", "never": self.grammarDownload = grammarDownload
        default: self.grammarDownload = "ask" // lenient decode: unknown value → conservative default
        }
    }

    /// The disabled default — used everywhere the feature isn't explicitly on.
    public static let disabled = CodeGraphConfig(enabled: false)

    private enum CodingKeys: String, CodingKey {
        case enabled, maxFileBytes, indexOnMutation, exploreDepth
        case treeSitter, callEnrichment, grammarDownload
    }

    public init(from decoder: Decoder) throws {
        let d = CodeGraphConfig()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled,
            maxFileBytes: try c.decodeIfPresent(Int.self, forKey: .maxFileBytes) ?? d.maxFileBytes,
            indexOnMutation: try c.decodeIfPresent(Bool.self, forKey: .indexOnMutation) ?? d.indexOnMutation,
            exploreDepth: try c.decodeIfPresent(Int.self, forKey: .exploreDepth) ?? d.exploreDepth,
            treeSitter: try c.decodeIfPresent(Bool.self, forKey: .treeSitter) ?? d.treeSitter,
            callEnrichment: try c.decodeIfPresent(Bool.self, forKey: .callEnrichment) ?? d.callEnrichment,
            grammarDownload: try c.decodeIfPresent(String.self, forKey: .grammarDownload) ?? d.grammarDownload
        )
    }
}
