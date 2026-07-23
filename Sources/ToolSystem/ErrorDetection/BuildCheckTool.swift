import Foundation

/// Tool that allows the agent to explicitly check for build errors
/// Returns JSON with error details
public struct BuildCheckTool: Tool {
    public let name = "build_check"
    
    public let description = """
    Check for compilation/build errors in the project. Detects errors using LSP servers (fast) \
    and falls back to actual build tools (thorough). Supports: .NET (dotnet), Node.js (npm/yarn/pnpm), \
    Go, Rust (cargo), Python. Returns errors grouped by file with line numbers and messages.
    """
    
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "workspace": PropertySchema(
                type: "string",
                description: "Optional workspace path (default: current directory)"
            )
        ],
        required: []
    )
    
    private let permissions: PermissionEngine
    private let buildErrorDetector: BuildErrorDetector
    
    public init(
        permissions: PermissionEngine,
        buildErrorDetector: BuildErrorDetector = BuildErrorDetector()
    ) {
        self.permissions = permissions
        self.buildErrorDetector = buildErrorDetector
    }
    
    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        let workspacePath = (arguments["workspace"] as? String) ?? FileManager.default.currentDirectoryPath
        
        // Validate workspace path
        do {
            _ = try permissions.validatePath(workspacePath)
        } catch {
            return .error("Access denied to workspace path: \(workspacePath)")
        }
        
        do {
            // Run build check
            let result = await buildErrorDetector.detect(workspace: workspacePath)
            
            // Format as JSON for tool result
            let renderer = BuildCheckRenderer()
            let jsonOutput = try renderer.formatErrorsAsJSON(result)
            
            if result.hasErrors {
                return .error(jsonOutput)
            } else {
                return .success(jsonOutput)
            }
        } catch {
            return .error("Build check failed: \(error.localizedDescription)")
        }
    }
}
