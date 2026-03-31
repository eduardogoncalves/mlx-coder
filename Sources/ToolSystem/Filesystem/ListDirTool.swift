// Sources/ToolSystem/Filesystem/ListDirTool.swift
// List directory contents with size and type info

import Foundation

/// Lists the contents of a directory with file type and size information.
public struct ListDirTool: Tool {
    public let name = "list_dir"
    public let description = "List the contents of a directory, showing file names, types, and sizes."
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "path": PropertySchema(type: "string", description: "Path to the directory to list (relative to workspace root)"),
            "recursive": PropertySchema(type: "boolean", description: "If true, list contents recursively (default: false)"),
            "max_depth": PropertySchema(type: "integer", description: "Maximum recursion depth (default: 3)"),
        ],
        required: ["path"]
    )

    private let permissions: PermissionEngine
    private let maxEntries: Int

    public init(permissions: PermissionEngine, maxEntries: Int = 200) {
        self.permissions = permissions
        self.maxEntries = maxEntries
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let path = arguments["path"] as? String else {
            return .error("Missing required argument: path")
        }

        let recursive = arguments["recursive"] as? Bool ?? false
        let maxDepth = arguments["max_depth"] as? Int ?? 3

        let resolvedPath: String
        do {
            resolvedPath = try permissions.validatePath(path)
        } catch {
            return .error(error.localizedDescription)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .error("Not a directory: \(path)")
        }

        var entries: [String] = []
        let basePath = resolvedPath

        func listContents(at dirPath: String, depth: Int) {
            guard depth <= maxDepth, entries.count < maxEntries else { return }

            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dirPath) else {
                return
            }

            for item in contents.sorted() {
                guard entries.count < maxEntries else { break }

                // Skip hidden files
                if item.hasPrefix(".") { continue }

                let fullPath = (dirPath as NSString).appendingPathComponent(item)
                
                // Security: Validate that full path is still within workspace
                // This prevents symlink escapes during recursive listing
                do {
                    let validatedPath = try permissions.validatePath(fullPath)
                    
                    let relativePath: String
                    if validatedPath.hasPrefix(basePath) {
                        let index = validatedPath.index(validatedPath.startIndex, offsetBy: basePath.count)
                        var remainder = String(validatedPath[index...])
                        if remainder.hasPrefix("/") {
                            remainder.removeFirst()
                        }
                        relativePath = remainder
                    } else {
                        // Path escaped workspace during validation, skip it
                        continue
                    }

                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: validatedPath, isDirectory: &isDir)

                    if isDir.boolValue {
                        entries.append("📁 \(relativePath)/")
                        if recursive {
                            listContents(at: validatedPath, depth: depth + 1)
                        }
                    } else {
                        let attrs = try? FileManager.default.attributesOfItem(atPath: validatedPath)
                        let size = attrs?[.size] as? UInt64 ?? 0
                        entries.append("📄 \(relativePath) (\(formatSize(size)))")
                    }
                } catch {
                    // Skip items that fail path validation (includes symlink escapes)
                    continue
                }
            }
        }

        listContents(at: resolvedPath, depth: 1)

        if entries.isEmpty {
            return .success("(empty directory)")
        }

        let omitted = entries.count >= maxEntries ? "\n[... entries omitted, limit \(maxEntries) ...]" : ""
        return ToolResult(
            content: entries.joined(separator: "\n"),
            truncationMarker: omitted.isEmpty ? nil : omitted
        )
    }

    private func formatSize(_ bytes: UInt64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}
