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

    // MARK: - Hard write-guard: write_file must refuse to overwrite an
    // existing file and steer the model toward a targeted edit instead.

    func testWriteFileToNewFileStillSucceeds() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let permissions = PermissionEngine(workspaceRoot: workspace.path)
        let tool = WriteFileTool(permissions: permissions)

        let result = try await tool.execute(arguments: [
            "path": "new-file.txt",
            "content": "brand new content\n"
        ])

        XCTAssertFalse(result.isError)
        let written = workspace.appendingPathComponent("new-file.txt")
        XCTAssertEqual(try String(contentsOf: written, encoding: .utf8), "brand new content\n")
    }

    func testWriteFileToExistingFileIsBlockedWithActionableRecipe() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let existing = workspace.appendingPathComponent("existing.txt")
        try "original content\n".write(to: existing, atomically: true, encoding: .utf8)

        let permissions = PermissionEngine(workspaceRoot: workspace.path)
        let tool = WriteFileTool(permissions: permissions)

        let result = try await tool.execute(arguments: [
            "path": "existing.txt",
            "content": "clobbered!\n"
        ])

        XCTAssertTrue(result.isError)
        // The recipe must name the exact tools/arguments the model needs to
        // retry successfully — not just "use edit_file instead", since
        // edit_file additionally needs an old_text the model doesn't have yet.
        XCTAssertTrue(result.content.contains("edit_file"))
        XCTAssertTrue(result.content.contains("old_text"))
        XCTAssertTrue(result.content.contains("new_text"))
        XCTAssertTrue(result.content.contains("append_file"))
        XCTAssertTrue(result.content.contains("content"))

        // The guard must have actually refused the write — original content preserved.
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "original content\n")
    }

    // MARK: - PlanFileTool exemption: PLAN.MD legitimately gets rewritten
    // repeatedly via the same `writeContent` helper and must not be blocked.

    func testPlanFileWriteToExistingPlanFileStillSucceeds() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let permissions = PermissionEngine(workspaceRoot: workspace.path)
        let plan = PlanFileTool(permissions: permissions)

        let first = try await plan.execute(arguments: ["action": "write", "content": "# Plan v1\n"])
        XCTAssertFalse(first.isError)

        // PLAN.MD now exists; a second 'write' must still succeed (unlike
        // write_file, which would refuse this exact scenario).
        let second = try await plan.execute(arguments: ["action": "write", "content": "# Plan v2\n"])
        XCTAssertFalse(second.isError)

        let planFile = workspace.appendingPathComponent("PLAN.MD")
        XCTAssertEqual(try String(contentsOf: planFile, encoding: .utf8), "# Plan v2\n")
    }

    // MARK: - Bash redirect guard: `cmd > existing_file` bypasses the tool
    // layer entirely, so it needs its own guard (RedirectOverwriteGuard),
    // wired into BashTool ahead of execution.

    func testBashRedirectGuardBlocksTruncatingOverwriteOfExistingFile() {
        let workspaceRoot = "/tmp/mlx-coder-redirect-guard-test"
        let existing = workspaceRoot + "/existing.txt"
        try? FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)
        try? "keep me".write(toFile: existing, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: workspaceRoot) }

        let blocked = RedirectOverwriteGuard.checkTruncatingRedirect(
            "echo hello > existing.txt",
            workspaceRoot: workspaceRoot
        )
        XCTAssertNotNil(blocked)
        XCTAssertTrue(blocked?.contains("edit_file") == true)
        XCTAssertTrue(blocked?.contains("append_file") == true)
    }

    func testBashRedirectGuardDoesNotBlockNewFileTarget() {
        let workspaceRoot = "/tmp/mlx-coder-redirect-guard-test-new"
        try? FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: workspaceRoot) }

        let blocked = RedirectOverwriteGuard.checkTruncatingRedirect(
            "echo hello > brand-new-file.txt",
            workspaceRoot: workspaceRoot
        )
        XCTAssertNil(blocked)
    }

    func testBashRedirectGuardDoesNotBlockAppendToExistingFile() {
        let workspaceRoot = "/tmp/mlx-coder-redirect-guard-test-append"
        let existing = workspaceRoot + "/existing.txt"
        try? FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)
        try? "keep me".write(toFile: existing, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: workspaceRoot) }

        // `>>` is append — deliberately never blocked, even to an existing file.
        let blocked = RedirectOverwriteGuard.checkTruncatingRedirect(
            "echo hello >> existing.txt",
            workspaceRoot: workspaceRoot
        )
        XCTAssertNil(blocked)
    }

    func testBashRedirectGuardFalsePositiveGuardForFdDuplication() {
        let workspaceRoot = "/tmp/mlx-coder-redirect-guard-test-fd"
        let existing = workspaceRoot + "/existing.txt"
        try? FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)
        try? "keep me".write(toFile: existing, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: workspaceRoot) }

        // `2>&1` duplicates stderr onto stdout's fd — no file is written at
        // all, so this must never be mistaken for a truncating redirect.
        let blocked = RedirectOverwriteGuard.checkTruncatingRedirect(
            "some_command existing.txt 2>&1",
            workspaceRoot: workspaceRoot
        )
        XCTAssertNil(blocked)
    }

    func testBashRedirectGuardIgnoresRedirectInsideQuotes() {
        let workspaceRoot = "/tmp/mlx-coder-redirect-guard-test-quote"
        let existing = workspaceRoot + "/existing.txt"
        try? FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)
        try? "keep me".write(toFile: existing, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: workspaceRoot) }

        // The `>` here is just text inside a quoted string, not a redirect —
        // no file named "existing.txt" is written to.
        let blocked = RedirectOverwriteGuard.checkTruncatingRedirect(
            "echo \"value > existing.txt\"",
            workspaceRoot: workspaceRoot
        )
        XCTAssertNil(blocked)
    }

    func testBashRedirectGuardBlocksHeredocOverwriteOfExistingFile() {
        // `cat > file <<'EOF' ... EOF` is the standard shell idiom small
        // models reach for to write whole-file content — the primary bypass
        // this guard exists to close.
        let workspaceRoot = "/tmp/mlx-coder-redirect-guard-test-heredoc"
        let existing = workspaceRoot + "/existing.txt"
        try? FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)
        try? "keep me".write(toFile: existing, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: workspaceRoot) }

        let command = "cat > existing.txt <<'EOF'\nsome new content with a > inside\nEOF"
        let blocked = RedirectOverwriteGuard.checkTruncatingRedirect(command, workspaceRoot: workspaceRoot)
        XCTAssertNotNil(blocked)
    }

    func testBashRedirectGuardIgnoresLiteralGreaterThanInsideHeredocBody() {
        let workspaceRoot = "/tmp/mlx-coder-redirect-guard-test-heredoc-body"
        let existing = workspaceRoot + "/existing.txt"
        try? FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)
        try? "keep me".write(toFile: existing, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: workspaceRoot) }

        // No redirect targets existing.txt at all here — the `>` only
        // appears as plain text inside the heredoc body, which must not be
        // mistaken for a redirect operator.
        let command = "cat <<'EOF'\nexisting.txt > should not trigger\nEOF"
        let blocked = RedirectOverwriteGuard.checkTruncatingRedirect(command, workspaceRoot: workspaceRoot)
        XCTAssertNil(blocked)
    }

    // MARK: - `tee` / `dd`: the other two write kinds that bypass write_file
    // and a bare `>` redirect alike.

    func testBashRedirectGuardBlocksTeeOverwriteOfExistingFile() {
        let workspaceRoot = "/tmp/mlx-coder-redirect-guard-test-tee"
        let existing = workspaceRoot + "/existing.txt"
        try? FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)
        try? "keep me".write(toFile: existing, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: workspaceRoot) }

        let blocked = RedirectOverwriteGuard.checkTruncatingRedirect(
            "echo hello | tee existing.txt",
            workspaceRoot: workspaceRoot
        )
        XCTAssertNotNil(blocked)
        XCTAssertTrue(blocked?.contains("tee") == true)
    }

    func testBashRedirectGuardDoesNotBlockTeeAppendToExistingFile() {
        let workspaceRoot = "/tmp/mlx-coder-redirect-guard-test-tee-append"
        let existing = workspaceRoot + "/existing.txt"
        try? FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)
        try? "keep me".write(toFile: existing, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: workspaceRoot) }

        // `tee -a` is an append, same rule as `>>` — must never be blocked.
        let blocked = RedirectOverwriteGuard.checkTruncatingRedirect(
            "echo hello | tee -a existing.txt",
            workspaceRoot: workspaceRoot
        )
        XCTAssertNil(blocked)
    }

    func testBashRedirectGuardBlocksDdOfOverwriteOfExistingFile() {
        let workspaceRoot = "/tmp/mlx-coder-redirect-guard-test-dd-of"
        let existing = workspaceRoot + "/existing.img"
        try? FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)
        try? "keep me".write(toFile: existing, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: workspaceRoot) }

        let blocked = RedirectOverwriteGuard.checkTruncatingRedirect(
            "dd if=/dev/zero of=existing.img bs=1M count=1",
            workspaceRoot: workspaceRoot
        )
        XCTAssertNotNil(blocked)
        XCTAssertTrue(blocked?.contains("dd") == true)
    }

    func testBashRedirectGuardDoesNotBlockDdIfOfExistingFile() {
        // `if=` is the *input* file — reading an existing file with dd must
        // never be confused with writing to it.
        let workspaceRoot = "/tmp/mlx-coder-redirect-guard-test-dd-if"
        let existing = workspaceRoot + "/existing.img"
        try? FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)
        try? "keep me".write(toFile: existing, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: workspaceRoot) }

        let blocked = RedirectOverwriteGuard.checkTruncatingRedirect(
            "dd if=existing.img of=new-copy.img bs=1M",
            workspaceRoot: workspaceRoot
        )
        XCTAssertNil(blocked)
    }

    // MARK: - Command chains: a truncating write must be caught no matter
    // what chain operator precedes it.

    func testBashRedirectGuardBlocksTruncatingRedirectAfterAndAndChain() {
        let workspaceRoot = "/tmp/mlx-coder-redirect-guard-test-chain-and"
        let existing = workspaceRoot + "/existing.swift"
        try? FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)
        try? "keep me".write(toFile: existing, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: workspaceRoot) }

        let blocked = RedirectOverwriteGuard.checkTruncatingRedirect(
            "echo hi && cat > existing.swift",
            workspaceRoot: workspaceRoot
        )
        XCTAssertNotNil(blocked)
    }

    func testBashRedirectGuardBlocksTeeAfterPipeChain() {
        let workspaceRoot = "/tmp/mlx-coder-redirect-guard-test-chain-pipe"
        let existing = workspaceRoot + "/existing.swift"
        try? FileManager.default.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)
        try? "keep me".write(toFile: existing, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: workspaceRoot) }

        let blocked = RedirectOverwriteGuard.checkTruncatingRedirect(
            "make | tee existing.swift",
            workspaceRoot: workspaceRoot
        )
        XCTAssertNotNil(blocked)
    }

    func testBashToolEndToEndBlocksTruncatingRedirectToExistingFile() async throws {
        let workspace = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let existing = workspace.appendingPathComponent("existing.txt")
        try "keep me".write(to: existing, atomically: true, encoding: .utf8)

        let permissions = PermissionEngine(workspaceRoot: workspace.path)
        let bash = BashTool(permissions: permissions)

        let result = try await bash.execute(arguments: ["command": "echo clobbered > existing.txt"])

        XCTAssertTrue(result.isError)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep me")
    }

    private func makeTempWorkspace() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mlx-coder-write-file-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
