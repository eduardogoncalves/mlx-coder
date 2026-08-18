// Tests/ToolSystemTests/ExecuteCodeToolTests.swift
// Exercises ExecuteCodeTool + CodeModeSandboxProcess end-to-end against the
// REAL CodeModeWorker binary (mock dispatcher only — no real AgentLoop),
// verifying the RPC/JS plumbing: return values, sub-call denial propagation,
// the recursion guard, the timeout, and the modified_files bridging line.

import XCTest
@testable import MLXCoder

final class ExecuteCodeToolTests: XCTestCase {
    override func setUp() {
        super.setUp()
        if ProcessInfo.processInfo.environment["MLXCODER_CODE_MODE_WORKER_PATH"] == nil,
           let path = ExecuteCodeToolTests.locateCodeModeWorkerBinary() {
            setenv("MLXCODER_CODE_MODE_WORKER_PATH", path, 1)
        }
    }

    /// Locates the just-built CodeModeWorker binary relative to this test
    /// file's own on-disk path (a compile-time constant), since at test-run
    /// time `CommandLine.arguments[0]` is the XCTest runner, not MLXCoder's
    /// own binary — the normal sibling-of-executable lookup can't find it.
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
            .appendingPathComponent("mlx-coder-execute-code-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeTool(
        workspace: URL,
        exposedTools: [ExecuteCodeTool.ExposedTool] = [],
        timeoutSeconds: Double = 15,
        dispatcher: @escaping @Sendable (String, [String: Any]) async -> ToolResult
    ) -> ExecuteCodeTool {
        ExecuteCodeTool(
            exposedTools: exposedTools,
            permissions: PermissionEngine(workspaceRoot: workspace.path),
            timeoutSeconds: timeoutSeconds,
            dispatcher: dispatcher
        )
    }

    func testReturnsScriptValueWithNoSubCalls() async throws {
        guard ExecuteCodeToolTests.locateCodeModeWorkerBinary() != nil else {
            throw XCTSkip("CodeModeWorker binary not built — run `swift build` first")
        }
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let tool = makeTool(workspace: workspace) { _, _ in .error("should not be called") }
        let result = try await tool.execute(arguments: ["code": "return 1 + 1;"])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("2"), "expected the script's return value in the result: \(result.content)")
    }

    func testDeniedSubCallSurfacesAsCatchableError() async throws {
        guard ExecuteCodeToolTests.locateCodeModeWorkerBinary() != nil else {
            throw XCTSkip("CodeModeWorker binary not built — run `swift build` first")
        }
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let exposed = [ExecuteCodeTool.ExposedTool(name: "read_file", description: "read a file", parameters: JSONSchema())]
        let tool = makeTool(workspace: workspace, exposedTools: exposed) { name, _ in
            XCTAssertEqual(name, "read_file")
            return .error("permission denied: outside workspace")
        }

        let code = """
        try {
            await tools.read_file({path: "../../etc/passwd"});
            return "should not reach here";
        } catch (e) {
            return { caught: e.message };
        }
        """
        let result = try await tool.execute(arguments: ["code": code])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("permission denied"), "denial message should reach the script's catch block: \(result.content)")
    }

    func testUncaughtSubCallDenialFailsTheWholeCall() async throws {
        guard ExecuteCodeToolTests.locateCodeModeWorkerBinary() != nil else {
            throw XCTSkip("CodeModeWorker binary not built — run `swift build` first")
        }
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let exposed = [ExecuteCodeTool.ExposedTool(name: "read_file", description: "read a file", parameters: JSONSchema())]
        let tool = makeTool(workspace: workspace, exposedTools: exposed) { _, _ in .error("permission denied") }

        let result = try await tool.execute(arguments: ["code": "await tools.read_file({path:\"x\"}); return \"unreached\";"])

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("permission denied"), "uncaught denial should fail execute_code with the denial message: \(result.content)")
    }

    func testExecuteCodeIsNeverInItsOwnExposedToolsList() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let exposed = [
            ExecuteCodeTool.ExposedTool(name: "read_file", description: "read a file", parameters: JSONSchema()),
            ExecuteCodeTool.ExposedTool(name: "execute_code", description: "must be filtered out", parameters: JSONSchema()),
        ]
        let tool = makeTool(workspace: workspace, exposedTools: exposed) { _, _ in .success("") }

        XCTAssertFalse(tool.description.contains("tools.execute_code("), "execute_code must never expose itself for recursive sandboxing")
        XCTAssertTrue(tool.description.contains("tools.read_file("))
    }

    func testMultipleSequentialSubCallsAllDispatch() async throws {
        guard ExecuteCodeToolTests.locateCodeModeWorkerBinary() != nil else {
            throw XCTSkip("CodeModeWorker binary not built — run `swift build` first")
        }
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let exposed = [ExecuteCodeTool.ExposedTool(name: "read_file", description: "read a file", parameters: JSONSchema())]
        let dispatchCount = ManagedCounter()
        let tool = makeTool(workspace: workspace, exposedTools: exposed) { _, args in
            await dispatchCount.increment()
            let path = (args["path"] as? String) ?? "?"
            return .success("content-of-\(path)")
        }

        let code = """
        const out = [];
        for (let i = 0; i < 3; i++) {
            out.push(await tools.read_file({path: "f" + i + ".txt"}));
        }
        return out;
        """
        let result = try await tool.execute(arguments: ["code": code])

        XCTAssertFalse(result.isError)
        let count = await dispatchCount.value
        XCTAssertEqual(count, 3)
        XCTAssertTrue(result.content.contains("content-of-f0.txt"))
        XCTAssertTrue(result.content.contains("content-of-f2.txt"))
    }

    func testModifiedFilesLineReportedForSuccessfulMutatingSubCall() async throws {
        guard ExecuteCodeToolTests.locateCodeModeWorkerBinary() != nil else {
            throw XCTSkip("CodeModeWorker binary not built — run `swift build` first")
        }
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let exposed = [ExecuteCodeTool.ExposedTool(name: "write_file", description: "write a file", parameters: JSONSchema())]
        let tool = makeTool(workspace: workspace, exposedTools: exposed) { _, _ in .success("wrote it") }

        let code = "await tools.write_file({path: \"out.txt\", content: \"hi\"}); return \"done\";"
        let result = try await tool.execute(arguments: ["code": code])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains(TaskTool.modifiedFilesLinePrefix + "out.txt"), "expected modified_files line: \(result.content)")
    }

    func testTimeoutKillsAHangingScript() async throws {
        guard ExecuteCodeToolTests.locateCodeModeWorkerBinary() != nil else {
            throw XCTSkip("CodeModeWorker binary not built — run `swift build` first")
        }
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let tool = makeTool(workspace: workspace, timeoutSeconds: 2) { _, _ in .error("unused") }
        let result = try await tool.execute(arguments: ["code": "while (true) {}"])

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.lowercased().contains("timeout") || result.content.lowercased().contains("timed out") || result.content.contains("exceeded"), "expected a timeout-shaped error: \(result.content)")
    }

    func testMissingCodeArgumentIsAnError() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let tool = makeTool(workspace: workspace) { _, _ in .success("") }
        let result = try await tool.execute(arguments: [:])
        XCTAssertTrue(result.isError)
    }

    // The worker's own launch is never Seatbelt-wrapped (see the doc
    // comment on CodeModeSandboxProcess.run for why — a linker-signed
    // worker binary launched under a Seatbelt profile that denies
    // `file-read*` on its own containing path fails to exec at all). This
    // test covers the sub-call side of sandboxing instead: a REAL,
    // Seatbelt-wrapped BashTool invoked from inside a script.
    func testRealSandboxedBashSubCallSucceeds() async throws {
        guard ExecuteCodeToolTests.locateCodeModeWorkerBinary() != nil else {
            throw XCTSkip("CodeModeWorker binary not built — run `swift build` first")
        }
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("fixtures"), withIntermediateDirectories: true)

        let permissions = PermissionEngine(workspaceRoot: workspace.path)
        let bashTool = BashTool(permissions: permissions, useSandbox: true)
        let exposed = [ExecuteCodeTool.ExposedTool(name: "bash", description: "run a shell command", parameters: JSONSchema())]

        let tool = ExecuteCodeTool(
            exposedTools: exposed,
            permissions: permissions,
            timeoutSeconds: 20,
            dispatcher: { name, args in
                XCTAssertEqual(name, "bash")
                return (try? await bashTool.execute(arguments: args)) ?? .error("bash threw")
            }
        )
        let result = try await tool.execute(arguments: ["code": "const out = await tools.bash({command: \"ls fixtures\", timeout: 10}); return out;"])
        XCTAssertFalse(result.isError, "real sandboxed bash sub-call failed: \(result.content)")
    }
}

/// Plain actor-based counter for tests that need to assert how many times a
/// mock dispatcher closure fired.
actor ManagedCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
