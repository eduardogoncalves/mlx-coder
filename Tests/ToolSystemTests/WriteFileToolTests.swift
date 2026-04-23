import XCTest
@testable import MLXCoder

final class WriteFileToolTests: XCTestCase {
    func testWriteFileAtWorkspaceRootSucceeds() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let permissions = PermissionEngine(workspaceRoot: workspace.path)
        let tool = WriteFileTool(permissions: permissions)

        let result = try await tool.execute(arguments: [
            "path": "hello.html",
            "content": "<h1>Hello</h1>\n"
        ])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Wrote"))

        let written = workspace.appendingPathComponent("hello.html")
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))
        let data = try String(contentsOf: written, encoding: .utf8)
        XCTAssertEqual(data, "<h1>Hello</h1>\n")
    }

    private func makeTempWorkspace() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mlx-coder-write-file-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
