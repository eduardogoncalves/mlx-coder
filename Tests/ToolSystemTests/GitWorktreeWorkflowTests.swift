import XCTest
@testable import MLXCoder

final class GitWorktreeWorkflowTests: XCTestCase {
    func testBranchNamerGeneratesFixPrefixWithoutTimestamp() throws {
        let info = try BranchNamer.parse(userMessage: "fix bug in auth middleware")

        XCTAssertTrue(info.branchName.hasPrefix("fix/"))
        XCTAssertTrue(BranchNamer.isValidBranchName(info.branchName))
        XCTAssertFalse(info.branchName.contains("/20"))
    }

    func testBranchNamerStillAcceptsLegacyFormat() {
        XCTAssertTrue(BranchNamer.isValidBranchName("hotfix/20260413-auth-token-expiry"))
    }

    func testBranchNamerGeneratesUsefulSlugFromLongPrompt() throws {
        let message = """
        vamos melhorar o workflow com git worktree, implementando as etapas que faltam:
        criar merge na main, revisão de diff e limpeza do worktree após aprovação
        """
        let info = try BranchNamer.parse(userMessage: message)

        XCTAssertEqual(info.type, .feature)
        XCTAssertTrue(info.branchName.hasPrefix("feature/"))
        XCTAssertTrue(info.branchName.contains("worktree"))
        XCTAssertTrue(info.branchName.contains("merge"))
        XCTAssertFalse(info.branchName.contains("vamos"))
        XCTAssertFalse(info.branchName.contains("etapas"))
    }

    func testBranchNamerIgnoresCodeBlockNoise() throws {
        let message = """
        fix: corrigir merge quebrado no fluxo de worktree
        ```bash
        git checkout main
        git pull origin main
        ```
        """
        let info = try BranchNamer.parse(userMessage: message)

        XCTAssertEqual(info.type, .fix)
        XCTAssertTrue(info.branchName.hasPrefix("fix/"))
        XCTAssertFalse(info.branchName.contains("checkout"))
        XCTAssertFalse(info.branchName.contains("origin"))
        XCTAssertTrue(info.branchName.contains("merge") || info.branchName.contains("worktree"))
    }

    func testCommitUsesWorktreeDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-worktree-workflow-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try runGit(["init"], cwd: tempDir.path)
        try runGit(["config", "user.email", "tests@mlx-coder.local"], cwd: tempDir.path)
        try runGit(["config", "user.name", "MLX Coder Tests"], cwd: tempDir.path)

        let file = tempDir.appendingPathComponent("README.md")
        try "base\n".write(to: file, atomically: true, encoding: .utf8)
        try runGit(["add", "."], cwd: tempDir.path)
        try runGit(["commit", "-m", "chore: initial commit"], cwd: tempDir.path)
        try runGit(["branch", "-M", "main"], cwd: tempDir.path)

        let service = try GitService(projectRoot: tempDir.path)
        let worktreePath = try await service.createWorktree(
            branchName: "feature/worktree-commit-test",
            fromBranch: "main"
        )

        let worktreeFile = URL(fileURLWithPath: worktreePath).appendingPathComponent("README.md")
        try "base\nchange-in-worktree\n".write(to: worktreeFile, atomically: true, encoding: .utf8)

        _ = try await service.commit(message: "feat: update from worktree", in: worktreePath)
        let commits = try await service.getCommitsSince(baseBranch: "main", in: worktreePath)

        XCTAssertEqual(commits.count, 1)
        XCTAssertTrue(commits[0].contains("feat: update from worktree"))
    }

    func testOnTaskCompleteCreatesCommitBeforeApprovalPromptWhenNeeded() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-worktree-orchestration-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try runGit(["init"], cwd: tempDir.path)
        try runGit(["config", "user.email", "tests@mlx-coder.local"], cwd: tempDir.path)
        try runGit(["config", "user.name", "MLX Coder Tests"], cwd: tempDir.path)

        let file = tempDir.appendingPathComponent("README.md")
        try "base\n".write(to: file, atomically: true, encoding: .utf8)
        try runGit(["add", "."], cwd: tempDir.path)
        try runGit(["commit", "-m", "chore: initial commit"], cwd: tempDir.path)
        try runGit(["branch", "-M", "main"], cwd: tempDir.path)

        let manager = try await GitOrchestrationManager.create(projectRoot: tempDir.path)
        _ = try await manager.prepareTask(userMessage: "implement merge approval flow", shouldPromptForBaseBranch: false)
        try await manager.createWorktreeNow()

        guard let worktreePath = await manager.getWorktreePath() else {
            XCTFail("Expected worktree path to be initialized")
            return
        }

        let worktreeFile = URL(fileURLWithPath: worktreePath).appendingPathComponent("README.md")
        try "base\npending-change\n".write(to: worktreeFile, atomically: true, encoding: .utf8)

        let guide = try await manager.onTaskComplete()

        XCTAssertEqual(guide.commits.count, 1)
        XCTAssertTrue(guide.commits[0].contains("Final changes"))
        XCTAssertTrue(guide.approvalPromptMessage.contains("Commits created: 1"))
    }

    private func runGit(_ arguments: [String], cwd: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown"
            throw NSError(domain: "GitWorktreeWorkflowTests", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(error)"
            ])
        }
    }
}
