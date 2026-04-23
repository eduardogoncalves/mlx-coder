// Sources/ToolSystem/Filesystem/EditFileTool.swift
// Targeted search-and-replace edits within files

import Foundation

/// Performs targeted search-and-replace edits on a file.
public struct EditFileTool: Tool {
    public let name = "edit_file"
    public let description = """
        Replace one unique occurrence of a string within an existing file. \
        Use this for a single, targeted in-place substitution where old_text appears exactly once. \
        Do NOT use when the same string appears more than once (make old_text longer/more unique instead), \
        when changes span multiple non-adjacent locations (use patch instead), \
        or when adding content at the end of the file (use append_file instead).
        """
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "path": PropertySchema(type: "string", description: "Path to the file to edit (relative to workspace root). The file must already exist."),
            "old_text": PropertySchema(type: "string", description: "Exact text to find and replace. Must match exactly one location in the file, including all whitespace and indentation. Add surrounding context lines to make it unique if needed."),
            "new_text": PropertySchema(type: "string", description: "Replacement text that will be written in place of old_text."),
        ],
        required: ["path", "old_text", "new_text"]
    )

    private let permissions: PermissionEngine

    public init(permissions: PermissionEngine) {
        self.permissions = permissions
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let path = arguments["path"] as? String else {
            return .error("Missing required argument: path")
        }
        guard let oldText = arguments["old_text"] as? String else {
            return .error("Missing required argument: old_text")
        }
        guard let newText = arguments["new_text"] as? String else {
            return .error("Missing required argument: new_text")
        }

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

            // Count occurrences
            let occurrences = originalContent.components(separatedBy: oldText).count - 1

            guard occurrences > 0 else {
                return .error("old_text not found in file. Make sure the text matches exactly, including whitespace.")
            }

            if occurrences > 1 {
                return .error("old_text found \(occurrences) times in file. It must be unique. Add more surrounding context to old_text to make it unique.")
            }

            // Apply the replacement
            let newContent = originalContent.replacingOccurrences(of: oldText, with: newText)
            try newContent.write(toFile: resolvedPath, atomically: true, encoding: .utf8)

            let diff = generateUnifiedDiff(original: originalContent, updated: newContent, path: path)
            return .success("Applied edit to \(path)\n\(diff)")
        } catch {
            return .error("Failed to edit file: \(error.localizedDescription)")
        }
    }

    // MARK: - Diff generation

    /// Produces a unified diff between `original` and `updated` content.
    /// Because `edit_file` always replaces exactly one occurrence, the changed
    /// region is always a single contiguous block, which keeps the implementation simple.
    func generateUnifiedDiff(original: String, updated: String, path: String) -> String {
        let origLines = original.components(separatedBy: "\n")
        let newLines  = updated.components(separatedBy: "\n")

        // Find the first line that differs (lo) and trim the common suffix so that
        // origHi / newHi are one-past the last differing line in each array.
        var lo = 0
        while lo < origLines.count && lo < newLines.count && origLines[lo] == newLines[lo] {
            lo += 1
        }

        var origHi = origLines.count
        var newHi  = newLines.count
        while origHi > lo && newHi > lo && origLines[origHi - 1] == newLines[newHi - 1] {
            origHi -= 1
            newHi  -= 1
        }

        guard lo < origHi || lo < newHi else { return "(no changes)" }

        // Expand the hunk window by up to 3 lines of context on each side.
        let ctx = 3
        let hunkStart    = max(0, lo - ctx)
        let hunkOrigEnd  = min(origLines.count, origHi + ctx)

        let leadingCtx   = lo - hunkStart
        let deletedCount = origHi - lo
        let addedCount   = newHi - lo
        let trailingCtx  = hunkOrigEnd - origHi

        let totalOrig = leadingCtx + deletedCount + trailingCtx
        let totalNew  = leadingCtx + addedCount   + trailingCtx

        var hunk = "@@ -\(hunkStart + 1),\(totalOrig) +\(hunkStart + 1),\(totalNew) @@\n"

        for l in hunkStart..<lo       { hunk += " \(origLines[l])\n" }
        for l in lo..<origHi          { hunk += "-\(origLines[l])\n" }
        for l in lo..<newHi           { hunk += "+\(newLines[l])\n"  }
        for l in origHi..<hunkOrigEnd { hunk += " \(origLines[l])\n" }

        return "--- a/\(path)\n+++ b/\(path)\n\(hunk)"
    }
}
