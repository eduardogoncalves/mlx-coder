// Sources/CodeGraph/TreeSitterExtractor.swift
// Base-tier tree-sitter extractor (plan §13.1, §13.2 tier-1): nodes +
// imports/extends/implements/references AND syntactic `calls` sites, for the
// vendored core grammars (Swift, C#, JavaScript, TypeScript). Conforms to the
// same synchronous `SymbolExtractor` protocol as `LexicalSymbolExtractor` —
// it is a drop-in, more-accurate replacement selected by
// `LanguageServerRegistry` when `CodeGraphConfig.treeSitter` is on and a
// grammar is available; unsupported languages / parse failures degrade to
// `.empty` (never throw) so the indexer falls back to the lexical extractor
// or silently skips the file (see `SymbolExtractor`'s protocol doc).
//
// Ground truth for every node/field name below was captured empirically by
// parsing small fixtures with the actual vendored grammars and inspecting
// `ts_node_string` + each grammar's `node-types.json` (not guessed from
// memory) — see the golden fixtures in `TreeSitterExtractorTests`.
//
// Known, accepted limitations (documented, same spirit as
// `LexicalSymbolExtractor`'s doc comment):
//  - `calls` edges only resolve simple callees (`foo(...)`, `self.foo(...)`,
//    `obj.Method(...)`) — subscripts, closures-as-callees, and other complex
//    callee expressions are skipped rather than guessed.
//  - `references` reuses the same coarse "capitalized identifier in this
//    symbol's source slice" heuristic as `LexicalSymbolExtractor` (applied
//    per-language over each symbol's byte range) rather than a resolved
//    type-check.
//  - Swift `extension Foo { ... }` bodies emit no symbol for `Foo` itself
//    (mirrors `LexicalSymbolExtractor`'s documented choice), but nested
//    members are still scoped under `Foo.` in their `qualifiedName` so their
//    `symbol_key`s read naturally.

import Foundation
import CTreeSitter
import CTreeSitterSwift
import CTreeSitterCSharp
import CTreeSitterJavaScript
import CTreeSitterTypeScript

/// Identifies one of the vendored tier-1 grammars (plan §13.2). The raw
/// value is both `cg_files.language` and the `LanguageServerRegistry` key.
public enum TreeSitterLanguageID: String, Sendable, CaseIterable {
    case swift
    case csharp
    case javascript
    case typescript

    /// `nil` only if a future grammar entry forgets to wire its `tree_sitter_*`
    /// getter here — every case below is one of the four vendored targets.
    var tsLanguage: OpaquePointer? {
        switch self {
        case .swift: return tree_sitter_swift()
        case .csharp: return tree_sitter_c_sharp()
        case .javascript: return tree_sitter_javascript()
        case .typescript: return tree_sitter_typescript()
        }
    }
}

public struct TreeSitterExtractor: SymbolExtractor {
    public let language: String
    let languageID: TreeSitterLanguageID

    /// Per-language identity so flipping `treeSitter` (lexical → tree-sitter)
    /// re-indexes the file (see `SymbolExtractor.extractionVersion`). Bump the
    /// suffix after a grammar re-pin if you want automatic invalidation rather
    /// than relying on `doctor --rebuild-graph`.
    public var extractionVersion: String { "treesitter-\(language)-v1" }

    public init(languageID: TreeSitterLanguageID) {
        self.languageID = languageID
        self.language = languageID.rawValue
    }

    public func extract(path: String, source: String) -> ExtractionResult {
        let fileName = (path as NSString).lastPathComponent
        guard !source.isEmpty else {
            let anchor = RawSymbol(
                qualifiedName: RawSymbol.fileAnchorQualifiedName,
                name: fileName, kind: .file, parent: nil,
                startLine: 1, endLine: 1, signature: nil
            )
            return ExtractionResult(symbols: [anchor], edges: [])
        }
        guard let tsLang = languageID.tsLanguage else { return .empty }

        let bytes = Array(source.utf8)
        guard let parser = ts_parser_new() else { return .empty }
        defer { ts_parser_delete(parser) }
        guard ts_parser_set_language(parser, tsLang) else { return .empty }

        guard let tree = bytes.withUnsafeBufferPointer({ buf -> OpaquePointer? in
            guard let base = buf.baseAddress else { return nil }
            return base.withMemoryRebound(to: CChar.self, capacity: buf.count) { cstr in
                ts_parser_parse_string(parser, nil, cstr, UInt32(buf.count))
            }
        }) else { return .empty }
        defer { ts_tree_delete(tree) }

        let root = ts_tree_root_node(tree)
        guard !ts_node_is_null(root) else { return .empty }

        let totalLines = source.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        var walker = TSWalker(bytes: bytes)
        var builders: [TSBuilding] = [
            TSBuilding(
                qualifiedName: RawSymbol.fileAnchorQualifiedName, name: fileName,
                kind: .file, parent: nil, startLine: 1, endLine: totalLines, signature: nil
            )
        ]

        switch languageID {
        case .swift:
            walker.walkSwift(root, scope: nil, into: &builders)
        case .csharp:
            walker.walkCSharp(root, scope: nil, into: &builders)
        case .javascript, .typescript:
            walker.walkJSFamily(root, scope: nil, into: &builders)
        }

        var edges = walker.edges
        edges.append(contentsOf: TSReferenceHeuristic.extractReferences(bytes: bytes, symbols: builders))

        let symbols = builders.map {
            RawSymbol(
                qualifiedName: $0.qualifiedName, name: $0.name, kind: $0.kind,
                parent: $0.parent, startLine: $0.startLine, endLine: $0.endLine, signature: $0.signature
            )
        }
        return ExtractionResult(symbols: symbols, edges: edges)
    }
}

// MARK: - Shared builder type (mirrors LexicalSymbolExtractor.Building)

struct TSBuilding {
    var qualifiedName: String
    var name: String
    var kind: SymbolKind
    var parent: String?
    var startLine: Int
    var endLine: Int
    var signature: String?
}

private struct TSScope {
    let qualifiedName: String
    let displayName: String
}

// MARK: - Low-level TSNode helpers

private func tsTypeName(_ node: TSNode) -> String {
    guard !ts_node_is_null(node), let cstr = ts_node_type(node) else { return "" }
    return String(cString: cstr)
}

private func tsField(_ node: TSNode, _ name: String) -> TSNode? {
    let result = name.withCString { ts_node_child_by_field_name(node, $0, UInt32(name.utf8.count)) }
    return ts_node_is_null(result) ? nil : result
}

private func tsNamedChildren(_ node: TSNode) -> [TSNode] {
    guard !ts_node_is_null(node) else { return [] }
    let count = ts_node_named_child_count(node)
    guard count > 0 else { return [] }
    return (0..<count).map { ts_node_named_child(node, $0) }
}

private func tsChildren(_ node: TSNode) -> [TSNode] {
    guard !ts_node_is_null(node) else { return [] }
    let count = ts_node_child_count(node)
    guard count > 0 else { return [] }
    return (0..<count).map { ts_node_child(node, $0) }
}

private func tsStartLine(_ node: TSNode) -> Int { Int(ts_node_start_point(node).row) + 1 }
private func tsEndLine(_ node: TSNode) -> Int { Int(ts_node_end_point(node).row) + 1 }

private func tsText(_ node: TSNode?, bytes: [UInt8]) -> String {
    guard let node, !ts_node_is_null(node) else { return "" }
    let start = Int(ts_node_start_byte(node))
    let end = Int(ts_node_end_byte(node))
    guard start >= 0, end <= bytes.count, start <= end else { return "" }
    return String(decoding: bytes[start..<end], as: UTF8.self)
}

/// Descends to find the first `type_identifier`/`identifier`-ish leaf under
/// `node`, stripping generic-argument wrappers the way
/// `LexicalSymbolExtractor.baseIdentifier(of:)` strips `<...>` lexically.
/// Falls back to `node`'s own text if no such descendant exists.
private func tsBaseTypeName(_ node: TSNode?, bytes: [UInt8]) -> String {
    guard let node, !ts_node_is_null(node) else { return "" }
    let leafTypes: Set<String> = ["type_identifier", "identifier", "simple_identifier"]
    var stack = [node]
    while let n = stack.popLast() {
        if leafTypes.contains(tsTypeName(n)) { return tsText(n, bytes: bytes) }
        stack.append(contentsOf: tsNamedChildren(n).reversed())
    }
    return tsText(node, bytes: bytes)
}

// MARK: - Walker

private struct TSWalker {
    let bytes: [UInt8]
    var edges: [RawEdge] = []

    private func qualify(_ name: String, scope: TSScope?) -> String {
        guard let scope else { return name }
        return "\(scope.qualifiedName).\(name)"
    }

    // MARK: Swift

    mutating func walkSwift(_ node: TSNode, scope: TSScope?, into builders: inout [TSBuilding]) {
        for child in tsNamedChildren(node) {
            switch tsTypeName(child) {
            case "import_declaration":
                if let idNode = tsNamedChildren(child).first(where: { tsTypeName($0) == "identifier" }) {
                    let name = tsText(idNode, bytes: bytes)
                    if !name.isEmpty {
                        edges.append(RawEdge(srcQualifiedName: RawSymbol.fileAnchorQualifiedName, dstName: name, kind: .imports))
                    }
                }
            case "class_declaration":
                handleSwiftClassLike(child, scope: scope, into: &builders)
            case "protocol_declaration":
                handleSwiftProtocol(child, scope: scope, into: &builders)
            case "function_declaration":
                handleSwiftFunction(child, scope: scope, into: &builders)
            case "init_declaration":
                handleSwiftInit(child, scope: scope, into: &builders)
            default:
                walkSwift(child, scope: scope, into: &builders)
            }
        }
    }

    private mutating func handleSwiftClassLike(_ node: TSNode, scope: TSScope?, into builders: inout [TSBuilding]) {
        let declKindNode = tsField(node, "declaration_kind")
        let declKind = tsTypeName(declKindNode ?? node) // e.g. "class"/"struct"/"enum"/"actor"/"extension"
        let inherited = tsNamedChildren(node)
            .filter { tsTypeName($0) == "inheritance_specifier" }
            .map { tsBaseTypeName(tsField($0, "inherits_from"), bytes: bytes) }
            .filter { !$0.isEmpty }
        let bodyNode = tsField(node, "body")

        if declKind == "extension" {
            // No dedicated symbol (mirrors LexicalSymbolExtractor — avoids a
            // symbol_key collision with the extended type's real
            // declaration, possibly in another file); conformances attach
            // to the file anchor; nested members still get a synthetic
            // scope so their qualifiedName reads `ExtendedType.member(...)`.
            let extendedName = tsBaseTypeName(tsField(node, "name"), bytes: bytes)
            for base in inherited {
                edges.append(RawEdge(srcQualifiedName: RawSymbol.fileAnchorQualifiedName, dstName: base, kind: .implements))
            }
            if let bodyNode {
                let childScope = TSScope(qualifiedName: extendedName, displayName: extendedName)
                walkSwift(bodyNode, scope: childScope, into: &builders)
            }
            return
        }

        let name = tsBaseTypeName(tsField(node, "name"), bytes: bytes)
        guard !name.isEmpty else { return }
        let kind: SymbolKind
        switch declKind {
        case "struct": kind = .struct
        case "enum": kind = .enum
        case "actor": kind = .actor
        default: kind = .class
        }
        let qualifiedName = qualify(name, scope: scope)
        builders.append(TSBuilding(
            qualifiedName: qualifiedName, name: name, kind: kind,
            parent: scope?.displayName, startLine: tsStartLine(node), endLine: tsEndLine(node), signature: nil
        ))
        for (i, base) in inherited.enumerated() {
            let edgeKind: EdgeKind = (declKind == "class" && i == 0) ? .extends : .implements
            edges.append(RawEdge(srcQualifiedName: qualifiedName, dstName: base, kind: edgeKind))
        }
        if let bodyNode {
            let childScope = TSScope(qualifiedName: qualifiedName, displayName: name)
            walkSwift(bodyNode, scope: childScope, into: &builders)
        }
    }

    private mutating func handleSwiftProtocol(_ node: TSNode, scope: TSScope?, into builders: inout [TSBuilding]) {
        let name = tsBaseTypeName(tsField(node, "name"), bytes: bytes)
        guard !name.isEmpty else { return }
        let inherited = tsNamedChildren(node)
            .filter { tsTypeName($0) == "inheritance_specifier" }
            .map { tsBaseTypeName(tsField($0, "inherits_from"), bytes: bytes) }
            .filter { !$0.isEmpty }
        let qualifiedName = qualify(name, scope: scope)
        builders.append(TSBuilding(
            qualifiedName: qualifiedName, name: name, kind: .protocol,
            parent: scope?.displayName, startLine: tsStartLine(node), endLine: tsEndLine(node), signature: nil
        ))
        for base in inherited {
            edges.append(RawEdge(srcQualifiedName: qualifiedName, dstName: base, kind: .implements))
        }
        if let bodyNode = tsField(node, "body") {
            let childScope = TSScope(qualifiedName: qualifiedName, displayName: name)
            walkSwift(bodyNode, scope: childScope, into: &builders)
        }
    }

    private mutating func swiftParameterLabels(_ node: TSNode) -> [String] {
        tsNamedChildren(node).filter { tsTypeName($0) == "parameter" }.map { param in
            if let ext = tsField(param, "external_name") {
                let t = tsText(ext, bytes: bytes)
                if !t.isEmpty { return t }
            }
            if let nameNode = tsField(param, "name"), tsTypeName(nameNode) == "simple_identifier" {
                let t = tsText(nameNode, bytes: bytes)
                if !t.isEmpty { return t }
            }
            return "_"
        }
    }

    private mutating func handleSwiftFunction(_ node: TSNode, scope: TSScope?, into builders: inout [TSBuilding]) {
        guard let nameNode = tsField(node, "name") else { return }
        let name = tsText(nameNode, bytes: bytes)
        guard !name.isEmpty else { return }
        let labels = swiftParameterLabels(node)
        let arity = "(" + labels.map { "\($0):" }.joined() + ")"
        let qualifiedName = qualify("\(name)\(arity)", scope: scope)
        let kind: SymbolKind = scope == nil ? .function : .method
        builders.append(TSBuilding(
            qualifiedName: qualifiedName, name: name, kind: kind,
            parent: scope?.displayName, startLine: tsStartLine(node), endLine: tsEndLine(node),
            signature: "func \(name)\(arity)"
        ))
        if let body = tsField(node, "body") {
            edges.append(contentsOf: swiftCalls(in: body, srcQualifiedName: qualifiedName))
            // Local nested declarations (rare, but keep parity with the
            // Lexical extractor's brace-tracking, which also descends).
            walkSwift(body, scope: TSScope(qualifiedName: qualifiedName, displayName: name), into: &builders)
        }
    }

    private mutating func handleSwiftInit(_ node: TSNode, scope: TSScope?, into builders: inout [TSBuilding]) {
        let labels = swiftParameterLabels(node)
        let arity = "(" + labels.map { "\($0):" }.joined() + ")"
        let name = "init"
        let qualifiedName = qualify("\(name)\(arity)", scope: scope)
        builders.append(TSBuilding(
            qualifiedName: qualifiedName, name: name, kind: .initializer,
            parent: scope?.displayName, startLine: tsStartLine(node), endLine: tsEndLine(node),
            signature: "init\(arity)"
        ))
        if let body = tsField(node, "body") {
            edges.append(contentsOf: swiftCalls(in: body, srcQualifiedName: qualifiedName))
        }
    }

    private func swiftCallee(_ node: TSNode) -> String? {
        switch tsTypeName(node) {
        case "simple_identifier":
            let t = tsText(node, bytes: bytes)
            return t.isEmpty ? nil : t
        case "navigation_expression":
            guard let suffix = tsField(node, "suffix"),
                  let inner = tsField(suffix, "suffix") else { return nil }
            let t = tsText(inner, bytes: bytes)
            return t.isEmpty ? nil : t
        default:
            return nil
        }
    }

    private func swiftCalls(in node: TSNode, srcQualifiedName: String) -> [RawEdge] {
        var found: [RawEdge] = []
        var stack = tsNamedChildren(node)
        while let n = stack.popLast() {
            if tsTypeName(n) == "call_expression", let callee = tsNamedChildren(n).first {
                if let name = swiftCallee(callee) {
                    found.append(RawEdge(srcQualifiedName: srcQualifiedName, dstName: name, kind: .calls))
                }
            }
            stack.append(contentsOf: tsNamedChildren(n))
        }
        return found
    }

    // MARK: C#

    mutating func walkCSharp(_ node: TSNode, scope: TSScope?, into builders: inout [TSBuilding]) {
        for child in tsNamedChildren(node) {
            switch tsTypeName(child) {
            case "using_directive":
                // `name` is declared as a field in node-types.json, but this
                // grammar version doesn't actually attach it for the plain
                // `using X;` form (verified empirically) — fall back to the
                // first named child (the qualified-name/identifier itself).
                let nameNode = tsField(child, "name") ?? tsNamedChildren(child).first
                let name = tsText(nameNode, bytes: bytes)
                if !name.isEmpty {
                    edges.append(RawEdge(srcQualifiedName: RawSymbol.fileAnchorQualifiedName, dstName: name, kind: .imports))
                }
            case "class_declaration", "struct_declaration", "interface_declaration", "record_declaration":
                handleCSharpType(child, scope: scope, into: &builders)
            case "enum_declaration":
                handleCSharpEnum(child, scope: scope, into: &builders)
            case "method_declaration":
                handleCSharpMethod(child, scope: scope, into: &builders)
            case "constructor_declaration":
                handleCSharpConstructor(child, scope: scope, into: &builders)
            default:
                walkCSharp(child, scope: scope, into: &builders)
            }
        }
    }

    private mutating func handleCSharpType(_ node: TSNode, scope: TSScope?, into builders: inout [TSBuilding]) {
        guard let nameNode = tsField(node, "name") else { return }
        let name = tsText(nameNode, bytes: bytes)
        guard !name.isEmpty else { return }
        let typeKind = tsTypeName(node)
        let kind: SymbolKind = typeKind == "interface_declaration" ? .protocol : (typeKind == "struct_declaration" ? .struct : .class)
        // `base_list`'s children are unlabeled (no field name) but the
        // grammar only ever puts type-reference nodes there.
        let bases: [String]
        if let baseListNode = tsNamedChildren(node).first(where: { tsTypeName($0) == "base_list" }) {
            bases = tsNamedChildren(baseListNode).compactMap { n -> String? in
                let t = tsBaseTypeName(n, bytes: bytes)
                return t.isEmpty ? nil : t
            }
        } else {
            bases = []
        }
        let qualifiedName = qualify(name, scope: scope)
        builders.append(TSBuilding(
            qualifiedName: qualifiedName, name: name, kind: kind,
            parent: scope?.displayName, startLine: tsStartLine(node), endLine: tsEndLine(node), signature: nil
        ))
        for (i, base) in bases.enumerated() {
            let edgeKind: EdgeKind = (typeKind == "class_declaration" && i == 0) ? .extends : .implements
            edges.append(RawEdge(srcQualifiedName: qualifiedName, dstName: base, kind: edgeKind))
        }
        if let bodyNode = tsField(node, "body") {
            let childScope = TSScope(qualifiedName: qualifiedName, displayName: name)
            walkCSharp(bodyNode, scope: childScope, into: &builders)
        }
    }

    private mutating func handleCSharpEnum(_ node: TSNode, scope: TSScope?, into builders: inout [TSBuilding]) {
        guard let nameNode = tsField(node, "name") else { return }
        let name = tsText(nameNode, bytes: bytes)
        guard !name.isEmpty else { return }
        builders.append(TSBuilding(
            qualifiedName: qualify(name, scope: scope), name: name, kind: .enum,
            parent: scope?.displayName, startLine: tsStartLine(node), endLine: tsEndLine(node), signature: nil
        ))
    }

    private func csharpParameterLabels(_ node: TSNode?) -> [String] {
        guard let paramsNode = node else { return [] }
        return tsNamedChildren(paramsNode).compactMap { p in
            guard tsTypeName(p) == "parameter", let nameNode = tsField(p, "name") else { return nil }
            let t = tsText(nameNode, bytes: bytes)
            return t.isEmpty ? nil : t
        }
    }

    private mutating func handleCSharpMethod(_ node: TSNode, scope: TSScope?, into builders: inout [TSBuilding]) {
        guard let nameNode = tsField(node, "name") else { return }
        let name = tsText(nameNode, bytes: bytes)
        guard !name.isEmpty else { return }
        let labels = csharpParameterLabels(tsField(node, "parameters"))
        let arity = "(" + labels.joined(separator: ",") + ")"
        let qualifiedName = qualify("\(name)\(arity)", scope: scope)
        builders.append(TSBuilding(
            qualifiedName: qualifiedName, name: name, kind: .method,
            parent: scope?.displayName, startLine: tsStartLine(node), endLine: tsEndLine(node),
            signature: "\(name)\(arity)"
        ))
        if let body = tsField(node, "body") {
            edges.append(contentsOf: csharpCalls(in: body, srcQualifiedName: qualifiedName))
        }
    }

    private mutating func handleCSharpConstructor(_ node: TSNode, scope: TSScope?, into builders: inout [TSBuilding]) {
        let labels = csharpParameterLabels(tsField(node, "parameters"))
        let arity = "(" + labels.joined(separator: ",") + ")"
        let name = "ctor"
        let qualifiedName = qualify("\(name)\(arity)", scope: scope)
        builders.append(TSBuilding(
            qualifiedName: qualifiedName, name: name, kind: .initializer,
            parent: scope?.displayName, startLine: tsStartLine(node), endLine: tsEndLine(node),
            signature: "ctor\(arity)"
        ))
        if let body = tsField(node, "body") {
            edges.append(contentsOf: csharpCalls(in: body, srcQualifiedName: qualifiedName))
        }
    }

    private func csharpCallee(_ node: TSNode) -> String? {
        switch tsTypeName(node) {
        case "identifier":
            let t = tsText(node, bytes: bytes)
            return t.isEmpty ? nil : t
        case "member_access_expression":
            guard let nameNode = tsField(node, "name") else { return nil }
            let t = tsText(nameNode, bytes: bytes)
            return t.isEmpty ? nil : t
        default:
            return nil
        }
    }

    private func csharpCalls(in node: TSNode, srcQualifiedName: String) -> [RawEdge] {
        var found: [RawEdge] = []
        var stack = tsNamedChildren(node)
        while let n = stack.popLast() {
            if tsTypeName(n) == "invocation_expression", let fn = tsField(n, "function"), let name = csharpCallee(fn) {
                found.append(RawEdge(srcQualifiedName: srcQualifiedName, dstName: name, kind: .calls))
            }
            stack.append(contentsOf: tsNamedChildren(n))
        }
        return found
    }

    // MARK: JavaScript / TypeScript

    mutating func walkJSFamily(_ node: TSNode, scope: TSScope?, into builders: inout [TSBuilding]) {
        for child in tsNamedChildren(node) {
            switch tsTypeName(child) {
            case "import_statement":
                handleJSImport(child)
            case "class_declaration":
                handleJSClass(child, scope: scope, into: &builders)
            case "interface_declaration":
                handleTSInterface(child, scope: scope, into: &builders)
            case "function_declaration":
                handleJSFunction(child, scope: scope, into: &builders)
            case "method_definition":
                handleJSMethod(child, scope: scope, into: &builders)
            default:
                walkJSFamily(child, scope: scope, into: &builders)
            }
        }
    }

    private mutating func handleJSImport(_ node: TSNode) {
        guard let clause = tsNamedChildren(node).first(where: { tsTypeName($0) == "import_clause" }) else { return }
        var stack = [clause]
        while let n = stack.popLast() {
            switch tsTypeName(n) {
            case "identifier":
                let t = tsText(n, bytes: bytes)
                if !t.isEmpty { edges.append(RawEdge(srcQualifiedName: RawSymbol.fileAnchorQualifiedName, dstName: t, kind: .imports)) }
            case "import_specifier":
                let target = tsField(n, "name")
                let t = tsText(target, bytes: bytes)
                if !t.isEmpty { edges.append(RawEdge(srcQualifiedName: RawSymbol.fileAnchorQualifiedName, dstName: t, kind: .imports)) }
            default:
                stack.append(contentsOf: tsNamedChildren(n))
            }
        }
    }

    private func jsHeritage(_ classNode: TSNode) -> (extends: [String], implements: [String]) {
        guard let heritage = tsNamedChildren(classNode).first(where: { tsTypeName($0) == "class_heritage" }) else {
            return ([], [])
        }
        var extendsNames: [String] = []
        var implementsNames: [String] = []
        for child in tsNamedChildren(heritage) {
            switch tsTypeName(child) {
            case "extends_clause":
                let t = tsBaseTypeName(tsField(child, "value"), bytes: bytes)
                if !t.isEmpty { extendsNames.append(t) }
            case "implements_clause":
                for typeNode in tsNamedChildren(child) {
                    let t = tsBaseTypeName(typeNode, bytes: bytes)
                    if !t.isEmpty { implementsNames.append(t) }
                }
            case "identifier":
                // Plain JS (no TS extends_clause wrapper) — the class_heritage's
                // direct identifier child IS the superclass.
                let t = tsText(child, bytes: bytes)
                if !t.isEmpty { extendsNames.append(t) }
            default:
                break
            }
        }
        return (extendsNames, implementsNames)
    }

    private mutating func handleJSClass(_ node: TSNode, scope: TSScope?, into builders: inout [TSBuilding]) {
        guard let nameNode = tsField(node, "name") else { return }
        let name = tsText(nameNode, bytes: bytes)
        guard !name.isEmpty else { return }
        let qualifiedName = qualify(name, scope: scope)
        builders.append(TSBuilding(
            qualifiedName: qualifiedName, name: name, kind: .class,
            parent: scope?.displayName, startLine: tsStartLine(node), endLine: tsEndLine(node), signature: nil
        ))
        let (extendsNames, implementsNames) = jsHeritage(node)
        for base in extendsNames { edges.append(RawEdge(srcQualifiedName: qualifiedName, dstName: base, kind: .extends)) }
        for base in implementsNames { edges.append(RawEdge(srcQualifiedName: qualifiedName, dstName: base, kind: .implements)) }
        if let bodyNode = tsField(node, "body") {
            let childScope = TSScope(qualifiedName: qualifiedName, displayName: name)
            walkJSFamily(bodyNode, scope: childScope, into: &builders)
        }
    }

    private mutating func handleTSInterface(_ node: TSNode, scope: TSScope?, into builders: inout [TSBuilding]) {
        guard let nameNode = tsField(node, "name") else { return }
        let name = tsText(nameNode, bytes: bytes)
        guard !name.isEmpty else { return }
        let qualifiedName = qualify(name, scope: scope)
        builders.append(TSBuilding(
            qualifiedName: qualifiedName, name: name, kind: .protocol,
            parent: scope?.displayName, startLine: tsStartLine(node), endLine: tsEndLine(node), signature: nil
        ))
        for child in tsNamedChildren(node) where tsTypeName(child) == "extends_type_clause" {
            for typeNode in tsNamedChildren(child) {
                let t = tsBaseTypeName(typeNode, bytes: bytes)
                if !t.isEmpty { edges.append(RawEdge(srcQualifiedName: qualifiedName, dstName: t, kind: .implements)) }
            }
        }
    }

    private func jsParameterLabels(_ node: TSNode?) -> [String] {
        guard let paramsNode = node else { return [] }
        return tsNamedChildren(paramsNode).compactMap { p -> String? in
            switch tsTypeName(p) {
            case "identifier":
                let t = tsText(p, bytes: bytes)
                return t.isEmpty ? nil : t
            case "required_parameter", "optional_parameter":
                let inner = tsField(p, "pattern") ?? tsField(p, "name")
                let t = tsText(inner, bytes: bytes)
                return t.isEmpty ? nil : t
            default:
                return nil
            }
        }
    }

    private mutating func handleJSFunction(_ node: TSNode, scope: TSScope?, into builders: inout [TSBuilding]) {
        guard let nameNode = tsField(node, "name") else { return }
        let name = tsText(nameNode, bytes: bytes)
        guard !name.isEmpty else { return }
        let labels = jsParameterLabels(tsField(node, "parameters"))
        let arity = "(" + labels.joined(separator: ",") + ")"
        let qualifiedName = qualify("\(name)\(arity)", scope: scope)
        builders.append(TSBuilding(
            qualifiedName: qualifiedName, name: name, kind: .function,
            parent: scope?.displayName, startLine: tsStartLine(node), endLine: tsEndLine(node),
            signature: "function \(name)\(arity)"
        ))
        if let body = tsField(node, "body") {
            edges.append(contentsOf: jsCalls(in: body, srcQualifiedName: qualifiedName))
        }
    }

    private mutating func handleJSMethod(_ node: TSNode, scope: TSScope?, into builders: inout [TSBuilding]) {
        guard let nameNode = tsField(node, "name") else { return }
        let name = tsText(nameNode, bytes: bytes)
        guard !name.isEmpty else { return }
        let labels = jsParameterLabels(tsField(node, "parameters"))
        let arity = "(" + labels.joined(separator: ",") + ")"
        let qualifiedName = qualify("\(name)\(arity)", scope: scope)
        builders.append(TSBuilding(
            qualifiedName: qualifiedName, name: name, kind: .method,
            parent: scope?.displayName, startLine: tsStartLine(node), endLine: tsEndLine(node),
            signature: "\(name)\(arity)"
        ))
        if let body = tsField(node, "body") {
            edges.append(contentsOf: jsCalls(in: body, srcQualifiedName: qualifiedName))
        }
    }

    private func jsCallee(_ node: TSNode) -> String? {
        switch tsTypeName(node) {
        case "identifier":
            let t = tsText(node, bytes: bytes)
            return t.isEmpty ? nil : t
        case "member_expression":
            guard let prop = tsField(node, "property") else { return nil }
            let t = tsText(prop, bytes: bytes)
            return t.isEmpty ? nil : t
        default:
            return nil
        }
    }

    private func jsCalls(in node: TSNode, srcQualifiedName: String) -> [RawEdge] {
        var found: [RawEdge] = []
        var stack = tsNamedChildren(node)
        while let n = stack.popLast() {
            if tsTypeName(n) == "call_expression", let fn = tsField(n, "function"), let name = jsCallee(fn) {
                found.append(RawEdge(srcQualifiedName: srcQualifiedName, dstName: name, kind: .calls))
            }
            stack.append(contentsOf: tsNamedChildren(n))
        }
        return found
    }
}

// MARK: - Shared references heuristic (byte-range based, language-agnostic)

enum TSReferenceHeuristic {
    static func extractReferences(bytes: [UInt8], symbols: [TSBuilding]) -> [RawEdge] {
        guard let regex = try? NSRegularExpression(pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#) else { return [] }
        let text = String(decoding: bytes, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        var edges: [RawEdge] = []
        for sym in symbols where sym.kind != .file {
            guard sym.startLine >= 1, sym.endLine >= sym.startLine, sym.startLine - 1 < lines.count else { continue }
            let endIdx = min(sym.endLine, lines.count)
            let slice = lines[(sym.startLine - 1)..<endIdx].joined(separator: "\n")
            let nsSlice = slice as NSString
            var seen = Set<String>()
            for match in regex.matches(in: slice, range: NSRange(location: 0, length: nsSlice.length)) {
                let name = nsSlice.substring(with: match.range)
                guard name != sym.name, name != sym.parent else { continue }
                guard seen.insert(name).inserted else { continue }
                edges.append(RawEdge(srcQualifiedName: sym.qualifiedName, dstName: name, kind: .references))
            }
        }
        return edges
    }
}
