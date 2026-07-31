// Tests/CodeGraphTests/TreeSitterExtractorTests.swift
// Golden-case tests for the tree-sitter base-tier extractor (plan §13.5):
// node/edge/syntactic-call extraction for Swift, C#, and TypeScript, plus
// error-recovery on truncated source (tree-sitter never throws — a
// malformed/half-edited file must still degrade gracefully, not crash the
// indexer).

import XCTest
@testable import MLXCoder

final class TreeSitterExtractorTests: XCTestCase {

    // MARK: - Helpers

    private func symbol(_ result: ExtractionResult, _ qualifiedName: String) -> RawSymbol? {
        result.symbols.first { $0.qualifiedName == qualifiedName }
    }

    private func edges(_ result: ExtractionResult, from src: String, kind: EdgeKind) -> [RawEdge] {
        result.edges.filter { $0.srcQualifiedName == src && $0.kind == kind }
    }

    // MARK: - Swift

    func testSwiftClassWithInheritanceMethodsAndCalls() {
        let extractor = TreeSitterExtractor(languageID: .swift)
        let source = """
        import Foundation

        class Foo: Base, Codable {
            func bar(_ x: Int, label y: String) -> Bool {
                self.baz(x)
                return true
            }
        }

        protocol Greeter {
            func greet()
        }
        """
        let result = extractor.extract(path: "Foo.swift", source: source)

        XCTAssertEqual(symbol(result, RawSymbol.fileAnchorQualifiedName)?.kind, .file)

        guard let foo = symbol(result, "Foo") else { return XCTFail("expected Foo symbol") }
        XCTAssertEqual(foo.kind, .class)
        XCTAssertNil(foo.parent)

        guard let bar = symbol(result, "Foo.bar(_:label:)") else {
            return XCTFail("expected Foo.bar(_:label:) symbol, got \(result.symbols.map(\.qualifiedName))")
        }
        XCTAssertEqual(bar.kind, .method)
        XCTAssertEqual(bar.parent, "Foo")

        XCTAssertNotNil(symbol(result, "Greeter"))
        XCTAssertEqual(symbol(result, "Greeter")?.kind, .protocol)

        XCTAssertTrue(edges(result, from: RawSymbol.fileAnchorQualifiedName, kind: .imports).contains { $0.dstName == "Foundation" })
        XCTAssertEqual(edges(result, from: "Foo", kind: .extends).map(\.dstName), ["Base"])
        XCTAssertEqual(edges(result, from: "Foo", kind: .implements).map(\.dstName), ["Codable"])

        // Syntactic call: `self.baz(x)` inside `bar` → calls edge to "baz".
        let calls = edges(result, from: "Foo.bar(_:label:)", kind: .calls)
        XCTAssertTrue(calls.contains { $0.dstName == "baz" }, "expected a calls edge to baz, got \(calls)")
    }

    func testSwiftStructEnumActorKinds() {
        let extractor = TreeSitterExtractor(languageID: .swift)
        let source = """
        struct Point { func length() -> Int { return 0 } }
        enum Direction { case north }
        actor Counter { func increment() {} }
        """
        let result = extractor.extract(path: "Shapes.swift", source: source)

        XCTAssertEqual(symbol(result, "Point")?.kind, .struct)
        XCTAssertEqual(symbol(result, "Direction")?.kind, .enum)
        XCTAssertEqual(symbol(result, "Counter")?.kind, .actor)
    }

    func testSwiftInitializer() {
        let extractor = TreeSitterExtractor(languageID: .swift)
        let source = """
        class Widget {
            init(name: String) {
                self.name = name
            }
        }
        """
        let result = extractor.extract(path: "Widget.swift", source: source)
        XCTAssertTrue(result.symbols.contains { $0.kind == .initializer && $0.parent == "Widget" })
    }

    // MARK: - C#

    func testCSharpClassWithBaseListMethodsAndCalls() {
        let extractor = TreeSitterExtractor(languageID: .csharp)
        let source = """
        using System;

        namespace NS {
            public class Foo : Base, IGreeter {
                public bool Bar(int x, string y) {
                    this.Baz(x);
                    return true;
                }
            }
            public interface IGreeter {}
        }
        """
        let result = extractor.extract(path: "Foo.cs", source: source)

        guard let foo = symbol(result, "Foo") else { return XCTFail("expected Foo symbol, got \(result.symbols.map(\.qualifiedName))") }
        XCTAssertEqual(foo.kind, .class)

        XCTAssertNotNil(symbol(result, "IGreeter"))
        XCTAssertEqual(symbol(result, "IGreeter")?.kind, .protocol)

        XCTAssertTrue(edges(result, from: RawSymbol.fileAnchorQualifiedName, kind: .imports).contains { $0.dstName == "System" })
        XCTAssertEqual(edges(result, from: "Foo", kind: .extends).map(\.dstName), ["Base"])
        XCTAssertEqual(edges(result, from: "Foo", kind: .implements).map(\.dstName), ["IGreeter"])

        guard let bar = result.symbols.first(where: { $0.name == "Bar" && $0.parent == "Foo" }) else {
            return XCTFail("expected Foo.Bar method, got \(result.symbols.map(\.qualifiedName))")
        }
        let calls = edges(result, from: bar.qualifiedName, kind: .calls)
        XCTAssertTrue(calls.contains { $0.dstName == "Baz" }, "expected a calls edge to Baz, got \(calls)")
    }

    // MARK: - TypeScript

    func testTypeScriptInterfaceClassImplementsAndCalls() {
        let extractor = TreeSitterExtractor(languageID: .typescript)
        let source = """
        import { Base } from './base';

        interface IGreeter {
            greet(): void;
        }

        class Foo extends Base implements IGreeter {
            greet(): void {
                this.log("hi");
            }
        }
        """
        let result = extractor.extract(path: "foo.ts", source: source)

        XCTAssertTrue(edges(result, from: RawSymbol.fileAnchorQualifiedName, kind: .imports).contains { $0.dstName == "Base" })

        XCTAssertEqual(symbol(result, "IGreeter")?.kind, .protocol)

        guard let foo = symbol(result, "Foo") else { return XCTFail("expected Foo symbol, got \(result.symbols.map(\.qualifiedName))") }
        XCTAssertEqual(foo.kind, .class)
        XCTAssertEqual(edges(result, from: "Foo", kind: .extends).map(\.dstName), ["Base"])
        XCTAssertEqual(edges(result, from: "Foo", kind: .implements).map(\.dstName), ["IGreeter"])

        guard let greet = result.symbols.first(where: { $0.name == "greet" && $0.parent == "Foo" }) else {
            return XCTFail("expected Foo.greet method, got \(result.symbols.map(\.qualifiedName))")
        }
        let calls = edges(result, from: greet.qualifiedName, kind: .calls)
        XCTAssertTrue(calls.contains { $0.dstName == "log" }, "expected a calls edge to log, got \(calls)")
    }

    func testJavaScriptFunctionAndMethodCalls() {
        let extractor = TreeSitterExtractor(languageID: .javascript)
        let source = """
        class Bar {
            baz(x) {
                this.qux(x);
            }
        }
        function top(a, b) { return helper(a, b); }
        """
        let result = extractor.extract(path: "bar.js", source: source)

        XCTAssertNotNil(symbol(result, "Bar"))
        guard let top = symbol(result, "top(a,b)") else {
            return XCTFail("expected top(a,b) symbol, got \(result.symbols.map(\.qualifiedName))")
        }
        XCTAssertEqual(top.kind, .function)
        XCTAssertTrue(edges(result, from: top.qualifiedName, kind: .calls).contains { $0.dstName == "helper" })
    }

    // MARK: - Error recovery (never throws, always degrades)

    func testHalfEditedSwiftSourceRecoversTheEnclosingDeclarations() {
        // Simulates a file mid-edit: the outer `class`'s closing brace hasn't
        // been typed yet, but the method inside it is complete. tree-sitter's
        // error recovery should still recognize both declarations (this is
        // exactly the case the plan calls out as the reason to prefer
        // tree-sitter over a brace-counting lexical scanner for this tier).
        let extractor = TreeSitterExtractor(languageID: .swift)
        let source = "class Foo: Base {\n    func bar(x: Int) -> Bool {\n        return true\n    }\n"
        let result = extractor.extract(path: "Truncated.swift", source: source)
        XCTAssertEqual(symbol(result, RawSymbol.fileAnchorQualifiedName)?.kind, .file)
        XCTAssertNotNil(symbol(result, "Foo"))
        XCTAssertNotNil(symbol(result, "Foo.bar(x:)"))
    }

    func testSeverelyTruncatedSwiftSourceDoesNotCrash() {
        // A much more aggressive truncation (cut off mid-expression, no
        // closing braces anywhere) may not recover the enclosing
        // declarations at all — that's fine; the only hard requirement is
        // "never throws / never crashes the indexer", not "always recovers".
        let extractor = TreeSitterExtractor(languageID: .swift)
        let source = "class Foo: Base {\n    func bar(x: Int) -> Bool {\n        return tr"
        let result = extractor.extract(path: "Truncated.swift", source: source)
        XCTAssertEqual(symbol(result, RawSymbol.fileAnchorQualifiedName)?.kind, .file)
    }

    func testEmptySourceYieldsOnlyFileAnchor() {
        let extractor = TreeSitterExtractor(languageID: .csharp)
        let result = extractor.extract(path: "Empty.cs", source: "")
        XCTAssertEqual(result.symbols.count, 1)
        XCTAssertEqual(result.symbols.first?.kind, .file)
        XCTAssertTrue(result.edges.isEmpty)
    }

    func testGarbageSourceDoesNotCrash() {
        for id in TreeSitterLanguageID.allCases {
            let extractor = TreeSitterExtractor(languageID: id)
            let result = extractor.extract(path: "garbage.txt", source: "}}}{{{ ) ) ( random \0 bytes \u{FFFD}")
            // Must not crash; file anchor is always present.
            XCTAssertEqual(result.symbols.first?.kind, .file)
        }
    }

    // MARK: - Determinism

    func testDeterministicAcrossRepeatedExtraction() {
        let extractor = TreeSitterExtractor(languageID: .swift)
        let source = "class Foo: Base { func bar() {} }"
        let first = extractor.extract(path: "Foo.swift", source: source)
        let second = extractor.extract(path: "Foo.swift", source: source)
        XCTAssertEqual(first.symbols, second.symbols)
        XCTAssertEqual(first.edges, second.edges)
    }
}
