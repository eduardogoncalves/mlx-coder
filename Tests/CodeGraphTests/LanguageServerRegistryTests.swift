// Tests/CodeGraphTests/LanguageServerRegistryTests.swift
// Extension → server/extractor resolution (plan §13.5).

import XCTest
@testable import MLXCoder

final class LanguageServerRegistryTests: XCTestCase {

    private let registry = LanguageServerRegistry.standard

    func testKnownExtensionsResolveToExpectedLanguage() {
        XCTAssertEqual(registry.language(forPath: "Foo.swift"), "swift")
        XCTAssertEqual(registry.language(forPath: "Foo.cs"), "csharp")
        XCTAssertEqual(registry.language(forPath: "foo.ts"), "typescript")
        XCTAssertEqual(registry.language(forPath: "foo.js"), "javascript")
        XCTAssertEqual(registry.language(forPath: "foo.jsx"), "javascript")
    }

    func testUnknownLanguageResolvesToNil() {
        XCTAssertNil(registry.language(forPath: "config.json"))
        XCTAssertNil(registry.language(forPath: "README.md"))
        XCTAssertNil(registry.language(forPath: "noextension"))
    }

    func testCaseInsensitiveExtensionMatch() {
        XCTAssertEqual(registry.language(forPath: "Foo.SWIFT"), "swift")
        XCTAssertEqual(registry.language(forPath: "Foo.CS"), "csharp")
    }

    // MARK: - Extractor selection follows CodeGraphConfig.treeSitter

    func testTreeSitterDisabledFallsBackToLexicalForSwiftAndNilForOthers() {
        XCTAssertTrue(registry.extractor(forPath: "Foo.swift", treeSitterEnabled: false) is LexicalSymbolExtractor)
        XCTAssertNil(registry.extractor(forPath: "Foo.cs", treeSitterEnabled: false))
        XCTAssertNil(registry.extractor(forPath: "foo.ts", treeSitterEnabled: false))
        XCTAssertNil(registry.extractor(forPath: "foo.js", treeSitterEnabled: false))
    }

    func testTreeSitterEnabledUsesTreeSitterExtractorForEveryVendoredGrammar() {
        for (path, expectedLanguage) in [("Foo.swift", "swift"), ("Foo.cs", "csharp"), ("foo.ts", "typescript"), ("foo.js", "javascript")] {
            guard let extractor = registry.extractor(forPath: path, treeSitterEnabled: true) as? TreeSitterExtractor else {
                return XCTFail("expected a TreeSitterExtractor for \(path)")
            }
            XCTAssertEqual(extractor.language, expectedLanguage)
        }
    }

    func testUnknownExtensionStaysNilRegardlessOfTreeSitterFlag() {
        XCTAssertNil(registry.extractor(forPath: "config.json", treeSitterEnabled: true))
        XCTAssertNil(registry.extractor(forPath: "config.json", treeSitterEnabled: false))
    }

    // MARK: - LSP spec presence (data only in Phase B — routing wired in Phase C)

    func testEveryVendoredLanguageCarriesAnLSPServerSpec() {
        for path in ["Foo.swift", "Foo.cs", "foo.ts", "foo.js"] {
            XCTAssertNotNil(registry.entry(forPath: path)?.lspServer, "expected an LSP server spec for \(path)")
        }
    }

    func testKnownExtensionsMatchesEntryKeys() {
        XCTAssertEqual(registry.knownExtensions, ["swift", "cs", "ts", "js", "jsx"])
    }
}
