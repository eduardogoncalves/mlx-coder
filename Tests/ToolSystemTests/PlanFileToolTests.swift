import XCTest
@testable import MLXCoder

final class PlanFileToolTests: XCTestCase {
    func testWriteCreatesWorkspacePlanFile() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let tool = PlanFileTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let result = try await tool.execute(arguments: [
            "action": "write",
            "content": "# Plan\n\n- [ ] First step\n"
        ])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Wrote"))

        let written = workspace.appendingPathComponent("PLAN.MD")
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))
        XCTAssertEqual(try String(contentsOf: written, encoding: .utf8), "# Plan\n\n- [ ] First step\n")
    }

    func testEditUpdatesExistingPlanFile() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let planFile = workspace.appendingPathComponent("PLAN.MD")
        try "# Plan\n\n- [ ] First step\n".write(to: planFile, atomically: true, encoding: .utf8)

        let tool = PlanFileTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let result = try await tool.execute(arguments: [
            "action": "edit",
            "old_text": "- [ ] First step",
            "new_text": "- [x] First step"
        ])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Applied edit to PLAN.MD"))
        XCTAssertTrue(result.content.contains("- [ ] First step"))
        XCTAssertTrue(result.content.contains("+- [x] First step"))
        XCTAssertEqual(try String(contentsOf: planFile, encoding: .utf8), "# Plan\n\n- [x] First step\n")
    }

    func testUnknownActionReturnsError() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let tool = PlanFileTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let result = try await tool.execute(arguments: ["action": "append"])

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("Use 'write' or 'edit'"))
    }

    private func makeTempWorkspace() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mlx-coder-plan-file-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
