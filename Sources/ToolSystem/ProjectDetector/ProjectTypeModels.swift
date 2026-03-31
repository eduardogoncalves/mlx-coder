import Foundation

/// Supported project types that the agent can detect and build
public enum ProjectType: String, Sendable {
    case dotnet = "dotnet"
    case nodejs = "nodejs"
    case go = "go"
    case rust = "rust"
    case python = "python"
    case unknown = "unknown"
}

/// Package manager detected for the project
public enum PackageManager: String, Sendable {
    case npm = "npm"
    case yarn = "yarn"
    case pnpm = "pnpm"
    case pip = "pip"
    case pipenv = "pipenv"
    case poetry = "poetry"
    case cargo = "cargo"
    case gomod = "go"
    case nuget = "nuget"
}

/// Information about a detected project
public struct ProjectInfo: Sendable {
    /// The type of project detected
    public let type: ProjectType
    
    /// The build tool name (e.g., "dotnet", "npm", "go")
    public let buildTool: String
    
    /// Primary project/workspace file (e.g., "project.csproj", "package.json", "go.mod")
    public let mainProjectFile: String?
    
    /// Detected package manager
    public let packageManager: PackageManager?
    
    /// Absolute path to the main file
    public let mainProjectFilePath: String?
    
    /// Whether the project has a build script configured
    public let hasBuildScript: Bool
    
    /// Working directory for build commands
    public let buildWorkingDirectory: String
    
    public init(
        type: ProjectType,
        buildTool: String,
        mainProjectFile: String? = nil,
        packageManager: PackageManager? = nil,
        mainProjectFilePath: String? = nil,
        hasBuildScript: Bool = false,
        buildWorkingDirectory: String = FileManager.default.currentDirectoryPath
    ) {
        self.type = type
        self.buildTool = buildTool
        self.mainProjectFile = mainProjectFile
        self.packageManager = packageManager
        self.mainProjectFilePath = mainProjectFilePath
        self.hasBuildScript = hasBuildScript
        self.buildWorkingDirectory = buildWorkingDirectory
    }
}

/// Detection result with optional error
public struct ProjectDetectionResult: Sendable {
    public let projectInfo: ProjectInfo?
    public let error: String?
    
    public var isDetected: Bool {
        projectInfo != nil && projectInfo?.type != .unknown
    }
    
    public static func success(_ info: ProjectInfo) -> ProjectDetectionResult {
        ProjectDetectionResult(projectInfo: info, error: nil)
    }
    
    public static func unknown() -> ProjectDetectionResult {
        ProjectDetectionResult(projectInfo: nil, error: nil)
    }
    
    public static func error(_ message: String) -> ProjectDetectionResult {
        ProjectDetectionResult(projectInfo: nil, error: message)
    }
}
