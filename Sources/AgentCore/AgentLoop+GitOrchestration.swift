// Sources/AgentCore/AgentLoop+GitOrchestration.swift
// Git orchestration flows — merge approval, worktree management, branch operations.

import Foundation

extension AgentLoop {

    public func runMergeApprovalShortcutFlow() async {
        do {
            let manager = try await ensureGitOrchestrationManager()
            try await presentMergeApprovalFlow(manager: manager)
        } catch {
            renderer.printStatus("⚠️  Could not run merge approval flow: \(error.localizedDescription)")
        }
    }

    public func runGitTreeShortcutFlow() async {
        do {
            let manager = try await ensureGitOrchestrationManager()
            let worktrees = try await manager.listAvailableWorktrees()
            guard !worktrees.isEmpty else {
                renderer.printStatus("No git worktrees found.")
                return
            }

            let currentDir = URL(filePath: FileManager.default.currentDirectoryPath).standardized.path()
            let options = worktrees.map { info in
                let normalizedPath = URL(filePath: info.path).standardized.path()
                let branch = info.branch ?? "detached HEAD"
                let marker = normalizedPath == currentDir ? " (current)" : ""
                return "\(branch) — \(normalizedPath)\(marker)"
            }

            guard let interactiveInput = self.interactiveInput else {
                renderer.printStatus("Git worktrees:")
                for option in options {
                    renderer.printStatus("  \(option)")
                }
                return
            }

            let actionOptions = ["Switch workspace to a worktree", "Delete local branch"]
            if let action = await interactiveInput.selectOption(
                prompt: "Git tree actions",
                options: actionOptions
            ) {
                if action == 1 {
                    try await runBranchDeleteFlow(manager: manager, interactiveInput: interactiveInput)
                    return
                }

                if let selected = await interactiveInput.selectOption(
                    prompt: "Select git worktree",
                    options: options
                ) {
                    let target = worktrees[selected]
                    let connected = try await manager.connectToExistingWorktree(path: target.path)
                    let normalizedPath = URL(filePath: connected.path).standardized.path()
                    await switchSessionWorkspace(to: normalizedPath, changeDirectory: true)
                    renderer.printStatus("📁 Switched workspace to: \(normalizedPath)")
                    renderer.printStatus("🌿 Active branch: \(connected.branch)")
                }
            }
        } catch {
            renderer.printStatus("⚠️  Could not open git worktree selector: \(error.localizedDescription)")
        }
    }

    func runBranchDeleteFlow(manager: GitOrchestrationManager, interactiveInput: InteractiveInput) async throws {
        let localBranches = try await manager.listLocalBranches()
        guard !localBranches.isEmpty else {
            renderer.printStatus("No local branches found.")
            return
        }

        let currentDir = URL(filePath: FileManager.default.currentDirectoryPath).standardized.path()
        let currentBranch = (try? await manager.getCurrentBranch(in: currentDir)) ?? ""
        let branchOptions = localBranches.map { branch in
            branch == currentBranch ? "\(branch) (current)" : branch
        }

        guard let selected = await interactiveInput.selectOption(
            prompt: "Select local branch to delete",
            options: branchOptions,
            escSelectsLastOption: true
        ) else {
            return
        }

        let targetBranch = localBranches[selected]
        let deleteOptions = ["Delete safely (-d)", "Force delete (-D)", "Cancel"]
        guard let deleteAction = await interactiveInput.selectOption(
            prompt: "Delete branch '\(targetBranch)'?",
            options: deleteOptions,
            escSelectsLastOption: true
        ) else {
            return
        }

        switch deleteAction {
        case 0:
            try await manager.deleteLocalBranch(targetBranch, force: false)
            renderer.printStatus("🗑️ Deleted branch: \(targetBranch)")
        case 1:
            try await manager.deleteLocalBranch(targetBranch, force: true)
            renderer.printStatus("🗑️ Force deleted branch: \(targetBranch)")
        default:
            renderer.printStatus("Branch deletion cancelled.")
        }
    }

    func ensureGitOrchestrationManager() async throws -> GitOrchestrationManager {
        if let manager = gitOrchestrationManager {
            return manager
        }
        let manager = try await GitOrchestrationManager.create(projectRoot: projectWorkspaceRoot)
        gitOrchestrationManager = manager
        return manager
    }

    func presentMergeApprovalFlow(manager: GitOrchestrationManager) async throws {
        var finalCommitMessage = "chore: finalize task changes"
        var skipFinalCommit = false
        if let interactiveInput = self.interactiveInput {
            let pendingDiff = (try? await manager.buildPendingCommitDiff()) ?? ""
            let suggestedFinalCommit = await generateCommitMessageSuggestion(
                diff: pendingDiff,
                fallback: finalCommitMessage,
                context: "final commit"
            )
            let finalChoice = await chooseEditableMessage(
                interactiveInput: interactiveInput,
                title: "Final commit message",
                suggested: suggestedFinalCommit,
                allowSkip: true
            )
            finalCommitMessage = finalChoice.message
            skipFinalCommit = finalChoice.skip
            if skipFinalCommit {
                renderer.printStatus("⏭️  Skipping final commit for now. Pending changes were kept.")
            }
        }

        let completionGuide = try await manager.onTaskComplete(
            finalCommitMessage: finalCommitMessage,
            autoFinalCommit: !skipFinalCommit
        )
        renderer.printStatus(completionGuide.formattedMessage)

        guard let interactiveInput = self.interactiveInput else { return }

        print("")
        let mergeOptions = [
            "Leave for later",
            "Merge now (squash)",
            "Merge now (merge commit)",
            "Merge now (rebase)"
        ]
        if let selected = await interactiveInput.selectOption(
            prompt: "Merge decision",
            options: mergeOptions
        ) {
            let outcome: MergeOutcome
            switch selected {
            case 1:
                let diffArtifacts = try? await manager.buildDiffReview()
                let suggestedSquashMessage = await generateCommitMessageSuggestion(
                    diff: diffArtifacts?.fullDiff ?? "",
                    fallback: "feat: merge \(completionGuide.branchName)",
                    context: "squash merge commit"
                )
                let squashChoice = await chooseEditableMessage(
                    interactiveInput: interactiveInput,
                    title: "Squash commit message",
                    suggested: suggestedSquashMessage
                )
                outcome = try await manager.finalizeAfterUserApproval(
                    mergeNow: true,
                    strategy: .squash,
                    cleanupWorktree: true,
                    squashCommitMessage: squashChoice.message
                )
            case 2:
                outcome = try await manager.finalizeAfterUserApproval(
                    mergeNow: true,
                    strategy: .mergeCommit,
                    cleanupWorktree: true,
                    squashCommitMessage: nil
                )
            case 3:
                outcome = try await manager.finalizeAfterUserApproval(
                    mergeNow: true,
                    strategy: .rebase,
                    cleanupWorktree: true,
                    squashCommitMessage: nil
                )
            default:
                outcome = try await manager.finalizeAfterUserApproval(
                    mergeNow: false,
                    strategy: .squash,
                    cleanupWorktree: false,
                    squashCommitMessage: nil
                )
            }
            renderer.printStatus("✅ \(outcome.message)")
            for warning in outcome.cleanupWarnings {
                renderer.printStatus("⚠️  Cleanup warning: \(warning)")
            }

            if outcome.merged && selected != 0 {
                await restoreWorkspaceToProjectRoot()
                do {
                    try await reloadModel()
                } catch {
                    renderer.printStatus("⚠️  Merge completed, but model reload failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func chooseEditableMessage(
        interactiveInput: InteractiveInput,
        title: String,
        suggested: String,
        allowSkip: Bool = false
    ) async -> (message: String, skip: Bool) {
        renderer.printStatus("📝 Proposed \(title.lowercased()): \(suggested)")
        let options = allowSkip
            ? ["Use this message", "No, suggest changes (esc)", "Skip commit for now"]
            : ["Use this message", "No, suggest changes (esc)"]
        if let selected = await interactiveInput.selectOption(
            prompt: "\(title) options",
            options: options,
            escSelectsLastOption: true
        ) {
            if allowSkip && selected == 2 {
                return (suggested, true)
            }
            if selected == 1 {
                let edited = await interactiveInput.promptForText(
                    prompt: "[\(title.lowercased())] Blocked. Suggest changes (or press Enter to keep suggested):",
                    placeholder: suggested,
                    validate: { message in
                        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty {
                            throw NSError(
                                domain: "AgentLoop",
                                code: 3,
                                userInfo: [NSLocalizedDescriptionKey: "\(title) cannot be empty"]
                            )
                        }
                        return true
                    }
                ) ?? suggested
                return (edited, false)
            }
        }
        return (suggested, false)
    }

    func restoreWorkspaceToProjectRoot() async {
        let normalizedPath = URL(filePath: projectWorkspaceRoot).standardized.path()
        await switchSessionWorkspace(to: normalizedPath, changeDirectory: true)
        renderer.printStatus("📁 Restored workspace to project root: \(normalizedPath)")
    }

    func switchSessionWorkspace(to path: String, changeDirectory: Bool) async {
        let normalizedPath = URL(filePath: path).standardized.path()
        permissions = PermissionEngine(
            workspaceRoot: normalizedPath,
            allowedCommands: permissions.allowedCommands,
            deniedCommands: permissions.deniedCommands,
            approvalMode: permissions.approvalMode,
            policy: permissions.policy,
            ignoredPathPatterns: permissions.ignoredPathPatterns
        )
        await registerToolsInternal()
        if changeDirectory, !FileManager.default.changeCurrentDirectoryPath(normalizedPath) {
            renderer.printStatus("⚠️  Failed to switch current directory to: \(normalizedPath)")
        }
    }

    func generateCommitMessageSuggestion(diff: String, fallback: String, context: String) async -> String {
        let trimmedDiff = diff.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDiff.isEmpty else { return fallback }
        _ = context
        // Deliberately avoid secondary model inference here because this path has shown
        // runtime instability on some checkpoints after tool execution.
        return heuristicCommitMessage(from: trimmedDiff, fallback: fallback)
    }

    func heuristicCommitMessage(from diff: String, fallback: String) -> String {
        let lower = diff.lowercased()
        if lower.contains("test") || lower.contains("spec") || lower.contains("xctest") {
            return "test: update coverage"
        }
        if lower.contains("readme") || lower.contains("/docs/") || lower.contains("changelog") {
            return "docs: update documentation"
        }
        if lower.contains("fix") || lower.contains("error") || lower.contains("fatal") {
            return "fix: harden merge approval flow"
        }
        return fallback
    }
}
