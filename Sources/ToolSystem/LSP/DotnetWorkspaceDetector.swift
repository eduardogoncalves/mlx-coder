// Sources/ToolSystem/LSP/DotnetWorkspaceDetector.swift
// Detects whether a workspace should enable .NET LSP support.

import Foundation

actor DotnetWorkspaceDetector {
    struct WorkspaceInfo: Sendable {
        let isDotnet: Bool
        let startupTargetPath: String?
    }

    private var cache: [String: WorkspaceInfo] = [:]

    func isDotnetWorkspace(_ workspaceRoot: String) -> Bool {
        workspaceInfo(workspaceRoot).isDotnet
    }

    func workspaceInfo(_ workspaceRoot: String) -> WorkspaceInfo {
        if let cached = cache[workspaceRoot] {
            return cached
        }

        let info = detectDotnetWorkspace(workspaceRoot)
        cache[workspaceRoot] = info
        return info
    }

    func clearCache(for workspaceRoot: String) {
        cache[workspaceRoot] = nil
    }

    // MARK: - Private

    private func detectDotnetWorkspace(_ workspaceRoot: String) -> WorkspaceInfo {
        let rootURL = URL(filePath: workspaceRoot).standardizedFileURL
        let fm = FileManager.default

        // Fast bounded BFS scan to avoid blocking on very large workspaces.
        let maxDepth = 3
        let maxVisitedEntries = 8_000
        var visitedEntries = 0
        var foundCsproj = false

        var queue: [(url: URL, depth: Int)] = [(rootURL, 0)]
        var index = 0

        while index < queue.count {
            let (dir, depth) = queue[index]
            index += 1

            guard let children = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for child in children {
                visitedEntries += 1
                if visitedEntries >= maxVisitedEntries {
                    return WorkspaceInfo(isDotnet: foundCsproj, startupTargetPath: nil)
                }

                let name = child.lastPathComponent
                if child.pathExtension == "sln" || child.pathExtension == "slnx" {
                    return WorkspaceInfo(isDotnet: true, startupTargetPath: child.path)
                }

                if child.pathExtension == "csproj" {
                    foundCsproj = true
                }

                if name == "global.json" {
                    return WorkspaceInfo(isDotnet: true, startupTargetPath: nil)
                }

                if depth >= maxDepth {
                    continue
                }

                if isIgnoredDirectory(name) {
                    continue
                }

                let values = try? child.resourceValues(forKeys: [.isDirectoryKey])
                if values?.isDirectory == true {
                    queue.append((child, depth + 1))
                }
            }
        }

        return WorkspaceInfo(isDotnet: foundCsproj, startupTargetPath: nil)
    }

    private func isIgnoredDirectory(_ name: String) -> Bool {
        switch name {
        case ".git", ".build", "node_modules", ".swiftpm", "DerivedData", "bin", "obj":
            return true
        default:
            return false
        }
    }
}
