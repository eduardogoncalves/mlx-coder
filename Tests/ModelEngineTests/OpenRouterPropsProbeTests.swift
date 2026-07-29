import XCTest
@testable import MLXCoder

/// Verifies the pure pieces of `OpenRouterClient.fetchContextWindow` — the
/// `/props` payload parser and the candidate-URL derivation — that let mlx-coder
/// discover a remote model's real context window before the first overflow.
final class OpenRouterPropsProbeTests: XCTestCase {

    // MARK: - parseContextWindow

    func testParsesTopLevelNCtx() {
        let data = Data(#"{"n_ctx":32768,"model":"qwen"}"#.utf8)
        XCTAssertEqual(OpenRouterClient.parseContextWindow(from: data), 32768)
    }

    func testParsesNestedDefaultGenerationSettings() {
        let data = Data(#"{"default_generation_settings":{"n_ctx":18432}}"#.utf8)
        XCTAssertEqual(OpenRouterClient.parseContextWindow(from: data), 18432)
    }

    func testTopLevelWinsOverNested() {
        let data = Data(#"{"n_ctx":32768,"default_generation_settings":{"n_ctx":18432}}"#.utf8)
        XCTAssertEqual(OpenRouterClient.parseContextWindow(from: data), 32768)
    }

    func testReturnsNilWhenAbsent() {
        XCTAssertNil(OpenRouterClient.parseContextWindow(from: Data(#"{"model":"qwen"}"#.utf8)))
    }

    func testReturnsNilOnMalformedJSON() {
        XCTAssertNil(OpenRouterClient.parseContextWindow(from: Data("not json".utf8)))
    }

    // MARK: - propsProbeURLs

    func testProbesUnderBaseAndRootWhenVersioned() {
        let urls = OpenRouterClient.propsProbeURLs(baseURL: URL(string: "http://localhost:8080/v1")!)
        XCTAssertEqual(urls.map(\.absoluteString), [
            "http://localhost:8080/v1/props",
            "http://localhost:8080/props",
        ])
    }

    func testProbesOnlyUnderBaseWhenUnversioned() {
        let urls = OpenRouterClient.propsProbeURLs(baseURL: URL(string: "http://localhost:8080")!)
        XCTAssertEqual(urls.map(\.absoluteString), ["http://localhost:8080/props"])
    }
}
