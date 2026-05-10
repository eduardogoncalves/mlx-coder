import XCTest
@testable import MLXCoder

final class CodeSearchToolTests: XCTestCase {
    func testQueryContactFindsNestedPathMatchInCSharpFile() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let contactFile = workspace
            .appendingPathComponent("src", isDirectory: true)
            .appendingPathComponent("Meridiano52w.Data", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("Contact.cs")
        try FileManager.default.createDirectory(at: contactFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "public class Contact { }\n".write(to: contactFile, atomically: true, encoding: .utf8)

        let tool = CodeSearchTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let result = try await tool.execute(arguments: ["query": "Contact", "path": "."])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("src/Meridiano52w.Data/Models/Contact.cs"))
    }

    func testDefaultSearchWithoutLanguageHandlesNonSwiftFiles() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let contactFile = workspace.appendingPathComponent("Contact.cs")
        try "public class Contact { public string Email { get; set; } }\n".write(to: contactFile, atomically: true, encoding: .utf8)

        let tool = CodeSearchTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let result = try await tool.execute(arguments: ["query": "Email", "path": "."])

        XCTAssertFalse(result.isError)
        XCTAssertFalse(result.content.contains("No code symbols matching"))
        XCTAssertTrue(result.content.contains("Contact.cs"))
    }

    func testExplicitLanguageFilterStillRestrictsToSwift() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let swiftFile = workspace.appendingPathComponent("Contact.swift")
        let csharpFile = workspace.appendingPathComponent("Contact.cs")
        try "struct Contact { }\n".write(to: swiftFile, atomically: true, encoding: .utf8)
        try "public class Contact { }\n".write(to: csharpFile, atomically: true, encoding: .utf8)

        let tool = CodeSearchTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let result = try await tool.execute(arguments: ["query": "Contact", "path": ".", "language": "swift"])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Contact.swift"))
        XCTAssertFalse(result.content.contains("Contact.cs"))
    }

    func testPathMatchesExcludeBuildOutputDirectories() async throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let buildFile = workspace
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("GhostContact.swift")
        let sourceFile = workspace
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("GhostContact.swift")

        try FileManager.default.createDirectory(at: buildFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "// build output\n".write(to: buildFile, atomically: true, encoding: .utf8)
        try "// source file\n".write(to: sourceFile, atomically: true, encoding: .utf8)

        let tool = CodeSearchTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let result = try await tool.execute(arguments: ["query": "GhostContact", "path": "."])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Sources/GhostContact.swift"))
        XCTAssertFalse(result.content.contains(".build/GhostContact.swift"))
    }

    private func makeWorkspace() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("test-workspaces", isDirectory: true)
            .appendingPathComponent("mlx-coder-code-search-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
