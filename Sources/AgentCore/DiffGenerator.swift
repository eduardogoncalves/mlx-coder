// Sources/AgentCore/DiffGenerator.swift
// Pure utility for generating and colorizing unified diffs.

import Foundation

/// Generates unified diffs between original and new file content.
/// Stateless — all methods are static and require no actor involvement.
struct DiffGenerator {

    /// Generate a unified diff between original and new content.
    static func generate(original: String?, new: String, path: String) -> String {
        guard let original = original else {
            // New file — show the first few lines
            let lines = new.components(separatedBy: .newlines)
            let preview = lines.prefix(20).joined(separator: "\n")
            let truncated = lines.count > 20 ? "\n... (\(lines.count - 20) more lines)" : ""
            let diff = "--- /dev/null\n+++ b/\(path)\n@@ -0,0 +1,\(lines.count) @@\n\(preview)\(truncated)"
            return colorize(diff)
        }

        let origLines = original.components(separatedBy: .newlines)
        let newLines = new.components(separatedBy: .newlines)

        // Simple unified diff implementation
        var diff = "--- a/\(path)\n+++ b/\(path)\n"
        var i = 0
        var j = 0
        var context: [String] = []
        var changes: [String] = []
        var origStart = 1
        var origCount = 0
        var newStart = 1
        var newCount = 0

        while i < origLines.count || j < newLines.count {
            if i < origLines.count && j < newLines.count && origLines[i] == newLines[j] {
                // Context line
                if !changes.isEmpty {
                    // Flush previous hunk
                    diff += buildHunk(origStart: origStart, origCount: origCount, newStart: newStart, newCount: newCount, changes: changes)
                    changes = []
                    origCount = 0
                    newCount = 0
                }
                context.append(origLines[i])
                if context.count > 3 {
                    context.removeFirst()
                    origStart = i + 2
                    newStart = j + 2
                }
                i += 1
                j += 1
            } else {
                // Change block: emit deletions before insertions to preserve
                // unified-diff ordering within each hunk.
                if context.isEmpty && changes.isEmpty {
                    origStart = max(1, i)
                    newStart = max(1, j)
                }

                var removed: [String] = []
                var added: [String] = []

                while i < origLines.count && j < newLines.count && origLines[i] != newLines[j] {
                    // Prefer a single-sided edit when the next line re-syncs.
                    if j + 1 < newLines.count && origLines[i] == newLines[j + 1] {
                        added.append(newLines[j])
                        j += 1
                    } else if i + 1 < origLines.count && origLines[i + 1] == newLines[j] {
                        removed.append(origLines[i])
                        i += 1
                    } else {
                        // Replacement: keep both but still output deletions first.
                        removed.append(origLines[i])
                        added.append(newLines[j])
                        i += 1
                        j += 1
                    }
                }

                if j >= newLines.count {
                    while i < origLines.count {
                        removed.append(origLines[i])
                        i += 1
                    }
                } else if i >= origLines.count {
                    while j < newLines.count {
                        added.append(newLines[j])
                        j += 1
                    }
                }

                for line in removed {
                    changes.append("-\(line)")
                    origCount += 1
                }
                for line in added {
                    changes.append("+\(line)")
                    newCount += 1
                }

                context = []
            }
        }

        if !changes.isEmpty {
            diff += buildHunk(origStart: origStart, origCount: origCount, newStart: newStart, newCount: newCount, changes: changes)
        }

        return diff.isEmpty ? "(no changes)" : colorize(diff)
    }

    static func buildHunk(origStart: Int, origCount: Int, newStart: Int, newCount: Int, changes: [String]) -> String {
        let origRange = origCount > 0 ? "\(origStart),\(origCount)" : "\(origStart),0"
        let newRange = newCount > 0 ? "\(newStart),\(newCount)" : "\(newStart),0"
        return "@@ -\(origRange) +\(newRange) @@\n" + changes.joined(separator: "\n") + "\n"
    }

    static func colorize(_ diff: String) -> String {
        let white = "\u{001B}[38;2;255;255;255m"
        let removedBackground = "\u{001B}[48;2;38;24;28m" // #26181c
        let addedBackground = "\u{001B}[48;2;20;38;29m" // #14261d
        let reset = "\u{001B}[0m"

        return diff
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { rawLine in
                let line = String(rawLine)
                if line.hasPrefix("--- ") || line.hasPrefix("+++ ") {
                    return line
                }
                if line.hasPrefix("-") {
                    return "\(white)\(removedBackground)\(line)\(reset)"
                }
                if line.hasPrefix("+") {
                    return "\(white)\(addedBackground)\(line)\(reset)"
                }
                return line
            }
            .joined(separator: "\n")
    }
}
