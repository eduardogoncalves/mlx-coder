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

    func testConnectToExistingWorktreeRestoresBranchAndPath() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-worktree-resume-tests-\(UUID().uuidString)", isDirectory: true)
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
        let branchName = "feature/resume-session"
        let worktreePath = try await service.createWorktree(branchName: branchName, fromBranch: "main")

        let manager = try await GitOrchestrationManager.create(projectRoot: tempDir.path)
        let worktrees = try await manager.listAvailableWorktrees()
        XCTAssertTrue(worktrees.contains(where: { URL(filePath: $0.path).lastPathComponent == URL(filePath: worktreePath).lastPathComponent }))

        let connected = try await manager.connectToExistingWorktree(path: worktreePath)
        let currentBranch = await manager.getCurrentBranchName()
        let currentWorktree = await manager.getWorktreePath()
        XCTAssertEqual(connected.branch, branchName)
        XCTAssertEqual(currentBranch, branchName)
        XCTAssertEqual(currentWorktree, worktreePath)
    }

    func testMergeSquashWorksWhenServiceIsInitializedFromFeatureWorktree() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-worktree-merge-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try runGit(["init"], cwd: tempDir.path)
        try runGit(["config", "user.email", "tests@mlx-coder.local"], cwd: tempDir.path)
        try runGit(["config", "user.name", "MLX Coder Tests"], cwd: tempDir.path)

        let rootFile = tempDir.appendingPathComponent("README.md")
        try "base\n".write(to: rootFile, atomically: true, encoding: .utf8)
        try runGit(["add", "."], cwd: tempDir.path)
        try runGit(["commit", "-m", "chore: initial commit"], cwd: tempDir.path)
        try runGit(["branch", "-M", "main"], cwd: tempDir.path)

        let rootService = try GitService(projectRoot: tempDir.path)
        let featureBranch = "feature/header-font"
        let worktreePath = try await rootService.createWorktree(branchName: featureBranch, fromBranch: "main")

        let featureFile = URL(fileURLWithPath: worktreePath).appendingPathComponent("README.md")
        try "base\nheader-font-change\n".write(to: featureFile, atomically: true, encoding: .utf8)

        let featureService = try GitService(projectRoot: worktreePath)
        _ = try await featureService.commit(message: "feat: header font update", in: worktreePath)
        _ = try await featureService.mergeSquash(
            baseBranch: "main",
            sourceBranch: featureBranch,
            commitMessage: "feat: merge header font"
        )

        let mainContent = try String(contentsOf: rootFile, encoding: .utf8)
        XCTAssertTrue(mainContent.contains("header-font-change"))
    }

    func testDeleteBranchAfterSquashRequiresForceDelete() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-worktree-delete-after-squash-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try runGit(["init"], cwd: tempDir.path)
        try runGit(["config", "user.email", "tests@mlx-coder.local"], cwd: tempDir.path)
        try runGit(["config", "user.name", "MLX Coder Tests"], cwd: tempDir.path)

        let rootFile = tempDir.appendingPathComponent("README.md")
        try "base\n".write(to: rootFile, atomically: true, encoding: .utf8)
        try runGit(["add", "."], cwd: tempDir.path)
        try runGit(["commit", "-m", "chore: initial commit"], cwd: tempDir.path)
        try runGit(["branch", "-M", "main"], cwd: tempDir.path)

        let rootService = try GitService(projectRoot: tempDir.path)
        let featureBranch = "feature/squash-delete"
        let worktreePath = try await rootService.createWorktree(branchName: featureBranch, fromBranch: "main")
        let featureService = try GitService(projectRoot: worktreePath)

        let featureFile = URL(fileURLWithPath: worktreePath).appendingPathComponent("README.md")
        try "base\nsquashed-change\n".write(to: featureFile, atomically: true, encoding: .utf8)
        _ = try await featureService.commit(message: "feat: squash me", in: worktreePath)
        _ = try await featureService.mergeSquash(
            baseBranch: "main",
            sourceBranch: featureBranch,
            commitMessage: "feat: squashed merge"
        )
        try await rootService.removeWorktree(path: worktreePath)

        do {
            try await rootService.deleteBranch(featureBranch)
            XCTFail("Expected non-forced branch deletion to fail after squash merge")
        } catch let error as GitError {
            guard case .cleanupFailed(let reason) = error else {
                XCTFail("Expected cleanupFailed, got \(error)")
                return
            }
            XCTAssertTrue(reason.contains("not fully merged") || reason.contains("is not fully merged"))
        }

        try await rootService.deleteBranch(featureBranch, force: true)
        let branches = try await rootService.listBranches()
        XCTAssertFalse(branches.contains(featureBranch))
    }

    func testFinalizeAfterApprovalReportsCleanupWarningsWithoutMaskingMergeSuccess() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-worktree-merge-cleanup-warning-tests-\(UUID().uuidString)", isDirectory: true)
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
        _ = try await manager.prepareTask(userMessage: "add cleanup warning coverage", shouldPromptForBaseBranch: false)
        try await manager.createWorktreeNow()

        guard let worktreePath = await manager.getWorktreePath() else {
            XCTFail("Expected worktree path")
            return
        }

        let worktreeFile = URL(fileURLWithPath: worktreePath).appendingPathComponent("README.md")
        try "base\ncleanup-warning-change\n".write(to: worktreeFile, atomically: true, encoding: .utf8)
        _ = try await manager.onTaskComplete()

        // Force cleanup partial failure after a successful merge by removing worktree early.
        try runGit(["worktree", "remove", worktreePath], cwd: tempDir.path)

        let outcome = try await manager.finalizeAfterUserApproval(
            mergeNow: true,
            strategy: .squash,
            cleanupWorktree: true
        )

        XCTAssertTrue(outcome.merged)
        XCTAssertFalse(outcome.cleanedUp)
        XCTAssertFalse(outcome.cleanupWarnings.isEmpty)
        XCTAssertTrue(outcome.message.contains("cleanup had issues"))

        let contentOnMain = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(contentOnMain.contains("cleanup-warning-change"))
    }

    func testOnTaskCompleteUsesProvidedFinalCommitMessage() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-worktree-custom-final-message-tests-\(UUID().uuidString)", isDirectory: true)
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
        _ = try await manager.prepareTask(userMessage: "custom final commit message", shouldPromptForBaseBranch: false)
        try await manager.createWorktreeNow()

        guard let worktreePath = await manager.getWorktreePath() else {
            XCTFail("Expected worktree path")
            return
        }

        let worktreeFile = URL(fileURLWithPath: worktreePath).appendingPathComponent("README.md")
        try "base\ncustom-final-message\n".write(to: worktreeFile, atomically: true, encoding: .utf8)

        let customMessage = "feat: add custom final commit message"
        let guide = try await manager.onTaskComplete(finalCommitMessage: customMessage)
        XCTAssertTrue(guide.commits.contains(where: { $0.contains(customMessage) }))
    }

    func testFinalizeAfterApprovalUsesProvidedSquashCommitMessage() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-worktree-custom-squash-message-tests-\(UUID().uuidString)", isDirectory: true)
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
        _ = try await manager.prepareTask(userMessage: "custom squash commit message", shouldPromptForBaseBranch: false)
        try await manager.createWorktreeNow()

        guard let worktreePath = await manager.getWorktreePath() else {
            XCTFail("Expected worktree path")
            return
        }

        let worktreeFile = URL(fileURLWithPath: worktreePath).appendingPathComponent("README.md")
        try "base\ncustom-squash-message\n".write(to: worktreeFile, atomically: true, encoding: .utf8)
        _ = try await manager.onTaskComplete(finalCommitMessage: "feat: prep squash merge")

        let squashMessage = "feat: use custom squash message"
        _ = try await manager.finalizeAfterUserApproval(
            mergeNow: true,
            strategy: .squash,
            cleanupWorktree: false,
            squashCommitMessage: squashMessage
        )

        let latestMessage = try runGitCapture(["log", "-1", "--pretty=%s"], cwd: tempDir.path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(latestMessage, squashMessage)
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

    private func runGitCapture(_ arguments: [String], cwd: String) throws -> String {
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

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown"
            throw NSError(domain: "GitWorktreeWorkflowTests", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(error)"
            ])
        }
        return output
    }
}
