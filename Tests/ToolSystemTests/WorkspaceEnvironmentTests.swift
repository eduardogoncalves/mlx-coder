import XCTest
@testable import MLXCoder

final class WorkspaceEnvironmentTests: XCTestCase {
    func testParsesDotenvFormat() {
        let parsed = WorkspaceEnvironment.parse("""
        # project env
        DOTNET_CLI_HOME=.dotnet
        export NUGET_PACKAGES="packages/nuget"
        QUOTED='single quoted value'
        SPACED = trimmed
        EMPTY=

        not a key value line
        1INVALID=skipped
        IN-VALID=skipped
        """)

        XCTAssertEqual(parsed["DOTNET_CLI_HOME"], ".dotnet")
        XCTAssertEqual(parsed["NUGET_PACKAGES"], "packages/nuget")
        XCTAssertEqual(parsed["QUOTED"], "single quoted value")
        XCTAssertEqual(parsed["SPACED"], "trimmed")
        XCTAssertEqual(parsed["EMPTY"], "")
        XCTAssertNil(parsed["1INVALID"])
        XCTAssertNil(parsed["IN-VALID"])
        XCTAssertEqual(parsed.count, 5)
    }

    func testSanitizationBlocksLoaderAndShellVariables() {
        let sanitized = WorkspaceEnvironment.sanitized([
            "DOTNET_CLI_HOME": ".dotnet",
            "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib",
            "LD_PRELOAD": "/tmp/evil.so",
            "IFS": ";",
            "BASH_ENV": "/tmp/evil.sh",
            "ZDOTDIR": "/tmp",
            "PROMPT_COMMAND": "curl evil",
        ])

        XCTAssertEqual(sanitized, ["DOTNET_CLI_HOME": ".dotnet"])
    }

    func testMergeAppendsPathInsteadOfReplacing() {
        let merged = WorkspaceEnvironment.merge(
            into: ["PATH": "/usr/bin:/bin", "HOME": "/Users/example"],
            workspace: ["PATH": "/Users/example/.dotnet/tools", "DOTNET_CLI_HOME": ".dotnet"]
        )

        XCTAssertEqual(merged["PATH"], "/usr/bin:/bin:/Users/example/.dotnet/tools")
        XCTAssertEqual(merged["DOTNET_CLI_HOME"], ".dotnet")
        XCTAssertEqual(merged["HOME"], "/Users/example")
    }

    func testLoadReturnsEmptyWhenFileMissing() {
        XCTAssertTrue(WorkspaceEnvironment.load(workspaceRoot: "/nonexistent-\(UUID().uuidString)").isEmpty)
    }

    func testLoadReadsAndSanitizesWorkspaceFile() throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try """
        DOTNET_CLI_HOME=.dotnet
        DYLD_INSERT_LIBRARIES=/tmp/evil.dylib
        """.write(to: workspace.appendingPathComponent(WorkspaceEnvironment.fileName), atomically: true, encoding: .utf8)

        let env = WorkspaceEnvironment.load(workspaceRoot: workspace.path)
        XCTAssertEqual(env, ["DOTNET_CLI_HOME": ".dotnet"])
    }

    func testBashToolInjectsWorkspaceEnvIntoCommands() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try """
        MLX_CODER_TEST_VAR=from-workspace-env
        """.write(to: workspace.appendingPathComponent(WorkspaceEnvironment.fileName), atomically: true, encoding: .utf8)

        let permissions = PermissionEngine(workspaceRoot: workspace.path)
        let tool = BashTool(permissions: permissions)

        let result = try await tool.execute(arguments: ["command": "echo value=$MLX_CODER_TEST_VAR"])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("value=from-workspace-env"))
    }

    func testSandboxedBashDefaultsDotnetCliHomeToWorkspace() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let permissions = PermissionEngine(workspaceRoot: workspace.path)
        let tool = BashTool(permissions: permissions, useSandbox: true)

        let result = try await tool.execute(arguments: ["command": "echo cli_home=$DOTNET_CLI_HOME"])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(
            result.content.contains("cli_home=\(permissions.effectiveWorkspaceRoot)/.dotnet"),
            "expected workspace-local DOTNET_CLI_HOME, got: \(result.content)"
        )
    }

    func testWorkspaceEnvOverridesSandboxDotnetCliHomeDefault() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try """
        DOTNET_CLI_HOME=/tmp/custom-dotnet-home
        """.write(to: workspace.appendingPathComponent(WorkspaceEnvironment.fileName), atomically: true, encoding: .utf8)

        let permissions = PermissionEngine(workspaceRoot: workspace.path)
        let tool = BashTool(permissions: permissions, useSandbox: true)

        let result = try await tool.execute(arguments: ["command": "echo cli_home=$DOTNET_CLI_HOME"])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("cli_home=/tmp/custom-dotnet-home"))
    }

    private func makeTempWorkspace() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mlx-coder-workspace-env-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
