import Foundation

/// Shared file mutation helpers used by the generic write/edit tools and the
/// dedicated PLAN.MD tool so they apply the same validation, write, and diff behavior.
enum FileMutationSupport {
    static func writeContent(
        _ content: String,
        to path: String,
        permissions: PermissionEngine,
        blockExistingFile: Bool = false
    ) -> ToolResult {
        let resolvedPath: String
        do {
            resolvedPath = try permissions.validatePath(path)
        } catch {
            return .error(error.localizedDescription)
        }

        if blockExistingFile, let blocked = writeGuardBlock(path: path, resolvedPath: resolvedPath) {
            return blocked
        }

        do {
            let parentDir = (resolvedPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: parentDir,
                withIntermediateDirectories: true
            )

            let canonicalParent = URL(filePath: parentDir).standardized.resolvingSymlinksInPath().path()
            let canonicalWorkspaceRoot = URL(filePath: permissions.workspaceRoot)
                .standardized
                .resolvingSymlinksInPath()
                .path()
            let parentInsideWorkspace = canonicalParent == canonicalWorkspaceRoot
                || canonicalParent.hasPrefix(canonicalWorkspaceRoot + "/")
            guard parentInsideWorkspace else {
                return .error("Security violation: Parent directory path validation failed")
            }

            try content.write(toFile: resolvedPath, atomically: true, encoding: .utf8)

            let lineCount = content.components(separatedBy: "\n").count
            return .success("Wrote \(lineCount) lines to \(path)")
        } catch {
            return .error("Failed to write file: \(error.localizedDescription)")
        }
    }

    static func editContent(
        in path: String,
        oldText: String,
        newText: String,
        permissions: PermissionEngine
    ) -> ToolResult {
        let resolvedPath: String
        do {
            resolvedPath = try permissions.validatePath(path)
        } catch {
            return .error(error.localizedDescription)
        }

        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            return .error("File not found: \(path)")
        }

        do {
            let originalContent = try String(contentsOfFile: resolvedPath, encoding: .utf8)
            let occurrences = originalContent.components(separatedBy: oldText).count - 1

            guard occurrences > 0 else {
                return .error("old_text not found in file. Make sure the text matches exactly, including whitespace.")
            }

            if occurrences > 1 {
                return .error("old_text found \(occurrences) times in file. It must be unique. Add more surrounding context to old_text to make it unique.")
            }

            let newContent = originalContent.replacingOccurrences(of: oldText, with: newText)
            try newContent.write(toFile: resolvedPath, atomically: true, encoding: .utf8)

            let diff = generateUnifiedDiff(original: originalContent, updated: newContent, path: path)
            return .success("Applied edit to \(path)\n\(diff)")
        } catch {
            return .error("Failed to edit file: \(error.localizedDescription)")
        }
    }

    /// Reads a file's full contents back. Returns a clear "not found" result
    /// (not an error a caller needs to special-case) rather than throwing,
    /// since "the plan doesn't exist yet" is an expected, common outcome for
    /// callers checking whether a plan has been written before delegating.
    static func readContent(from path: String, permissions: PermissionEngine) -> ToolResult {
        let resolvedPath: String
        do {
            resolvedPath = try permissions.validateReadPath(path)
        } catch {
            return .error(error.localizedDescription)
        }

        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            return .error("File not found: \(path)")
        }

        do {
            let content = try String(contentsOfFile: resolvedPath, encoding: .utf8)
            return .success(content)
        } catch {
            return .error("Failed to read file: \(error.localizedDescription)")
        }
    }

    /// Decides whether the `write_file` hard write-guard should reject a write
    /// to `resolvedPath`, returning the actionable-recipe error to surface to
    /// the model. Returns `nil` when the write may proceed — either because
    /// the target doesn't exist yet (a genuine create), or because the caller
    /// didn't opt into the guard at all (see `writeContent`'s
    /// `blockExistingFile` parameter, which `PlanFileTool` deliberately leaves
    /// `false` so it can keep overwriting the fixed PLAN.MD document).
    ///
    /// This is the single source of truth for the block decision + message so
    /// all three code paths that can land bytes on disk for `write_file` —
    /// `WriteFileTool` (via `writeContent` above), the large-payload streamed
    /// commit in `AgentLoop.handleStreamedToolCall`, and the truncated-write
    /// recovery in `AgentLoop.commitTruncatedStreamedWrite` — apply the exact
    /// same rule instead of three copies that could drift out of sync.
    ///
    /// The recipe deliberately does not just say "use edit_file instead":
    /// `edit_file` requires an exact, unique `old_text` the model doesn't have
    /// yet for a file it hasn't read, so the message spells out the two real
    /// next steps (read-then-edit_file, or append_file) with their exact
    /// argument names.
    static func writeGuardBlock(path: String, resolvedPath: String) -> ToolResult? {
        guard FileManager.default.fileExists(atPath: resolvedPath) else { return nil }
        return .error("""
            \(path) already exists. write_file only creates new files — it will not blanket-overwrite an existing one, because replacing the whole file destroys any unrelated content a small model didn't intend to touch. To change it instead:
            - Read \(path), then call edit_file with path: "\(path)", old_text: <the exact snippet to replace>, new_text: <its replacement> for a targeted change.
            - Or call append_file with path: "\(path)", content: <text to add> to add content at the end without touching the rest.
            """)
    }

    static func generateUnifiedDiff(original: String, updated: String, path: String) -> String {
        let origLines = original.components(separatedBy: "\n")
        let newLines = updated.components(separatedBy: "\n")

        var lo = 0
        while lo < origLines.count && lo < newLines.count && origLines[lo] == newLines[lo] {
            lo += 1
        }

        var origHi = origLines.count
        var newHi = newLines.count
        while origHi > lo && newHi > lo && origLines[origHi - 1] == newLines[newHi - 1] {
            origHi -= 1
            newHi -= 1
        }

        guard lo < origHi || lo < newHi else { return "(no changes)" }

        let ctx = 3
        let hunkStart = max(0, lo - ctx)
        let hunkOrigEnd = min(origLines.count, origHi + ctx)

        let leadingCtx = lo - hunkStart
        let deletedCount = origHi - lo
        let addedCount = newHi - lo
        let trailingCtx = hunkOrigEnd - origHi

        let totalOrig = leadingCtx + deletedCount + trailingCtx
        let totalNew = leadingCtx + addedCount + trailingCtx

        var hunk = "@@ -\(hunkStart + 1),\(totalOrig) +\(hunkStart + 1),\(totalNew) @@\n"

        for l in hunkStart..<lo { hunk += " \(origLines[l])\n" }
        for l in lo..<origHi { hunk += "-\(origLines[l])\n" }
        for l in lo..<newHi { hunk += "+\(newLines[l])\n" }
        for l in origHi..<hunkOrigEnd { hunk += " \(origLines[l])\n" }

        return "--- a/\(path)\n+++ b/\(path)\n\(hunk)"
    }
}
