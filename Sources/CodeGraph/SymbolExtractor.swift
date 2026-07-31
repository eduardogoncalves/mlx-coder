// Sources/CodeGraph/SymbolExtractor.swift
// Language-agnostic extraction protocol + the shared node/edge data model.

import Foundation

/// Structural kind of a `cg_symbols` row. Free-form on the SQLite side
/// (`kind TEXT`), typed here for extractor-side safety.
public enum SymbolKind: String, Sendable, Equatable, Codable {
    /// Synthetic one-per-file anchor symbol (`qualifiedName == "<file>"`).
    /// Exists so file-level facts (`import` statements, extension-only
    /// conformances) have a legitimate `cg_edges.src_id` to hang off, since
    /// the schema requires every edge to originate from a real symbol row.
    case file
    case function
    case method
    case initializer
    case `class`
    case `struct`
    case `enum`
    case `protocol`
    case actor
    /// Reserved for non-Swift extractors (e.g. HTTP route handlers); unused
    /// by `LexicalSymbolExtractor` in v1.
    case route
}

/// Kind of a `cg_edges` row.
public enum EdgeKind: String, Sendable, Equatable, Codable {
    case imports
    case extends
    case implements
    case references
    /// **Not emitted** by `LexicalSymbolExtractor` (v1) — lexical regex
    /// cannot reliably resolve call sites (trailing closures, method chains,
    /// `self.`, operator overloads, shadowing). See plan §2.1.
    ///
    /// M5 (§13.1) re-enables this: `TreeSitterExtractor` emits *syntactic*
    /// `calls` edges (simple callees only — see its doc comment), and, when
    /// `CodeGraphConfig.callEnrichment` is on and an LSP server is
    /// available, `SemanticEdgeEnricher` upserts higher-confidence
    /// *resolved* `calls` edges over them off the critical path.
    case calls
}

/// A symbol extracted from a single file, before cross-file reference
/// resolution. `qualifiedName` already encodes the full ancestor chain (e.g.
/// `"AgentLoop.processUserMessage(_:images:)"`) — `CodeGraphStore` combines it
/// with the file's path to form the stable `symbol_key`
/// (`<path>::<qualifiedName>`); see plan §3.2. `parent` stores only the
/// *immediate* enclosing symbol's bare name, matching the `cg_symbols.parent`
/// column.
public struct RawSymbol: Sendable, Equatable {
    public let qualifiedName: String
    public let name: String
    public let kind: SymbolKind
    public let parent: String?
    public let startLine: Int
    public let endLine: Int
    public let signature: String?

    public init(
        qualifiedName: String,
        name: String,
        kind: SymbolKind,
        parent: String? = nil,
        startLine: Int,
        endLine: Int,
        signature: String? = nil
    ) {
        self.qualifiedName = qualifiedName
        self.name = name
        self.kind = kind
        self.parent = parent
        self.startLine = startLine
        self.endLine = endLine
        self.signature = signature
    }

    /// `qualifiedName` used by every extractor for the per-file anchor symbol.
    public static let fileAnchorQualifiedName = "<file>"
}

/// A raw (unresolved) edge extracted from a file: a source symbol (identified
/// by its `qualifiedName`, resolved against the *same file's* `RawSymbol`
/// list) pointing at a **by-name** target that may live in another file (or
/// nowhere — e.g. `imports` almost always targets an external module).
/// `CodeGraphStore` keeps `dst_name` even after resolving `dst_id` so a
/// rename or a rebuild can always re-resolve it (plan §3.2).
public struct RawEdge: Sendable, Equatable {
    public let srcQualifiedName: String
    public let dstName: String
    public let kind: EdgeKind

    public init(srcQualifiedName: String, dstName: String, kind: EdgeKind) {
        self.srcQualifiedName = srcQualifiedName
        self.dstName = dstName
        self.kind = kind
    }
}

/// Everything extracted from one file, in phase-1 (per-file, no cross-file
/// awareness) form.
public struct ExtractionResult: Sendable, Equatable {
    public let symbols: [RawSymbol]
    public let edges: [RawEdge]

    public init(symbols: [RawSymbol], edges: [RawEdge]) {
        self.symbols = symbols
        self.edges = edges
    }

    public static let empty = ExtractionResult(symbols: [], edges: [])
}

/// Per-language phase-1 extraction. Implementations must be pure/deterministic
/// (same source → same result) and must never throw — extraction failures
/// degrade to `.empty` so a single malformed file can't poison a batch index
/// run (see `CodeGraphIndexer`, which never lets indexing failures escape into
/// the turn).
public protocol SymbolExtractor: Sendable {
    /// The language identifier this extractor handles (stored in `cg_files.language`).
    var language: String { get }
    /// A stable identity for *how* this extractor produces symbols/edges.
    /// Folded into the content-hash re-index gate (`CodeGraphIndexer.indexOne`)
    /// so that switching extractor for a file — e.g. flipping
    /// `CodeGraphConfig.treeSitter`, which routes a `.swift` file from the
    /// lexical extractor to the tree-sitter one — forces the already-indexed
    /// file to re-index instead of silently retaining its old-format symbols.
    /// Bump the version suffix when an extractor's output format changes; a
    /// grammar *re-pin* (same extractor, new grammar bytes) additionally
    /// warrants a `doctor --rebuild-graph`.
    var extractionVersion: String { get }
    /// Extract symbols/edges from `source`, a file at `path` (repo-relative).
    func extract(path: String, source: String) -> ExtractionResult
}

public extension SymbolExtractor {
    /// Default identity: the concrete type name. Enough to distinguish the
    /// lexical vs. tree-sitter path for any single file (a file's language,
    /// hence its extractor set, is fixed). Extractors whose output depends on
    /// more (e.g. a per-language grammar) should override.
    var extractionVersion: String { String(describing: Self.self) }
}
