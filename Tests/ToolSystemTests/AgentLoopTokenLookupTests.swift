import XCTest
@testable import MLXCoder

final class AgentLoopTokenLookupTests: XCTestCase {
    func testMakeTokenCountLookupHandlesDuplicateContent() {
        let lookup = AgentLoop.makeTokenCountLookup(
            contents: [
                "<tool_call>",
                "{\"name\":\"list_dir\",\"arguments\":{\"path\":\"src/portal.core/Models\"}}",
                "</tool_call>",
                "<tool_call>"
            ],
            counts: [1, 12, 1, 1]
        )

        XCTAssertEqual(lookup["<tool_call>"], 1)
        XCTAssertEqual(lookup["</tool_call>"], 1)
        XCTAssertEqual(lookup["{\"name\":\"list_dir\",\"arguments\":{\"path\":\"src/portal.core/Models\"}}"], 12)
        XCTAssertEqual(lookup.count, 3)
    }

    func testMakeTokenCountLookupUsesShortestInputLength() {
        let lookup = AgentLoop.makeTokenCountLookup(
            contents: ["a", "b", "c"],
            counts: [10, 20]
        )

        XCTAssertEqual(lookup["a"], 10)
        XCTAssertEqual(lookup["b"], 20)
        XCTAssertNil(lookup["c"])
    }
}
