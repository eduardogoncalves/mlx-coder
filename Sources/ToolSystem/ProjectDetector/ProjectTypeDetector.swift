import Foundation

/// Actor-based project type detector following DotnetWorkspaceDetector pattern
/// Fast bounded BFS search for project markers
public actor ProjectTypeDetector {
    private var cache: [String: ProjectDetectionResult] = [:]
    
    private let maxDepth: Int = 3
    private let maxEntriesScanned: Int = 8000
    
    public init() {}
    
    /// Clear the detection cache
    public func clearCache() {
        cache.removeAll()
    }
    
    /// Detect project type in the given workspace
    /// Returns ProjectDetectionResult with detected project info or unknown/error
    public func detect(workspace: String) -> ProjectDetectionResult {
        // Check cache
        if let cachedResult = cache[workspace] {
            return cachedResult
        }
        
        let result = detectInternal(workspace: workspace)
        cache[workspace] = result
        return result
    }
    
    private func detectInternal(workspace: String) -> ProjectDetectionResult {
        let fileManager = FileManager.default
        
        // Validate workspace exists
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: workspace, isDirectory: &isDir), isDir.boolValue else {
            return .error("Workspace path does not exist: \(workspace)")
        }
        
        // Fast BFS with bounded search
        var entryCount = 0
        var queue: [(path: String, depth: Int)] = [(workspace, 0)]
        var visited = Set<String>()
        
        while !queue.isEmpty && entryCount < maxEntriesScanned {
            let (currentPath, currentDepth) = queue.removeFirst()
            
            // Check depth limit
            if currentDepth > maxDepth {
                continue
            }
            
            // Avoid cycles
            if visited.contains(currentPath) {
                continue
            }
            visited.insert(currentPath)
            
            // Scan current directory for project markers (breadth-first)
            do {
                let contents = try fileManager.contentsOfDirectory(atPath: currentPath)
                for entry in contents {
                    entryCount += 1
                    if entryCount >= maxEntriesScanned {
                        break
                    }
                    
                    let fullPath = (currentPath as NSString).appendingPathComponent(entry)
                    
                    // Skip hidden files and known ignored directories
                    if entry.hasPrefix(".") || isIgnoredDirectory(entry) {
                        continue
                    }
                    
                    // Check for project markers
                    if let detectedInfo = checkProjectMarker(entry: entry, path: fullPath, workspace: workspace) {
                        return .success(detectedInfo)
                    }
                    
                    // Add directories to queue for next level
                    var isDir: ObjCBool = false
                    if fileManager.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                        queue.append((fullPath, currentDepth + 1))
                    }
                }
            } catch {
                continue // Skip directories we can't read
            }
        }
        
        // No project detected
        return .unknown()
    }
    
    private func checkProjectMarker(entry: String, path: String, workspace: String) -> ProjectInfo? {
        // .NET project markers (highest priority)
        if entry.hasSuffix(".sln") || entry.hasSuffix(".slnx") {
            return ProjectInfo(
                type: .dotnet,
                buildTool: "dotnet",
                mainProjectFile: entry,
                packageManager: .nuget,
                mainProjectFilePath: path,
                buildWorkingDirectory: workspace
            )
        }
        
        if entry == "global.json" {
            return ProjectInfo(
                type: .dotnet,
                buildTool: "dotnet",
                mainProjectFile: entry,
                packageManager: .nuget,
                mainProjectFilePath: path,
                buildWorkingDirectory: workspace
            )
        }
        
        if entry.hasSuffix(".csproj") || entry.hasSuffix(".fsproj") || entry.hasSuffix(".vbproj") {
            return ProjectInfo(
                type: .dotnet,
                buildTool: "dotnet",
                mainProjectFile: entry,
                packageManager: .nuget,
                mainProjectFilePath: path,
                buildWorkingDirectory: workspace
            )
        }
        
        // Node.js project marker
        if entry == "package.json" {
            let packageManager = detectNodePackageManager(workspace: workspace)
            return ProjectInfo(
                type: .nodejs,
                buildTool: "npm", // Will be overridden if yarn/pnpm detected
                mainProjectFile: entry,
                packageManager: packageManager,
                mainProjectFilePath: path,
                hasBuildScript: hasNodeBuildScript(path: path),
                buildWorkingDirectory: workspace
            )
        }
        
        // Go project marker
        if entry == "go.mod" {
            return ProjectInfo(
                type: .go,
                buildTool: "go",
                mainProjectFile: entry,
                packageManager: .gomod,
                mainProjectFilePath: path,
                buildWorkingDirectory: workspace
            )
        }
        
        // Rust project marker
        if entry == "Cargo.toml" {
            return ProjectInfo(
                type: .rust,
                buildTool: "cargo",
                mainProjectFile: entry,
                packageManager: .cargo,
                mainProjectFilePath: path,
                buildWorkingDirectory: workspace
            )
        }
        
        // Python project markers
        if entry == "pyproject.toml" {
            let packageManager = detectPythonPackageManager(workspace: workspace)
            return ProjectInfo(
                type: .python,
                buildTool: "python",
                mainProjectFile: entry,
                packageManager: packageManager,
                mainProjectFilePath: path,
                buildWorkingDirectory: workspace
            )
        }
        
        if entry == "requirements.txt" {
            return ProjectInfo(
                type: .python,
                buildTool: "python",
                mainProjectFile: entry,
                packageManager: .pip,
                mainProjectFilePath: path,
                buildWorkingDirectory: workspace
            )
        }
        
        if entry == "setup.py" || entry == "setup.cfg" {
            return ProjectInfo(
                type: .python,
                buildTool: "python",
                mainProjectFile: entry,
                packageManager: .pip,
                mainProjectFilePath: path,
                buildWorkingDirectory: workspace
            )
        }
        
        return nil
    }
    
    private func isIgnoredDirectory(_ name: String) -> Bool {
        let ignored = [
            ".git", ".build", "node_modules", ".swiftpm", "DerivedData",
            "bin", "obj", ".cache", "dist", "build", "__pycache__",
            ".venv", "venv", ".eggs", "*.egg-info", "target", ".cargo"
        ]
        return ignored.contains(name)
    }
    
    private func detectNodePackageManager(workspace: String) -> PackageManager {
        let fileManager = FileManager.default
        
        // Check for yarn.lock
        let yarnLock = (workspace as NSString).appendingPathComponent("yarn.lock")
        if fileManager.fileExists(atPath: yarnLock) {
            return .yarn
        }
        
        // Check for pnpm-lock.yaml
        let pnpmLock = (workspace as NSString).appendingPathComponent("pnpm-lock.yaml")
        if fileManager.fileExists(atPath: pnpmLock) {
            return .pnpm
        }
        
        // Default to npm
        return .npm
    }
    
    private func detectPythonPackageManager(workspace: String) -> PackageManager {
        let fileManager = FileManager.default
        
        // Check for Pipfile (pipenv)
        let pipfile = (workspace as NSString).appendingPathComponent("Pipfile")
        if fileManager.fileExists(atPath: pipfile) {
            return .pipenv
        }
        
        // Check for poetry.lock or pyproject.toml with [tool.poetry]
        let poetryLock = (workspace as NSString).appendingPathComponent("poetry.lock")
        if fileManager.fileExists(atPath: poetryLock) {
            return .poetry
        }
        
        // Default to pip
        return .pip
    }
    
    private func hasNodeBuildScript(path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: Any] else {
            return false
        }
        
        return scripts["build"] != nil || scripts["test"] != nil
    }
}
