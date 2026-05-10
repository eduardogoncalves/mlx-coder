import Foundation

enum TUIGitTreeCommandIntent: Equatable {
    case openMenu
    case switchWorktree
    case deleteBranch
    case invalidOption(String)
}

enum TUIGitTreeCommandParser {
    static func resolve(input: String) -> TUIGitTreeCommandIntent? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })

        guard let command = parts.first?.lowercased(), command == "/gittree" else {
            return nil
        }

        guard parts.count > 1 else { return .openMenu }
        let requested = parts[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !requested.isEmpty else { return .openMenu }

        switch requested {
        case "switch", "worktree", "switch-worktree":
            return .switchWorktree
        case "delete", "delete-branch", "branch", "remove-branch":
            return .deleteBranch
        default:
            return .invalidOption(requested)
        }
    }

    static func menuItems() -> [(name: String, desc: String)] {
        [
            (name: "/gittree switch", desc: "Switch workspace to a git worktree"),
            (name: "/gittree delete-branch", desc: "Delete a local branch")
        ]
    }
}
