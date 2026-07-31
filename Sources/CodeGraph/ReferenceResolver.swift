// Sources/CodeGraph/ReferenceResolver.swift
// Phase-2 join: unresolved by-name edges (`dst_name`) → symbol keys.

import Foundation

/// Drives the second half of the plan's two-phase resolution model (plan §3,
/// §10.3): `LexicalSymbolExtractor` (phase 1) only ever sees one file at a
/// time, so `extends`/`implements`/`references`/`imports` edges are recorded
/// with just a target *name*. `CodeGraphStore.upsertFile` performs a
/// best-effort immediate resolution against whatever is already indexed, but
/// the defining file may not have been indexed yet (or may be indexed again
/// later under a rename) — `ReferenceResolver` is what catches up dangling
/// in-edges once the target's symbol actually lands.
///
/// This is intentionally a thin façade over `CodeGraphStore` rather than
/// owning any SQL itself: it exists as its own file/type so the "two-phase
/// resolution" step in the indexing pipeline (extract → store → **resolve**)
/// has a single, testable named entry point, per the plan's module table (§3).
public enum ReferenceResolver {
    /// For each freshly (re)inserted symbol, re-resolve any dangling in-edge
    /// elsewhere in the graph whose `dst_name` matches its bare name. Returns
    /// the total number of edges resolved.
    @discardableResult
    public static func resolveNewSymbols(
        _ symbols: [CodeGraphStore.SymbolRow],
        in store: CodeGraphStore
    ) async throws -> Int {
        var resolved = 0
        for symbol in symbols {
            resolved += try await store.resolveDanglingEdges(matchingName: symbol.name, resolvedSymbolID: symbol.id)
        }
        return resolved
    }
}
