// Sources/CodeGraph/CodeGraphExploreTool.swift
// The single agent-facing code graph tool (plan §5.1).

import Foundation

/// Returns, per requested symbol name: its source region, type hierarchy
/// (`extends`/`implements`, walked up to `depth` hops), import/reference
/// neighbors, and a blast-radius-by-name count. This collapses the
/// grep→read→grep loop into one call.
///
/// NB: v1 has no `calls` edges (deferred to M5 — plan §2.1), so this is
/// deliberately **not** a call graph. The tool's own description says so, to
/// avoid over-selling it to the model.
public struct CodeGraphExploreTool: Tool {
    public let name = "code_graph_explore"
    public let description = """
    Look up named code symbols (functions, methods, classes, structs, enums, protocols) in the \
    deterministic code graph. Returns each match's source location, type hierarchy \
    (extends/implements), import and by-name reference neighbors, and a blast-radius count \
    (how many places reference it by name). This is NOT a call graph — it has no function-call \
    edges, only structural ones (imports/inheritance/by-name references). Prefer this over \
    grep+read when you just need "where is X defined and what does it relate to".
    """
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "symbols": PropertySchema(
                type: "array",
                description: "Symbol names to look up (bare name, e.g. 'AgentLoop' or 'processUserMessage').",
                items: PropertySchema(type: "string")
            ),
            "depth": PropertySchema(
                type: "integer",
                description: "How many extends/implements hops to walk up the type hierarchy (default 1, max 5)."
            ),
        ],
        required: ["symbols"]
    )

    private let indexer: CodeGraphIndexer
    private let defaultDepth: Int
    private let maxMatchesPerName: Int
    private let maxVisitedNodes: Int

    public init(indexer: CodeGraphIndexer, defaultDepth: Int = 1, maxMatchesPerName: Int = 3, maxVisitedNodes: Int = 24) {
        self.indexer = indexer
        self.defaultDepth = max(1, min(5, defaultDepth))
        self.maxMatchesPerName = max(1, maxMatchesPerName)
        self.maxVisitedNodes = max(4, maxVisitedNodes)
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        let names = Self.parseNames(arguments["symbols"])
        guard !names.isEmpty else {
            return .error("Missing required argument: symbols (array of symbol names)")
        }
        let depth: Int = {
            if let d = arguments["depth"] as? Int { return max(1, min(5, d)) }
            if let d = arguments["depth"] as? NSNumber { return max(1, min(5, d.intValue)) }
            return defaultDepth
        }()

        let status = await indexer.status()
        guard status.enabled else {
            return .error("Code graph is disabled (codeGraph.enabled=false). Enable it in ~/.mlx-coder/config.json to use this tool.")
        }

        var sections: [String] = []
        if status.pendingCount > 0 {
            sections.append("⚠️ Code graph is stale: \(status.pendingCount) file(s) pending sync — results below may be incomplete.")
        }

        var visited = 0
        for name in names {
            var matches: [CodeGraphStore.SymbolRow] = []
            do {
                matches = try await indexer.store.findSymbols(named: name, limit: maxMatchesPerName)
                if matches.isEmpty {
                    matches = try await indexer.store.searchSymbols(query: name, limit: maxMatchesPerName)
                }
            } catch {
                sections.append("'\(name)': lookup failed (\(error.localizedDescription)).")
                continue
            }
            guard !matches.isEmpty else {
                sections.append("No symbol named '\(name)' found in the code graph.")
                continue
            }
            for match in matches {
                guard visited < maxVisitedNodes else { break }
                visited += 1
                do {
                    sections.append(try await renderSymbol(match, depth: depth))
                } catch {
                    sections.append("'\(match.symbolKey)': failed to load neighbors (\(error.localizedDescription)).")
                }
            }
        }

        return .success(sections.joined(separator: "\n\n"))
    }

    // MARK: - Rendering

    private func renderSymbol(_ symbol: CodeGraphStore.SymbolRow, depth: Int) async throws -> String {
        var lines: [String] = []
        lines.append("### \(symbol.kind) \(symbol.symbolKey)")
        lines.append("\(symbol.path):\(symbol.startLine)-\(symbol.endLine)")
        if let signature = symbol.signature, !signature.isEmpty {
            lines.append("signature: \(signature)")
        }

        let neighbors = try await indexer.store.neighbors(symbolID: symbol.id)
        let outgoing = neighbors?.outgoing ?? []
        let incoming = neighbors?.incoming ?? []

        let hierarchyEdges = outgoing.filter { $0.kind == EdgeKind.extends.rawValue || $0.kind == EdgeKind.implements.rawValue }
        if !hierarchyEdges.isEmpty {
            let hierarchy = try await renderHierarchy(from: symbol, edges: hierarchyEdges, remainingDepth: depth - 1, visited: [symbol.id])
            if !hierarchy.isEmpty { lines.append("hierarchy: \(hierarchy)") }
        }

        let importEdges = outgoing.filter { $0.kind == EdgeKind.imports.rawValue }
        if !importEdges.isEmpty {
            lines.append("imports: " + importEdges.map(\.dstName).joined(separator: ", "))
        }

        let referenceEdges = outgoing.filter { $0.kind == EdgeKind.references.rawValue }
        if !referenceEdges.isEmpty {
            let names = Array(Set(referenceEdges.map(\.dstName))).sorted()
            lines.append("references: " + names.joined(separator: ", "))
        }

        if let neighbors, !incoming.isEmpty {
            let callerPaths = try await Self.describeIncoming(incoming, in: indexer.store, limit: 8)
            lines.append("blast radius (referenced by \(neighbors.blastRadiusCount) symbol(s)): " + callerPaths.joined(separator: ", "))
        }

        return lines.joined(separator: "\n")
    }

    private func renderHierarchy(
        from symbol: CodeGraphStore.SymbolRow,
        edges: [CodeGraphStore.EdgeRow],
        remainingDepth: Int,
        visited: Set<Int64>
    ) async throws -> String {
        var parts: [String] = []
        for edge in edges {
            let label = edge.kind == EdgeKind.extends.rawValue ? "extends \(edge.dstName)" : "implements \(edge.dstName)"
            guard remainingDepth > 0, let dstId = edge.dstId, !visited.contains(dstId),
                  let dstSymbol = try await indexer.store.symbol(id: dstId) else {
                parts.append(label)
                continue
            }
            let dstOutgoing = try await indexer.store.outgoingEdges(symbolID: dstId)
            let dstHierarchy = dstOutgoing.filter { $0.kind == EdgeKind.extends.rawValue || $0.kind == EdgeKind.implements.rawValue }
            if dstHierarchy.isEmpty {
                parts.append(label)
            } else {
                let nested = try await renderHierarchy(
                    from: dstSymbol, edges: dstHierarchy, remainingDepth: remainingDepth - 1, visited: visited.union([dstId])
                )
                parts.append(nested.isEmpty ? label : "\(label) → \(nested)")
            }
        }
        return parts.joined(separator: ", ")
    }

    private static func describeIncoming(_ edges: [CodeGraphStore.EdgeRow], in store: CodeGraphStore, limit: Int) async throws -> [String] {
        var seen = Set<Int64>()
        var out: [String] = []
        for edge in edges {
            guard out.count < limit else { break }
            guard seen.insert(edge.srcId).inserted else { continue }
            if let src = try await store.symbol(id: edge.srcId) {
                out.append("\(src.symbolKey) (\(edge.kind))")
            }
        }
        return out
    }

    // MARK: - Argument parsing

    private static func parseNames(_ raw: Any?) -> [String] {
        guard let array = raw as? [Any] else {
            if let single = raw as? String {
                let trimmed = single.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? [] : [trimmed]
            }
            return []
        }
        var seen = Set<String>()
        var out: [String] = []
        for element in array {
            guard let s = element as? String else { continue }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }
}
