// Sources/CodeGraph/SemanticEdgeEnricher.swift
// M5b LSP enrichment (plan §13.1) — a new ASYNC sibling protocol to the sync
// `SymbolExtractor`, deliberately NOT overloaded onto it. Backed by LSP
// call-hierarchy (`textDocument/prepareCallHierarchy` +
// `callHierarchy/outgoingCalls`), which supersedes `TreeSitterExtractor`'s
// syntactic `calls` sites when a server is present and responsive.
//
// Graceful degrade (plan §13.3 rail #5) is load-bearing here, not
// decoration: no LSP entry for the language, a server that fails to start,
// a per-symbol timeout, or a malformed response must each fall back to
// "keep the syntactic edges" — `enrichCalls` therefore never `throws` and
// swallows every failure into an empty/partial result.

import Foundation

/// Resolves `calls` edges for one file's already-extracted symbols via an
/// external, asynchronous source (LSP call-hierarchy today; conceivably
/// something else later). Kept separate from `SymbolExtractor` because it
/// is inherently async/optional/best-effort, unlike the sync base tier.
public protocol SemanticEdgeEnricher: Sendable {
    /// `symbols` is the file's freshly-extracted `RawSymbol`s (from whichever
    /// base extractor ran). Returns resolved `calls` edges — callers are
    /// expected to treat this as authoritative and REPLACE the file's prior
    /// syntactic `calls` edges (see `CodeGraphStore.replaceCallEdges`), not
    /// merge/append, since the enricher re-derives the full set each time.
    /// Never throws: every failure (no server for this language, server
    /// unavailable, timeout, malformed response) degrades to a smaller (or
    /// empty) result, never an error into the turn.
    func enrichCalls(path: String, symbols: [RawSymbol]) async -> [RawEdge]
}

/// LSP-call-hierarchy-backed `SemanticEdgeEnricher`. One instance is meant
/// to live for the process's lifetime (or at least a session) so its
/// per-language `LSPBridge` instances are reused rather than
/// spawned-and-killed per file — starting a language server is expensive.
///
/// This is an `actor` (not just a `struct` wrapping an actor) because it
/// owns genuinely mutable, non-`Sendable`-safe-without-isolation state: the
/// `bridges` cache and the `languageStartFailed` short-circuit set.
public actor LSPCallHierarchyEnricher: SemanticEdgeEnricher {
    private let registry: LanguageServerRegistry
    private let permissions: PermissionEngine
    /// One `LSPBridge` per language, lazily started and reused. A language
    /// whose server never starts (missing binary, crashes) is recorded in
    /// `languageStartFailed` so every subsequent file in that language
    /// short-circuits to "no enrichment" instead of re-attempting (and
    /// re-timing-out) a doomed launch on every single file.
    private var bridges: [String: LSPBridge] = [:]
    private var languageStartFailed: Set<String> = []

    public init(registry: LanguageServerRegistry = .standard, permissions: PermissionEngine) {
        self.registry = registry
        self.permissions = permissions
    }

    public func enrichCalls(path: String, symbols: [RawSymbol]) async -> [RawEdge] {
        guard let entry = registry.entry(forPath: path), let spec = entry.lspServer else { return [] }
        guard !languageStartFailed.contains(entry.language) else { return [] }

        let absPath = permissions.resolveAbsolutePath(path)
        guard let source = try? String(contentsOfFile: absPath, encoding: .utf8) else { return [] }
        let lines = source.components(separatedBy: "\n")

        guard let bridge = await bridge(forLanguage: entry.language, spec: spec) else { return [] }

        var edges: [RawEdge] = []
        for symbol in symbols {
            guard symbol.kind == .function || symbol.kind == .method || symbol.kind == .initializer else { continue }
            guard let character = Self.column(ofName: symbol.name, onLine: symbol.startLine, in: lines) else { continue }
            do {
                let itemsJSON = try await bridge.prepareCallHierarchy(
                    filePath: absPath, line: symbol.startLine - 1, character: character
                )
                guard let item = LSPCallHierarchyParser.parseItems(fromJSONText: itemsJSON).first else { continue }
                let callsJSON = try await bridge.outgoingCalls(itemJSON: item.rawJSON)
                for call in LSPCallHierarchyParser.parseOutgoingCalls(fromJSONText: callsJSON) {
                    edges.append(RawEdge(srcQualifiedName: symbol.qualifiedName, dstName: call.calleeName, kind: .calls))
                }
            } catch {
                // Per-symbol degrade — one timed-out/erroring symbol must not
                // drop enrichment for the rest of the file (plan §13.3 #5).
                continue
            }
        }
        return edges
    }

    /// Drops every cached bridge (shuts each server down first). Used by
    /// tests and by any future "workspace changed" seam; not required for
    /// normal operation.
    public func reset() async {
        for (_, bridge) in bridges { await bridge.shutdown() }
        bridges.removeAll()
        languageStartFailed.removeAll()
    }

    private func bridge(forLanguage language: String, spec: LSPServerSpec) async -> LSPBridge? {
        if let existing = bridges[language] { return existing }
        let newBridge = LSPBridge(serverSpec: spec)
        do {
            try await newBridge.start(workspacePath: URL(fileURLWithPath: permissions.workspaceRoot))
        } catch {
            languageStartFailed.insert(language)
            return nil
        }
        bridges[language] = newBridge
        return newBridge
    }

    /// 0-based LSP character offset of the first occurrence of `name` on
    /// `startLine` (1-based, matching `RawSymbol.startLine`). `RawSymbol`
    /// intentionally carries no column (plan's node/edge model is
    /// line-only, matching `cg_symbols.start_line`), so this is a
    /// best-effort re-derivation from source text — good enough to land
    /// `prepareCallHierarchy`'s position argument on the identifier token;
    /// a miss just means that symbol gets no enrichment (degrade, not throw).
    static func column(ofName name: String, onLine startLine: Int, in lines: [String]) -> Int? {
        guard startLine >= 1, startLine - 1 < lines.count, !name.isEmpty else { return nil }
        let line = lines[startLine - 1]
        guard let range = line.range(of: name) else { return nil }
        return line.distance(from: line.startIndex, to: range.lowerBound)
    }
}
