import XCTest
@testable import NativeAgent

final class LSPWorkspaceEditApplierTests: XCTestCase {
    func testApplySingleReplacementEdit() throws {
        let original = "class A {\n    void M() {\n        var foo = 1;\n    }\n}\n"
        let edits: [[String: Any]] = [
            [
                "range": [
                    "start": ["line": 2, "character": 12],
                    "end": ["line": 2, "character": 15],
                ],
                "newText": "bar",
            ]
        ]

        let updated = try LSPWorkspaceEditApplier.applyEdits(originalText: original, rawEdits: edits)
        XCTAssertTrue(updated.contains("var bar = 1;"))
    }

    func testApplyMultipleEditsInReverseOrderSafely() throws {
        let original = "alpha beta gamma\n"
        let edits: [[String: Any]] = [
            [
                "range": [
                    "start": ["line": 0, "character": 11],
                    "end": ["line": 0, "character": 16],
                ],
                "newText": "delta",
            ],
            [
                "range": [
                    "start": ["line": 0, "character": 0],
                    "end": ["line": 0, "character": 5],
                ],
                "newText": "omega",
            ],
        ]

        let updated = try LSPWorkspaceEditApplier.applyEdits(originalText: original, rawEdits: edits)
        XCTAssertEqual(updated, "omega beta delta\n")
    }

    func testApplyEditsRejectsOutOfRangePosition() {
        let original = "line\n"
        let edits: [[String: Any]] = [
            [
                "range": [
                    "start": ["line": 0, "character": 20],
                    "end": ["line": 0, "character": 21],
                ],
                "newText": "x",
            ]
        ]

        XCTAssertThrowsError(try LSPWorkspaceEditApplier.applyEdits(originalText: original, rawEdits: edits))
    }

    func testApplyMultilineReplacementEdit() throws {
        let original = "start\nfoo\nbar\nend\n"
        let edits: [[String: Any]] = [
            [
                "range": [
                    "start": ["line": 1, "character": 0],
                    "end": ["line": 3, "character": 0],
                ],
                "newText": "joined\n",
            ]
        ]

        let updated = try LSPWorkspaceEditApplier.applyEdits(originalText: original, rawEdits: edits)
        XCTAssertEqual(updated, "start\njoined\nend\n")
    }

    func testApplyEditHandlesCRLFLineEndings() throws {
        let original = "a\r\nb\r\n"
        let edits: [[String: Any]] = [
            [
                "range": [
                    "start": ["line": 1, "character": 0],
                    "end": ["line": 1, "character": 1],
                ],
                "newText": "c",
            ]
        ]

        let updated = try LSPWorkspaceEditApplier.applyEdits(originalText: original, rawEdits: edits)
        XCTAssertEqual(updated, "a\r\nc\r\n")
    }

    func testRejectsOverlappingEdits() {
        let original = "abcdef\n"
        let edits: [[String: Any]] = [
            [
                "range": [
                    "start": ["line": 0, "character": 1],
                    "end": ["line": 0, "character": 4],
                ],
                "newText": "X",
            ],
            [
                "range": [
                    "start": ["line": 0, "character": 3],
                    "end": ["line": 0, "character": 5],
                ],
                "newText": "Y",
            ]
        ]

        XCTAssertThrowsError(try LSPWorkspaceEditApplier.applyEdits(originalText: original, rawEdits: edits))
    }
}
