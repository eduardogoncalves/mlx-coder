// Tests/AgentCoreTests/CodeModeIntegrationTests.swift
// Exercises ExecuteCodeTool through a REAL AgentLoop.executeSubToolCall
// dispatcher (not a mock), the same way TaskTool wires it for a sub-agent —
// verifying that a script's sub-calls actually go through the real
// permission pipeline (e.g. an out-of-workspace read is denied exactly like
// a direct tool call would be), not some parallel, weaker path.

import XCTest
@testable import MLXCoder

final class CodeModeIntegrationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        if ProcessInfo.processInfo.environment["MLXCODER_CODE_MODE_WORKER_PATH"] == nil,
           let path = CodeModeIntegrationTests.locateCodeModeWorkerBinary() {
            setenv("MLXCODER_CODE_MODE_WORKER_PATH", path, 1)
        }
    }

    /// Locates the just-built CodeModeWorker binary relative to this test
    /// file's own on-disk path — duplicated from ExecuteCodeToolTests (a
    /// sibling but separate SPM test target; `@testable import MLXCoder`
    /// only exposes the main module, not sibling test targets).
    static func locateCodeModeWorkerBinary(file: StaticString = #filePath) -> String? {
        var dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while dir.pathComponents.count > 1 {
            let buildDir = dir.appendingPathComponent(".build")
            if let archDirs = try? FileManager.default.contentsOfDirectory(atPath: buildDir.path) {
                for archDir in archDirs {
                    for config in ["debug", "release"] {
                        let candidate = buildDir
                            .appendingPathComponent(archDir)
                            .appendingPathComponent(config)
                            .appendingPathComponent("CodeModeWorker")
                        if FileManager.default.isExecutableFile(atPath: candidate.path) {
                            return candidate.path
                        }
                    }
                }
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    private func makeTempWorkspace() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mlx-coder-code-mode-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Mirrors TaskTool.run's shape: a scoped registry, a sub-agent
    /// AgentLoop over it in AGENT mode (so destructive calls don't hit the
    /// PLAN-mode block), and an ExecuteCodeTool registered with a dispatcher
    /// that calls back into that same AgentLoop's `executeSubToolCall`.
    private func makeSubAgentWithExecuteCode(workspace: URL, extraTools: [any Tool]) async -> (AgentLoop, ExecuteCodeTool.ExposedTool) {
        let permissions = PermissionEngine(workspaceRoot: workspace.path)
        let registry = ToolRegistry()
        for tool in extraTools {
            await registry.register(tool)
        }

        let subAgent = AgentLoop(
            modelContainer: nil,
            registry: registry,
            permissions: permissions,
            generationConfig: GenerationEngine.Config(),
            frontend: NullAgentFrontend(),
            systemPrompt: "test",
            modelPath: "mlx-community/test-model",
            workspace: workspace.path,
            role: "executor",
            subAgentBaseInstructions: "test executor"
        )
        await subAgent.configureForSubAgentExecution(taskType: .coding, parentAutoApproveAllTools: true)

        let readFileSignature = ExecuteCodeTool.ExposedTool(
            name: "read_file",
            description: "read a file",
            parameters: JSONSchema(type: "object", properties: ["path": PropertySchema(type: "string")], required: ["path"])
        )
        return (subAgent, readFileSignature)
    }

    func testSubCallOutsideWorkspaceIsDeniedThroughTheRealPipeline() async throws {
        guard CodeModeIntegrationTests.locateCodeModeWorkerBinary() != nil else {
            throw XCTSkip("CodeModeWorker binary not built — run `swift build` first")
        }
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let readFileTool = ReadFileTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let (subAgent, readFileSignature) = await makeSubAgentWithExecuteCode(workspace: workspace, extraTools: [readFileTool])

        let executeCodeTool = ExecuteCodeTool(
            exposedTools: [readFileSignature],
            permissions: PermissionEngine(workspaceRoot: workspace.path),
            useSandbox: false,
            dispatcher: { name, arguments in
                nonisolated(unsafe) let isolatedArguments = arguments
                return await subAgent.executeSubToolCall(name: name, arguments: isolatedArguments)
            }
        )

        let code = """
        try {
            await tools.read_file({path: "/etc/passwd"});
            return "should have been denied";
        } catch (e) {
            return { caught: e.message };
        }
        """
        let result = try await executeCodeTool.execute(arguments: ["code": code])

        XCTAssertFalse(result.isError)
        XCTAssertFalse(result.content.contains("should have been denied"), "an out-of-workspace read must be denied by the real permission pipeline, not silently allowed through code mode: \(result.content)")
    }

    func testSubCallInsideWorkspaceSucceedsThroughTheRealPipeline() async throws {
        guard CodeModeIntegrationTests.locateCodeModeWorkerBinary() != nil else {
            throw XCTSkip("CodeModeWorker binary not built — run `swift build` first")
        }
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let fileURL = workspace.appendingPathComponent("hello.txt")
        try "hello from disk".write(to: fileURL, atomically: true, encoding: .utf8)

        let readFileTool = ReadFileTool(permissions: PermissionEngine(workspaceRoot: workspace.path))
        let (subAgent, readFileSignature) = await makeSubAgentWithExecuteCode(workspace: workspace, extraTools: [readFileTool])

        let executeCodeTool = ExecuteCodeTool(
            exposedTools: [readFileSignature],
            permissions: PermissionEngine(workspaceRoot: workspace.path),
            useSandbox: false,
            dispatcher: { name, arguments in
                nonisolated(unsafe) let isolatedArguments = arguments
                return await subAgent.executeSubToolCall(name: name, arguments: isolatedArguments)
            }
        )

        let code = "const content = await tools.read_file({path: \"hello.txt\"}); return { content: content };"
        let result = try await executeCodeTool.execute(arguments: ["code": code])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("hello from disk"), "expected the real file's content to come back through the real pipeline: \(result.content)")
    }

    func testExecuteCodeCannotDispatchItself() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let (subAgent, _) = await makeSubAgentWithExecuteCode(workspace: workspace, extraTools: [])
        let result = await subAgent.executeSubToolCall(name: "execute_code", arguments: ["code": "return 1;"])
        XCTAssertTrue(result.isError)
    }
}
