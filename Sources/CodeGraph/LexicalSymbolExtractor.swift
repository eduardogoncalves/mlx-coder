// Sources/CodeGraph/LexicalSymbolExtractor.swift
// Zero-dependency regex/heuristic Swift extractor — the v1 extraction backbone
// (plan §3.4). Produces nodes (file/class/struct/enum/protocol/actor/
// function/method/initializer) and `imports`/`extends`/`implements`/
// `references` edges. Deliberately does NOT attempt `calls` edges — see
// `EdgeKind.calls` and plan §2.1 for why lexical regex is unreliable for call
// sites specifically (trailing closures, method chains, `self.`, operator
// overloads, shadowing).
//
// This is a hand-rolled single-pass character scanner rather than a line-based
// regex, specifically because this codebase's own style (see
// `HybridKnowledgeStore.write`, `AgentLoop.init`) commonly spreads a function's
// parameter list across many lines — a line-anchored "header ends with `{`"
// regex would miss most of the methods in this very repo.
//
// Known, accepted limitations (documented rather than silently wrong):
//  - Brace/paren/bracket balance is purely lexical: string literals and
//    comments are blanked out first (so their contents can't corrupt nesting
//    depth), but interpolated expressions inside strings (`\(...)`) are
//    blanked along with the rest of the string, so symbols referenced only
//    inside string interpolation are invisible to `references` edges.
//  - Operator-function declarations (`static func == (...)`) are not captured
//    as symbols (no identifier name to key on), but their bodies are still
//    correctly skipped over for brace-depth purposes.
//  - `extension Foo: Protocol { }` conformances are attributed to the
//    per-file anchor symbol rather than a dedicated "Foo" symbol, to avoid a
//    `symbol_key` collision with `Foo`'s real declaration (possibly in
//    another file). This means blast-radius-by-name for `Foo`'s conformances
//    declared via extension is approximate (file-level, not type-level).
//  - `references` edges are a coarse "capitalized identifier appears in this
//    symbol's body" heuristic, not a resolved type-check — by design (plan
//    §2.1 explicitly keeps by-name `references` in v1 while deferring the
//    much less reliable `calls`).
import Foundation

public struct LexicalSymbolExtractor: SymbolExtractor {
    public let language = "swift"

    public init() {}

    public func extract(path: String, source: String) -> ExtractionResult {
        Self.extractSwift(path: path, source: source)
    }

    // MARK: - Entry point

    static func extractSwift(path: String, source: String) -> ExtractionResult {
        let fileName = (path as NSString).lastPathComponent
        guard !source.isEmpty else {
            let anchor = RawSymbol(
                qualifiedName: RawSymbol.fileAnchorQualifiedName,
                name: fileName, kind: .file, parent: nil,
                startLine: 1, endLine: 1, signature: nil
            )
            return ExtractionResult(symbols: [anchor], edges: [])
        }

        let cleaned = cleanedSource(source)
        let scanner = SwiftScanner(chars: cleaned.chars, lineOf: cleaned.lineOf)
        scanner.run()

        var buildings = scanner.symbols
        buildings.insert(
            Building(
                qualifiedName: RawSymbol.fileAnchorQualifiedName,
                name: fileName, kind: .file, parent: nil,
                startLine: 1, endLine: cleaned.totalLines, signature: nil
            ),
            at: 0
        )

        var edges = scanner.edges
        edges.append(contentsOf: extractReferences(
            cleaned: cleaned.chars,
            lineStartOffsets: cleaned.lineStartOffsets,
            symbols: buildings
        ))

        let symbols = buildings.map {
            RawSymbol(
                qualifiedName: $0.qualifiedName, name: $0.name, kind: $0.kind,
                parent: $0.parent, startLine: $0.startLine, endLine: $0.endLine,
                signature: $0.signature
            )
        }
        return ExtractionResult(symbols: symbols, edges: edges)
    }

    // MARK: - Comment / string blanking

    struct Cleaned {
        let chars: [Character]
        let lineOf: [Int]
        /// 1-indexed: `lineStartOffsets[n]` is the char index where line `n` begins.
        let lineStartOffsets: [Int]
        let totalLines: Int
    }

    /// Blanks out comment and string-literal content (replacing with spaces,
    /// preserving newlines and overall length) so brace/paren counting can't
    /// be corrupted by `{`/`}`/`(`/`)` appearing inside a string or comment,
    /// and so identifier scanning can't misfire on commented-out code.
    static func cleanedSource(_ source: String) -> Cleaned {
        let original = Array(source)
        var out = original
        var lineOf = [Int](repeating: 1, count: original.count)
        var lineStartOffsets: [Int] = [0, 0] // index 0 unused; line 1 starts at offset 0
        var line = 1

        enum Mode { case code, lineComment, blockComment, tripleString, singleString }
        var mode: Mode = .code
        var i = 0
        let n = original.count

        func advanceLine() {
            line += 1
            lineStartOffsets.append(i + 1)
        }

        while i < n {
            if i < lineOf.count { lineOf[i] = line }
            let c = original[i]
            switch mode {
            case .code:
                if c == "\n" { advanceLine(); i += 1; continue }
                if c == "/", i + 1 < n, original[i + 1] == "/" {
                    out[i] = " "; out[i + 1] = " "
                    if i + 1 < lineOf.count { lineOf[i + 1] = line }
                    mode = .lineComment; i += 2; continue
                }
                if c == "/", i + 1 < n, original[i + 1] == "*" {
                    out[i] = " "; out[i + 1] = " "
                    if i + 1 < lineOf.count { lineOf[i + 1] = line }
                    mode = .blockComment; i += 2; continue
                }
                if c == "\"", i + 2 < n, original[i + 1] == "\"", original[i + 2] == "\"" {
                    out[i] = " "; out[i + 1] = " "; out[i + 2] = " "
                    if i + 2 < lineOf.count { lineOf[i + 1] = line; lineOf[i + 2] = line }
                    mode = .tripleString; i += 3; continue
                }
                if c == "\"" {
                    out[i] = " "
                    mode = .singleString; i += 1; continue
                }
                i += 1
            case .lineComment:
                if c == "\n" { mode = .code; advanceLine(); i += 1; continue }
                out[i] = " "; i += 1
            case .blockComment:
                if c == "\n" { advanceLine(); i += 1; continue }
                if c == "*", i + 1 < n, original[i + 1] == "/" {
                    out[i] = " "; out[i + 1] = " "
                    if i + 1 < lineOf.count { lineOf[i + 1] = line }
                    mode = .code; i += 2; continue
                }
                out[i] = " "; i += 1
            case .tripleString:
                if c == "\n" { advanceLine(); i += 1; continue }
                if c == "\"", i + 2 < n, original[i + 1] == "\"", original[i + 2] == "\"" {
                    out[i] = " "; out[i + 1] = " "; out[i + 2] = " "
                    if i + 2 < lineOf.count { lineOf[i + 1] = line; lineOf[i + 2] = line }
                    mode = .code; i += 3; continue
                }
                out[i] = " "; i += 1
            case .singleString:
                if c == "\n" { mode = .code; advanceLine(); i += 1; continue } // defensive: unterminated
                if c == "\\", i + 1 < n, original[i + 1] != "\n" {
                    out[i] = " "; out[i + 1] = " "
                    if i + 1 < lineOf.count { lineOf[i + 1] = line }
                    i += 2; continue
                }
                if c == "\"" {
                    out[i] = " "
                    mode = .code; i += 1; continue
                }
                out[i] = " "; i += 1
            }
        }
        return Cleaned(chars: out, lineOf: lineOf, lineStartOffsets: lineStartOffsets, totalLines: line)
    }

    // MARK: - References (phase-1, by-name)

    /// Swift stdlib / Foundation names common enough that flagging every
    /// occurrence as a `references` edge would be pure noise.
    static let referenceBuiltinBlocklist: Set<String> = [
        "String", "Int", "Int8", "Int16", "Int32", "Int64",
        "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
        "Double", "Float", "CGFloat", "Bool", "Character", "Substring",
        "Array", "Dictionary", "Set", "Optional", "Result",
        "Void", "Any", "AnyObject", "Error", "Self",
        "Data", "URL", "Date", "UUID", "NSObject", "NSString",
    ]

    static func extractReferences(
        cleaned: [Character],
        lineStartOffsets: [Int],
        symbols: [Building]
    ) -> [RawEdge] {
        var edges: [RawEdge] = []
        for sym in symbols where sym.kind != .file {
            guard sym.startLine >= 1, sym.endLine >= sym.startLine,
                  sym.startLine < lineStartOffsets.count else { continue }
            let startOffset = lineStartOffsets[sym.startLine]
            let endLineClamped = min(sym.endLine, lineStartOffsets.count - 1)
            let endOffset = (endLineClamped + 1 < lineStartOffsets.count)
                ? lineStartOffsets[endLineClamped + 1] : cleaned.count
            guard startOffset >= 0, startOffset < endOffset, endOffset <= cleaned.count else { continue }
            let slice = String(cleaned[startOffset..<endOffset])
            var seen = Set<String>()
            for name in capitalizedIdentifiers(in: slice) {
                guard name != sym.name, name != sym.parent,
                      !referenceBuiltinBlocklist.contains(name) else { continue }
                guard seen.insert(name).inserted else { continue }
                edges.append(RawEdge(srcQualifiedName: sym.qualifiedName, dstName: name, kind: .references))
            }
        }
        return edges
    }

    static func capitalizedIdentifiers(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#) else { return [] }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        return matches.map { nsText.substring(with: $0.range) }
    }

    // MARK: - Parameter-label / signature helpers (Swift selector-style arity)

    /// Splits a raw parameter list (already balanced-paren-extracted) into
    /// its top-level comma-separated parameters, respecting nested
    /// `()`/`<>`/`[]` (default-value closures, generic types, tuple/array
    /// types) so a comma inside e.g. `(a: Int, b: [String: Int] = [:])` isn't
    /// mistaken for a parameter separator.
    static func splitTopLevelCommaList(_ text: String) -> [String] {
        var depth = 0
        var current = ""
        var result: [String] = []
        for ch in text {
            switch ch {
            case "(", "<", "[": depth += 1; current.append(ch)
            case ")", ">", "]": depth = max(0, depth - 1); current.append(ch)
            case ",":
                if depth <= 0 { result.append(current); current = "" } else { current.append(ch) }
            default:
                current.append(ch)
            }
        }
        result.append(current)
        return result.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Swift external-label rule: `_ name: T` → `_`; `ext name: T` → `ext`;
    /// `name: T` → `name` (the internal name doubles as the external label).
    static func externalLabel(forParam param: String) -> String {
        guard let colonIdx = param.firstIndex(of: ":") else {
            let firstToken = param.split(separator: " ").first.map(String.init) ?? "_"
            return firstToken
        }
        let beforeColon = String(param[param.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
        let tokens = beforeColon.split(separator: " ").map(String.init)
        return tokens.first ?? "_"
    }

    static func parameterLabels(from paramText: String) -> [String] {
        let trimmed = paramText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return splitTopLevelCommaList(trimmed).map(externalLabel(forParam:))
    }

    static func aritySuffix(labels: [String]) -> String {
        "(" + labels.map { "\($0):" }.joined() + ")"
    }

    /// Strips generic args / trailing modifiers from an inheritance-list item,
    /// e.g. `"Collection<Element == Int>"` → `"Collection"`, `"Sendable"` → `"Sendable"`.
    static func baseIdentifier(of raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        for ch in trimmed {
            if isIdentifierContinue(ch) || (result.isEmpty && isIdentifierStart(ch)) {
                result.append(ch)
            } else {
                break
            }
        }
        return result
    }
}

// MARK: - Character classes

private func isIdentifierStart(_ c: Character) -> Bool { c.isLetter || c == "_" }
private func isIdentifierContinue(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

// MARK: - Internal mutable symbol builder (converted to `RawSymbol` at the end)

struct Building {
    var qualifiedName: String
    var name: String
    var kind: SymbolKind
    var parent: String?
    var startLine: Int
    var endLine: Int
    var signature: String?
}

// MARK: - Single-pass character scanner

/// Not `Sendable` (mutable scratch state); constructed and driven entirely
/// within a single synchronous call to `LexicalSymbolExtractor.extract`.
private final class SwiftScanner {
    private struct Frame {
        let displayName: String
        let qualifiedName: String
        /// `nil` for the synthetic "extension" scope marker (no emitted symbol).
        let kind: SymbolKind?
        let isContainer: Bool
        let openDepth: Int
        let pendingSymbolIndex: Int?
    }

    private let chars: [Character]
    private let lineOf: [Int]
    private var pos = 0
    private var depth = 0
    private var scopeStack: [Frame] = []

    private(set) var symbols: [Building] = []
    private(set) var edges: [RawEdge] = []

    private static let typeDeclBlacklist: Set<String> = ["func", "var", "let", "subscript"]
    private static let topLevelStopKeywords: Set<String> = [
        "func", "class", "struct", "enum", "protocol", "actor", "extension",
        "init", "import", "var", "let",
    ]

    init(chars: [Character], lineOf: [Int]) {
        self.chars = chars
        self.lineOf = lineOf
    }

    func run() {
        while pos < chars.count {
            let c = chars[pos]
            if c == "\n" || c.isWhitespace { pos += 1; continue }
            if c == "{" { depth += 1; pos += 1; continue }
            if c == "}" {
                if let top = scopeStack.last, top.openDepth == depth {
                    scopeStack.removeLast()
                    if let idx = top.pendingSymbolIndex {
                        symbols[idx].endLine = currentLine()
                    }
                }
                depth = max(0, depth - 1)
                pos += 1
                continue
            }
            if isIdentifierStart(c) {
                let wordStart = pos
                let word = readIdentifier()
                let wordLine = lineOf.indices.contains(wordStart) ? lineOf[wordStart] : currentLine()
                switch word {
                case "import": handleImport()
                case "class", "struct", "enum", "protocol", "actor": handleTypeDecl(keyword: word, startLine: wordLine)
                case "extension": handleExtension(startLine: wordLine)
                case "func": handleFunc(startLine: wordLine)
                case "init": handleInit(startLine: wordLine)
                default: break
                }
                continue
            }
            pos += 1
        }
        // Defensively close any still-open frames (malformed/truncated source).
        let lastLine = lineOf.last ?? 1
        while let top = scopeStack.popLast() {
            if let idx = top.pendingSymbolIndex, symbols[idx].endLine < 0 {
                symbols[idx].endLine = lastLine
            }
        }
    }

    // MARK: Cursor helpers

    private func currentLine() -> Int {
        if pos < lineOf.count { return lineOf[pos] }
        return lineOf.last ?? 1
    }

    private func peekChar() -> Character? { pos < chars.count ? chars[pos] : nil }

    private func skipWhitespace() {
        while pos < chars.count, chars[pos].isWhitespace { pos += 1 }
    }

    /// Reads an identifier starting at `pos` without checking `isIdentifierStart`
    /// first — callers must only invoke this when they already know `pos` sits
    /// on an identifier-start character.
    private func readIdentifier() -> String {
        var s = ""
        while pos < chars.count, isIdentifierContinue(chars[pos]) {
            s.append(chars[pos]); pos += 1
        }
        return s
    }

    /// Non-consuming lookahead for the next identifier (after whitespace).
    private func peekIdentifier() -> String? {
        var i = pos
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        guard i < chars.count, isIdentifierStart(chars[i]) else { return nil }
        var s = ""
        while i < chars.count, isIdentifierContinue(chars[i]) { s.append(chars[i]); i += 1 }
        return s
    }

    @discardableResult
    private func skipBalanced(open: Character, close: Character) -> Bool {
        guard pos < chars.count, chars[pos] == open else { return false }
        var localDepth = 0
        while pos < chars.count {
            let c = chars[pos]
            if c == open { localDepth += 1 }
            else if c == close {
                localDepth -= 1
                if localDepth == 0 { pos += 1; return true }
            }
            pos += 1
        }
        return false
    }

    // MARK: Declaration handlers

    private func handleImport() {
        skipWhitespace()
        if let maybeKind = peekIdentifier(),
           ["struct", "class", "enum", "protocol", "func", "var", "let", "typealias"].contains(maybeKind) {
            _ = readIdentifier()
            skipWhitespace()
        }
        guard let moduleName = peekIdentifier() else { return }
        _ = readIdentifier()
        edges.append(RawEdge(srcQualifiedName: RawSymbol.fileAnchorQualifiedName, dstName: moduleName, kind: .imports))
    }

    private func handleTypeDecl(keyword: String, startLine: Int) {
        skipWhitespace()
        guard let name = peekIdentifier(), !Self.typeDeclBlacklist.contains(name) else { return }
        _ = readIdentifier()

        skipWhitespace()
        if peekChar() == "<" { skipBalanced(open: "<", close: ">"); skipWhitespace() }

        let inherited = parseInheritanceIfPresent()
        skipWhereClauseIfPresent()
        skipWhitespace()
        guard peekChar() == "{" else { return }
        depth += 1; pos += 1

        let kind = LexicalSymbolExtractor.symbolKind(forTypeKeyword: keyword)
        let prefix = scopeStack.last?.qualifiedName
        let qualifiedName = prefix.map { "\($0).\(name)" } ?? name
        symbols.append(Building(
            qualifiedName: qualifiedName, name: name, kind: kind,
            parent: scopeStack.last?.displayName, startLine: startLine, endLine: -1, signature: nil
        ))
        let idx = symbols.count - 1
        scopeStack.append(Frame(
            displayName: name, qualifiedName: qualifiedName, kind: kind,
            isContainer: true, openDepth: depth, pendingSymbolIndex: idx
        ))

        for (i, base) in inherited.enumerated() {
            let edgeKind: EdgeKind = (keyword == "class" && i == 0) ? .extends : .implements
            edges.append(RawEdge(srcQualifiedName: qualifiedName, dstName: base, kind: edgeKind))
        }
    }

    private func handleExtension(startLine: Int) {
        skipWhitespace()
        guard let rawName = peekDottedTypeName() else { return }
        consumeDottedTypeName()

        let inherited = parseInheritanceIfPresent()
        skipWhereClauseIfPresent()
        skipWhitespace()
        guard peekChar() == "{" else { return }
        depth += 1; pos += 1

        let displayName = rawName.components(separatedBy: ".").last ?? rawName
        scopeStack.append(Frame(
            displayName: displayName, qualifiedName: rawName, kind: nil,
            isContainer: true, openDepth: depth, pendingSymbolIndex: nil
        ))

        // Extension-declared conformances are attributed to the file anchor —
        // see the type-level doc comment on `LexicalSymbolExtractor` for why.
        for base in inherited {
            edges.append(RawEdge(srcQualifiedName: RawSymbol.fileAnchorQualifiedName, dstName: base, kind: .implements))
        }
    }

    private func handleFunc(startLine: Int) {
        let containerOK = scopeStack.isEmpty || (scopeStack.last?.isContainer == true)
        skipWhitespace()
        guard let name = peekIdentifier() else { return } // operator funcs: skip (body still tracked generically)
        guard containerOK else { return }
        _ = readIdentifier()

        skipWhitespace()
        if peekChar() == "<" { skipBalanced(open: "<", close: ">"); skipWhitespace() }
        guard peekChar() == "(" else { return }
        let paramStart = pos
        guard skipBalanced(open: "(", close: ")") else { return }
        let paramText = String(chars[(paramStart + 1)..<max(paramStart + 1, pos - 1)])
        let arity = LexicalSymbolExtractor.aritySuffix(labels: LexicalSymbolExtractor.parameterLabels(from: paramText))

        skipFunctionTail()
        appendCallable(name: name, arity: arity, startLine: startLine)
    }

    private func handleInit(startLine: Int) {
        let containerOK = scopeStack.isEmpty || (scopeStack.last?.isContainer == true)
        guard containerOK else { return }

        var name = "init"
        if peekChar() == "?" { name += "?"; pos += 1 }
        else if peekChar() == "!" { name += "!"; pos += 1 }

        skipWhitespace()
        if peekChar() == "<" { skipBalanced(open: "<", close: ">"); skipWhitespace() }
        guard peekChar() == "(" else { return }
        let paramStart = pos
        guard skipBalanced(open: "(", close: ")") else { return }
        let paramText = String(chars[(paramStart + 1)..<max(paramStart + 1, pos - 1)])
        let arity = LexicalSymbolExtractor.aritySuffix(labels: LexicalSymbolExtractor.parameterLabels(from: paramText))

        skipFunctionTail()
        appendCallable(name: name, arity: arity, startLine: startLine, kindOverride: .initializer)
    }

    @discardableResult
    private func appendCallable(name: String, arity: String, startLine: Int, kindOverride: SymbolKind? = nil) -> Int {
        let kind = kindOverride ?? (scopeStack.isEmpty ? .function : .method)
        let prefix = scopeStack.last?.qualifiedName
        let qualifiedName = prefix.map { "\($0).\(name)\(arity)" } ?? "\(name)\(arity)"
        let parent = scopeStack.last?.displayName
        let signature = "func \(name)\(arity)"

        guard peekChar() == "{" else {
            // No body — protocol requirement / abstract declaration.
            symbols.append(Building(
                qualifiedName: qualifiedName, name: name, kind: kind, parent: parent,
                startLine: startLine, endLine: startLine, signature: signature
            ))
            return symbols.count - 1
        }

        depth += 1; pos += 1
        symbols.append(Building(
            qualifiedName: qualifiedName, name: name, kind: kind, parent: parent,
            startLine: startLine, endLine: -1, signature: signature
        ))
        let idx = symbols.count - 1
        scopeStack.append(Frame(
            displayName: name, qualifiedName: qualifiedName, kind: kind,
            isContainer: false, openDepth: depth, pendingSymbolIndex: idx
        ))
        return idx
    }

    // MARK: Header sub-parsers

    /// Parses an optional `: Base, Proto` inheritance clause, stopping at a
    /// top-level `{` or `where`. Returns the base identifiers (generic args
    /// stripped). Leaves `pos` at the `{` or `where` that terminated it.
    private func parseInheritanceIfPresent() -> [String] {
        guard peekChar() == ":" else { return [] }
        pos += 1
        skipWhitespace()
        let clauseStart = pos
        var localDepth = 0
        while pos < chars.count {
            let c = chars[pos]
            if localDepth == 0, c == "{" { break }
            if localDepth == 0, isIdentifierStart(c) {
                var j = pos
                var w = ""
                while j < chars.count, isIdentifierContinue(chars[j]) { w.append(chars[j]); j += 1 }
                if w == "where" { break }
                pos = j
                continue
            }
            switch c {
            case "<", "(", "[": localDepth += 1
            case ">", ")", "]": localDepth = max(0, localDepth - 1)
            default: break
            }
            pos += 1
        }
        let clauseText = String(chars[clauseStart..<pos])
        return LexicalSymbolExtractor.splitTopLevelCommaList(clauseText)
            .map(LexicalSymbolExtractor.baseIdentifier(of:))
            .filter { !$0.isEmpty }
    }

    /// Skips a `where <constraints>` clause (generic or extension), if present,
    /// through to the top-level `{`. No-op (and non-consuming) otherwise.
    private func skipWhereClauseIfPresent() {
        skipWhitespace()
        let save = pos
        guard let w = peekIdentifier(), w == "where" else { pos = save; return }
        _ = readIdentifier()
        var localDepth = 0
        while pos < chars.count {
            let c = chars[pos]
            if localDepth == 0, c == "{" { break }
            switch c {
            case "<", "(", "[": localDepth += 1
            case ">", ")", "]": localDepth = max(0, localDepth - 1)
            default: break
            }
            pos += 1
        }
    }

    /// Skips `async`/`throws`/`rethrows` and an optional `-> ReturnType`,
    /// stopping at the top-level `{` that opens the body, or determining
    /// there is none (protocol requirement / single-line declaration).
    private func skipFunctionTail() {
        var localDepth = 0
        let start = pos
        while pos < chars.count {
            let c = chars[pos]
            if localDepth == 0, c == "{" { return }
            if localDepth == 0, c == ";" { return }
            switch c {
            case "(", "[": localDepth += 1
            case ")", "]": localDepth = max(0, localDepth - 1)
            case "<": localDepth += 1
            case ">": localDepth = max(0, localDepth - 1)
            default: break
            }
            if localDepth == 0, c == "\n" {
                if let next = peekSignificant(after: pos + 1) {
                    if next == "}" || Self.topLevelStopKeywords.contains(next) { return }
                }
            }
            if pos - start > 4000 { return } // defensive runaway cap
            pos += 1
        }
    }

    /// Non-consuming: the next `{`, `}`, or identifier word at/after `idx`.
    private func peekSignificant(after idx: Int) -> String? {
        var i = idx
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        guard i < chars.count else { return nil }
        let c = chars[i]
        if c == "{" || c == "}" { return String(c) }
        guard isIdentifierStart(c) else { return nil }
        var w = ""
        while i < chars.count, isIdentifierContinue(chars[i]) { w.append(chars[i]); i += 1 }
        return w
    }

    /// Non-consuming lookahead for a dotted type name (`Foo` or `Outer.Inner`),
    /// as used after `extension`.
    private func peekDottedTypeName() -> String? {
        var i = pos
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        guard i < chars.count, isIdentifierStart(chars[i]) else { return nil }
        var s = ""
        while true {
            while i < chars.count, isIdentifierContinue(chars[i]) { s.append(chars[i]); i += 1 }
            if i < chars.count, chars[i] == ".", i + 1 < chars.count, isIdentifierStart(chars[i + 1]) {
                s.append("."); i += 1
            } else {
                break
            }
        }
        return s
    }

    private func consumeDottedTypeName() {
        skipWhitespace()
        while pos < chars.count, isIdentifierContinue(chars[pos]) { pos += 1 }
        while pos < chars.count, chars[pos] == ".", pos + 1 < chars.count, isIdentifierStart(chars[pos + 1]) {
            pos += 1
            while pos < chars.count, isIdentifierContinue(chars[pos]) { pos += 1 }
        }
    }
}

private extension LexicalSymbolExtractor {
    static func symbolKind(forTypeKeyword keyword: String) -> SymbolKind {
        switch keyword {
        case "class": return .class
        case "struct": return .struct
        case "enum": return .enum
        case "protocol": return .protocol
        case "actor": return .actor
        default: return .class
        }
    }
}
