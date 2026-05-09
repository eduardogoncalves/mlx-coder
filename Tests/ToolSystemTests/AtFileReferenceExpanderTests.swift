import XCTest
@testable import MLXCoder

final class AtFileReferenceExpanderTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("at-file-expander-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            XCTFail("Failed to create temp directory: \(error)")
        }
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    func testExpandsTokensSeparatedByNewlineAndTab() throws {
        let fileA = tempDir.appendingPathComponent("a.swift")
        let fileB = tempDir.appendingPathComponent("b.swift")
        try "let a = 1\n".write(to: fileA, atomically: true, encoding: .utf8)
        try "let b = 2\n".write(to: fileB, atomically: true, encoding: .utf8)

        let prompt = "Check @a.swift\nand\t@b.swift"
        let expanded = AtFileReferenceExpander.expand(prompt, workspaceRoot: tempDir.path)

        XCTAssertTrue(expanded.contains("**Contents of `a.swift`:**"))
        XCTAssertTrue(expanded.contains("**Contents of `b.swift`:**"))
    }

    func testTrimsTrailingPeriodFromAtPathToken() throws {
        let file = tempDir.appendingPathComponent("c.swift")
        try "let c = 3\n".write(to: file, atomically: true, encoding: .utf8)

        let prompt = "Read @c.swift."
        let expanded = AtFileReferenceExpander.expand(prompt, workspaceRoot: tempDir.path)

        XCTAssertTrue(expanded.contains("**Contents of `c.swift`:**"))
    }
}
