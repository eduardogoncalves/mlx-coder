import XCTest
@testable import MLXCoder

final class LSPDiagnosticsManualTests: XCTestCase {
    // Temporary manual harness workspace. Override with
    // NATIVE_AGENT_LSP_TEST_WORKSPACE environment variable.
    private let defaultWorkspace = NSTemporaryDirectory() + "mlx-coder-lsp-test"

    func testRunDiagnosticsForTeste006() async throws {
        try requireManualLSPTestsEnabled()
        let workspace = ProcessInfo.processInfo.environment["NATIVE_AGENT_LSP_TEST_WORKSPACE"] ?? defaultWorkspace
        let permissions = PermissionEngine(workspaceRoot: workspace)
        let tool = LSPDiagnosticsTool(permissions: permissions)

        let result = try await tool.execute(arguments: ["file_path": NSNull()])
        print("lsp_diagnostics output:\n\(result.content)")

        await DotnetLSPService.shared.shutdown()

        XCTAssertFalse(result.isError, "lsp_diagnostics failed: \(result.content)")
    }

    func testRunHoverAndReferencesForDiscoveredClassSymbol() async throws {
        try requireManualLSPTestsEnabled()
        let workspace = ProcessInfo.processInfo.environment["NATIVE_AGENT_LSP_TEST_WORKSPACE"] ?? defaultWorkspace
        let permissions = PermissionEngine(workspaceRoot: workspace)

        // Warm up LSP and ensure workspace is initialized before symbol queries.
        let diagnostics = try await LSPDiagnosticsTool(permissions: permissions).execute(arguments: ["file_path": NSNull()])
        XCTAssertFalse(diagnostics.isError, "lsp_diagnostics warm-up failed: \(diagnostics.content)")

        let symbol = try findFirstClassSymbol(in: workspace)
        print("selected symbol: \(symbol.relativePath):\(symbol.line):\(symbol.character)")

        let hover = try await LSPHoverTool(permissions: permissions).execute(arguments: [
            "file_path": symbol.relativePath,
            "line": symbol.line,
            "character": symbol.character,
        ])
        print("lsp_hover output:\n\(hover.content)")
        if hover.isError && hover.content.contains("timed out") {
            throw XCTSkip("lsp_hover timed out in this workspace: \(hover.content)")
        }
        XCTAssertFalse(hover.isError, "lsp_hover failed: \(hover.content)")

        let references = try await LSPReferencesTool(permissions: permissions).execute(arguments: [
            "file_path": symbol.relativePath,
            "line": symbol.line,
            "character": symbol.character,
        ])
        print("lsp_references output:\n\(references.content)")
        if references.isError && references.content.contains("timed out") {
            throw XCTSkip("lsp_references timed out in this workspace: \(references.content)")
        }
        XCTAssertFalse(references.isError, "lsp_references failed: \(references.content)")

        await DotnetLSPService.shared.shutdown()
    }

    private func requireManualLSPTestsEnabled() throws {
        let enabled = ProcessInfo.processInfo.environment["NATIVE_AGENT_ENABLE_MANUAL_LSP_TESTS"]
        if enabled != "1" {
            throw XCTSkip("Manual LSP tests are disabled by default. Set NATIVE_AGENT_ENABLE_MANUAL_LSP_TESTS=1 to run.")
        }
    }

    private func findFirstClassSymbol(in workspace: String) throws -> (relativePath: String, line: Int, character: Int) {
        let root = URL(filePath: workspace)
        var preferredFiles: [URL] = []
        var fallbackFiles: [URL] = []

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw NSError(domain: "LSPDiagnosticsManualTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to scan workspace for .cs files"])
        }

        while let entry = enumerator.nextObject() as? URL {
            if ["bin", "obj", ".git"].contains(entry.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }

            guard entry.pathExtension == "cs" else {
                continue
            }

            let name = entry.lastPathComponent.lowercased()
            if name.hasSuffix(".g.cs") || name.hasSuffix(".generated.cs") || name.contains("assemblyinfo") {
                continue
            }

            if name == "program.cs" {
                preferredFiles.append(entry)
            } else {
                fallbackFiles.append(entry)
            }
        }

        let candidateFiles = preferredFiles + fallbackFiles
        for entry in candidateFiles {
            let source = (try? String(contentsOf: entry, encoding: .utf8)) ?? ""
            let lines = source.components(separatedBy: .newlines)
            for (lineIndex, line) in lines.enumerated() {
                if let range = line.range(of: "class ") {
                    let symbolStart = line.distance(from: line.startIndex, to: range.upperBound)
                    let relative = String(entry.path.dropFirst(root.path().count + 1))
                    return (relativePath: relative, line: lineIndex, character: symbolStart)
                }
            }
        }

        throw NSError(domain: "LSPDiagnosticsManualTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "No C# class symbol found in workspace"])
    }
}