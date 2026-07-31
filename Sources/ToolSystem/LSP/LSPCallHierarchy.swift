// Sources/ToolSystem/LSP/LSPCallHierarchy.swift
// `textDocument/prepareCallHierarchy` + `callHierarchy/outgoingCalls` /
// `incomingCalls` result parsing (plan §13.1). Pure functions, no I/O — kept
// separate from `LSPBridge`'s transport so `SemanticEdgeEnricherTests` can
// exercise "call-hierarchy parse → resolved calls" against canned JSON
// without spawning a real language server.

import Foundation

/// One `CallHierarchyItem` as defined by the LSP spec — the fields
/// `LSPCallHierarchyEnricher` actually needs. Any other server-specific
/// fields (e.g. Roslyn's opaque `data`) are preserved by round-tripping the
/// *raw JSON text* back to `LSPBridge.outgoingCalls(itemJSON:)` rather than
/// re-encoding this struct — see `LSPBridge.prepareCallHierarchy`.
public struct LSPCallHierarchyItem: Sendable, Equatable {
    public let name: String
    public let uri: String
    public let startLine: Int
    public let startCharacter: Int
    /// The exact JSON object text for this item, as received from the
    /// server — passed back verbatim in follow-up `callHierarchy/*Calls`
    /// requests.
    public let rawJSON: String

    public init(name: String, uri: String, startLine: Int, startCharacter: Int, rawJSON: String) {
        self.name = name
        self.uri = uri
        self.startLine = startLine
        self.startCharacter = startCharacter
        self.rawJSON = rawJSON
    }
}

/// One resolved call edge: `from` called `to` (for outgoing) — the parser
/// only extracts the callee's `name` (`RawEdge.dstName` only needs a name,
/// never a full item; plan §13.1's `EdgeKind.calls` stays name-keyed like
/// every other v1 edge kind, see `SymbolExtractor.swift`).
public struct LSPResolvedCall: Sendable, Equatable {
    public let calleeName: String
    public let calleeURI: String
}

public enum LSPCallHierarchyParser {
    /// Parses a `textDocument/prepareCallHierarchy` response
    /// (`CallHierarchyItem[] | null`) into `LSPCallHierarchyItem`s.
    public static func parseItems(fromJSONText text: String) -> [LSPCallHierarchyItem] {
        guard let data = text.data(using: .utf8),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        return array.compactMap(parseItem)
    }

    private static func parseItem(_ dict: [String: Any]) -> LSPCallHierarchyItem? {
        guard let name = dict["name"] as? String, !name.isEmpty,
              let uri = dict["uri"] as? String,
              let range = dict["range"] as? [String: Any],
              let start = range["start"] as? [String: Any],
              let line = start["line"] as? Int,
              let character = start["character"] as? Int
        else { return nil }
        let rawJSON = (try? JSONSerialization.data(withJSONObject: dict)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return LSPCallHierarchyItem(name: name, uri: uri, startLine: line, startCharacter: character, rawJSON: rawJSON)
    }

    /// Parses a `callHierarchy/outgoingCalls` response
    /// (`CallHierarchyOutgoingCall[] | null`) — each entry's `to` field is
    /// the callee item.
    public static func parseOutgoingCalls(fromJSONText text: String) -> [LSPResolvedCall] {
        guard let data = text.data(using: .utf8),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { entry in
            guard let to = entry["to"] as? [String: Any],
                  let name = to["name"] as? String, !name.isEmpty else { return nil }
            let uri = to["uri"] as? String ?? ""
            return LSPResolvedCall(calleeName: name, calleeURI: uri)
        }
    }

    /// Mirrors `parseOutgoingCalls` for `callHierarchy/incomingCalls`
    /// (`CallHierarchyIncomingCall[] | null`, `from` field) — implemented
    /// for API completeness (plan §13.1 names both directions);
    /// `LSPCallHierarchyEnricher` only consumes outgoing calls today.
    public static func parseIncomingCalls(fromJSONText text: String) -> [LSPResolvedCall] {
        guard let data = text.data(using: .utf8),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { entry in
            guard let from = entry["from"] as? [String: Any],
                  let name = from["name"] as? String, !name.isEmpty else { return nil }
            let uri = from["uri"] as? String ?? ""
            return LSPResolvedCall(calleeName: name, calleeURI: uri)
        }
    }
}
