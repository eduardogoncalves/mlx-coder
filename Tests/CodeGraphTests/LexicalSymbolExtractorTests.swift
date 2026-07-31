// Tests/CodeGraphTests/LexicalSymbolExtractorTests.swift
// Golden-case tests for the zero-dependency Swift lexical extractor.

import XCTest
@testable import MLXCoder

final class LexicalSymbolExtractorTests: XCTestCase {

    private let extractor = LexicalSymbolExtractor()

    // MARK: - Helpers

    private func symbol(_ result: ExtractionResult, _ qualifiedName: String) -> RawSymbol? {
        result.symbols.first { $0.qualifiedName == qualifiedName }
    }

    private func edges(_ result: ExtractionResult, from src: String, kind: EdgeKind) -> [RawEdge] {
        result.edges.filter { $0.srcQualifiedName == src && $0.kind == kind }
    }

    // MARK: - Nodes + imports + inheritance

    func testClassWithSuperclassAndProtocolConformance() {
        let source = """
        import Foundation

        class Foo: Base, Codable {
            func bar(_ x: Int, label y: String) -> Bool {
                return true
            }
        }
        """
        let result = extractor.extract(path: "Test.swift", source: source)

        let fileAnchor = symbol(result, RawSymbol.fileAnchorQualifiedName)
        XCTAssertNotNil(fileAnchor)
        XCTAssertEqual(fileAnchor?.kind, .file)

        guard let foo = symbol(result, "Foo") else { return XCTFail("expected Foo symbol") }
        XCTAssertEqual(foo.kind, .class)
        XCTAssertNil(foo.parent)
        XCTAssertEqual(foo.startLine, 3)
        XCTAssertEqual(foo.endLine, 7)

        guard let bar = symbol(result, "Foo.bar(_:label:)") else { return XCTFail("expected Foo.bar(_:label:) symbol") }
        XCTAssertEqual(bar.kind, .method)
        XCTAssertEqual(bar.parent, "Foo")
        XCTAssertEqual(bar.startLine, 4)
        XCTAssertEqual(bar.endLine, 6)

        // import → file anchor
        let importEdges = edges(result, from: RawSymbol.fileAnchorQualifiedName, kind: .imports)
        XCTAssertTrue(importEdges.contains { $0.dstName == "Foundation" })

        // First inherited item on a `class` → extends; the rest → implements.
        let extendsEdges = edges(result, from: "Foo", kind: .extends)
        XCTAssertEqual(extendsEdges.map(\.dstName), ["Base"])
        let implementsEdges = edges(result, from: "Foo", kind: .implements)
        XCTAssertEqual(implementsEdges.map(\.dstName), ["Codable"])

        // `calls` must never be emitted by the lexical extractor (plan §2.1).
        XCTAssertTrue(result.edges.filter { $0.kind == .calls }.isEmpty)
    }

    func testStructAndEnumConformancesAreAllImplements() {
        let source = """
        struct Point: Codable, Hashable {
            let x: Int
        }
        enum Direction: String, CaseIterable {
            case north, south
        }
        """
        let result = extractor.extract(path: "Shapes.swift", source: source)

        guard let point = symbol(result, "Point") else { return XCTFail("expected Point symbol") }
        XCTAssertEqual(point.kind, .struct)
        XCTAssertTrue(edges(result, from: "Point", kind: .extends).isEmpty)
        XCTAssertEqual(Set(edges(result, from: "Point", kind: .implements).map(\.dstName)), ["Codable", "Hashable"])

        guard let direction = symbol(result, "Direction") else { return XCTFail("expected Direction symbol") }
        XCTAssertEqual(direction.kind, .enum)
        XCTAssertEqual(Set(edges(result, from: "Direction", kind: .implements).map(\.dstName)), ["String", "CaseIterable"])
    }

    func testProtocolRequirementHasNoBody() {
        let source = """
        protocol Greeter {
            func greet(name: String) -> String
        }
        """
        let result = extractor.extract(path: "Greeter.swift", source: source)

        guard let proto = symbol(result, "Greeter") else { return XCTFail("expected Greeter symbol") }
        XCTAssertEqual(proto.kind, .protocol)
        XCTAssertEqual(proto.startLine, 1)
        XCTAssertEqual(proto.endLine, 3)

        guard let greet = symbol(result, "Greeter.greet(name:)") else { return XCTFail("expected Greeter.greet(name:) symbol") }
        XCTAssertEqual(greet.kind, .method)
        XCTAssertEqual(greet.startLine, 2)
        XCTAssertEqual(greet.endLine, 2, "a body-less protocol requirement should not swallow following lines")
    }

    // MARK: - Multi-line signatures (this codebase's own dominant style)

    func testMultiLineFunctionSignatureIsCapturedWithCorrectArityAndLines() {
        let source = """
        struct Widget {
            func configure(
                name: String,
                count: Int = 1
            ) -> Bool {
                return true
            }
        }
        """
        let result = extractor.extract(path: "Widget.swift", source: source)

        guard let widget = symbol(result, "Widget") else { return XCTFail("expected Widget symbol") }
        XCTAssertEqual(widget.startLine, 1)
        XCTAssertEqual(widget.endLine, 8)

        guard let configure = symbol(result, "Widget.configure(name:count:)") else {
            return XCTFail("expected Widget.configure(name:count:) — multi-line signature not parsed")
        }
        XCTAssertEqual(configure.kind, .method)
        XCTAssertEqual(configure.startLine, 2)
        XCTAssertEqual(configure.endLine, 7)
    }

    // MARK: - Nested types / qualification

    func testNestedTypeQualifiedNameIncludesFullAncestorChain() {
        let source = """
        class Outer {
            struct Inner {
                func helper() -> Int { 1 }
            }
        }
        """
        let result = extractor.extract(path: "Nested.swift", source: source)

        guard let inner = symbol(result, "Outer.Inner") else { return XCTFail("expected Outer.Inner symbol") }
        XCTAssertEqual(inner.parent, "Outer", "parent column stores only the immediate enclosing symbol's bare name")

        guard let helper = symbol(result, "Outer.Inner.helper()") else {
            return XCTFail("expected Outer.Inner.helper() — full ancestor chain in qualifiedName")
        }
        XCTAssertEqual(helper.parent, "Inner")
    }

    // MARK: - Initializers

    func testFailableInitializerIsDistinctFromPlainInitializer() {
        let source = """
        struct Money {
            init(cents: Int) {
                self.cents = cents
            }
            init?(string: String) {
                return nil
            }
            let cents: Int
        }
        """
        let result = extractor.extract(path: "Money.swift", source: source)

        XCTAssertNotNil(symbol(result, "Money.init(cents:)"))
        XCTAssertNotNil(symbol(result, "Money.init?(string:)"))
    }

    // MARK: - Extension conformances → file anchor

    func testExtensionConformanceAttributesToFileAnchorNotADuplicateSymbol() {
        let source = """
        class Foo {
        }

        extension Foo: Equatable {
            static func == (lhs: Foo, rhs: Foo) -> Bool {
                return true
            }
        }
        """
        let result = extractor.extract(path: "Foo.swift", source: source)

        // Exactly one "Foo" symbol — the extension must not create a second,
        // colliding `symbol_key`.
        XCTAssertEqual(result.symbols.filter { $0.qualifiedName == "Foo" }.count, 1)

        let implementsFromFile = edges(result, from: RawSymbol.fileAnchorQualifiedName, kind: .implements)
        XCTAssertTrue(implementsFromFile.contains { $0.dstName == "Equatable" })

        // The operator function itself isn't captured as a symbol (no
        // identifier name to key on), but its body must not corrupt brace
        // depth tracking for the enclosing extension.
        XCTAssertNil(symbol(result, "Foo.==(lhs:rhs:)"))
    }

    // MARK: - References (by-name, coarse)

    func testReferencesEdgeCapturesNonBuiltinCapitalizedIdentifiers() {
        let source = """
        class Repository {
            func load() -> Widget {
                return WidgetFactory.make()
            }
        }
        """
        let result = extractor.extract(path: "Repository.swift", source: source)
        let refs = edges(result, from: "Repository.load()", kind: .references)
        XCTAssertEqual(Set(refs.map(\.dstName)), ["Widget", "WidgetFactory"])
    }

    func testReferencesEdgeExcludesCommonBuiltins() {
        let source = """
        class Calc {
            func compute() -> Int {
                let s: String = "x"
                return s.count
            }
        }
        """
        let result = extractor.extract(path: "Calc.swift", source: source)
        let refs = edges(result, from: "Calc.compute()", kind: .references)
        XCTAssertTrue(refs.isEmpty, "String/Int are blocklisted builtins, not real references")
    }

    // MARK: - Comment / string blanking safety

    func testBracesInsideStringsAndCommentsDoNotCorruptNesting() {
        let source = """
        class Config {
            // a comment with a brace { that must not open a scope
            let greeting = "hello { world } // not a comment"
            func value() -> String {
                return "{}"
            }
        }
        """
        let result = extractor.extract(path: "Config.swift", source: source)
        guard let config = symbol(result, "Config") else { return XCTFail("expected Config symbol") }
        XCTAssertEqual(config.startLine, 1)
        XCTAssertEqual(config.endLine, 7)
        XCTAssertNotNil(symbol(result, "Config.value()"))
    }

    // MARK: - Empty file

    func testEmptySourceProducesOnlyFileAnchor() {
        let result = extractor.extract(path: "Empty.swift", source: "")
        XCTAssertEqual(result.symbols.count, 1)
        XCTAssertEqual(result.symbols.first?.kind, .file)
        XCTAssertTrue(result.edges.isEmpty)
    }

    // MARK: - Static helpers

    func testParameterLabelParsingRules() {
        XCTAssertEqual(LexicalSymbolExtractor.parameterLabels(from: ""), [])
        XCTAssertEqual(LexicalSymbolExtractor.parameterLabels(from: "_ x: Int"), ["_"])
        XCTAssertEqual(LexicalSymbolExtractor.parameterLabels(from: "x: Int"), ["x"])
        XCTAssertEqual(LexicalSymbolExtractor.parameterLabels(from: "ext int_: Int"), ["ext"])
        XCTAssertEqual(
            LexicalSymbolExtractor.parameterLabels(from: "a: Int, b: [String: Int] = [:], _ c: (Int) -> Void"),
            ["a", "b", "_"]
        )
    }
}
