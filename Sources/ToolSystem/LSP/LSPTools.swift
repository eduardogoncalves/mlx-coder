// Sources/ToolSystem/LSP/LSPTools.swift
// Read-only LSP-backed tools for .NET workspaces.

import Foundation

// Keep this larger than service/bridge timeouts so underlying LSP errors
// are surfaced with diagnostics instead of generic tool timeout failures.
private let lspToolTimeoutSeconds: Double = 90
private let lspDocumentSymbolsTimeoutSeconds: Double = 30

private func runWithTimeout<T: Sendable>(
    seconds: Double,
    operationName: String,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }

        group.addTask {
            let nanos = UInt64(seconds * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanos)
            throw LSPBridgeError.requestTimedOut(method: operationName, timeoutSeconds: seconds)
        }

        let first = try await group.next()
        group.cancelAll()

        guard let first else {
            throw LSPBridgeError.transportClosed
        }
        return first
    }
}

public struct LSPDiagnosticsTool: Tool {
    public let name = "lsp_diagnostics"
    public let description = "Return compiler errors and warnings for a C# file or the whole project."
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "file_path": PropertySchema(type: "string", description: "Target file path relative to workspace. Omit or set null for project-wide diagnostics."),
        ],
        required: []
    )

    private func handleLSPError(_ error: Error) -> String {
        if let bridgeError = error as? LSPBridgeError, case .disabledForSession(let reason) = bridgeError {
            return "LSP unavailable: \(reason). Set CSHARP_LS_PATH=/path/to/binary or NATIVE_AGENT_LSP_DISABLED=1"
        }
        return error.localizedDescription
    }

    private let permissions: PermissionEngine

    public init(permissions: PermissionEngine) {
        self.permissions = permissions
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        do {
            let filePath = parseOptionalString(arguments["file_path"])
            let diagnostics = try await runWithTimeout(seconds: lspToolTimeoutSeconds, operationName: name) {
                try await DotnetLSPService.shared.diagnostics(permissions: permissions, filePath: filePath)
            }
            return .success(diagnostics)
        } catch {
            return .error(handleLSPError(error))
        }
    }

    private func parseOptionalString(_ value: Any?) -> String? {
        if value == nil || value is NSNull {
            return nil
        }
        return value as? String
    }
}

public struct LSPHoverTool: Tool {
    public let name = "lsp_hover"
    public let description = "Get type info and documentation for a symbol at a given position."
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "file_path": PropertySchema(type: "string", description: "Path to the C# file (relative to workspace root)"),
            "line": PropertySchema(type: "integer", description: "0-based line index"),
            "character": PropertySchema(type: "integer", description: "0-based character index"),
        ],
        required: ["file_path", "line", "character"]
    )

    private let permissions: PermissionEngine

    public init(permissions: PermissionEngine) {
        self.permissions = permissions
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let filePath = arguments["file_path"] as? String else {
            return .error("Missing required argument: file_path")
        }
        guard let line = arguments["line"] as? Int else {
            return .error("Missing required argument: line")
        }
        guard let character = arguments["character"] as? Int else {
            return .error("Missing required argument: character")
        }

        do {
            let hover = try await runWithTimeout(seconds: lspToolTimeoutSeconds, operationName: name) {
                try await DotnetLSPService.shared.hover(
                    permissions: permissions,
                    filePath: filePath,
                    line: line,
                    character: character
                )
            }
            return .success(hover)
        } catch {
            return .error(error.localizedDescription)
        }
    }
}

public struct LSPReferencesTool: Tool {
    public let name = "lsp_references"
    public let description = "Find all usages of a symbol across the workspace."
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "file_path": PropertySchema(type: "string", description: "Path to the C# file (relative to workspace root)"),
            "line": PropertySchema(type: "integer", description: "0-based line index"),
            "character": PropertySchema(type: "integer", description: "0-based character index"),
        ],
        required: ["file_path", "line", "character"]
    )

    private let permissions: PermissionEngine

    public init(permissions: PermissionEngine) {
        self.permissions = permissions
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let filePath = arguments["file_path"] as? String else {
            return .error("Missing required argument: file_path")
        }
        guard let line = arguments["line"] as? Int else {
            return .error("Missing required argument: line")
        }
        guard let character = arguments["character"] as? Int else {
            return .error("Missing required argument: character")
        }

        do {
            let references = try await runWithTimeout(seconds: lspToolTimeoutSeconds, operationName: name) {
                try await DotnetLSPService.shared.references(
                    permissions: permissions,
                    filePath: filePath,
                    line: line,
                    character: character
                )
            }
            return .success(references)
        } catch {
            return .error(error.localizedDescription)
        }
    }
}

public struct LSPDefinitionTool: Tool {
    public let name = "lsp_definition"
    public let description = "Go to the definition location(s) for a symbol at a given position."
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "file_path": PropertySchema(type: "string", description: "Path to the C# file (relative to workspace root)"),
            "line": PropertySchema(type: "integer", description: "0-based line index"),
            "character": PropertySchema(type: "integer", description: "0-based character index"),
        ],
        required: ["file_path", "line", "character"]
    )

    private let permissions: PermissionEngine

    public init(permissions: PermissionEngine) {
        self.permissions = permissions
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let filePath = arguments["file_path"] as? String else {
            return .error("Missing required argument: file_path")
        }
        guard let line = arguments["line"] as? Int else {
            return .error("Missing required argument: line")
        }
        guard let character = arguments["character"] as? Int else {
            return .error("Missing required argument: character")
        }

        do {
            let definition = try await runWithTimeout(seconds: lspToolTimeoutSeconds, operationName: name) {
                try await DotnetLSPService.shared.definition(
                    permissions: permissions,
                    filePath: filePath,
                    line: line,
                    character: character
                )
            }
            return .success(definition)
        } catch {
            return .error(error.localizedDescription)
        }
    }
}

public struct LSPCompletionTool: Tool {
    public let name = "lsp_completion"
    public let description = "Get completion items for a symbol position in a C# file."
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "file_path": PropertySchema(type: "string", description: "Path to the C# file (relative to workspace root)"),
            "line": PropertySchema(type: "integer", description: "0-based line index"),
            "character": PropertySchema(type: "integer", description: "0-based character index"),
        ],
        required: ["file_path", "line", "character"]
    )

    private let permissions: PermissionEngine

    public init(permissions: PermissionEngine) {
        self.permissions = permissions
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let filePath = arguments["file_path"] as? String else {
            return .error("Missing required argument: file_path")
        }
        guard let line = arguments["line"] as? Int else {
            return .error("Missing required argument: line")
        }
        guard let character = arguments["character"] as? Int else {
            return .error("Missing required argument: character")
        }

        do {
            let completion = try await runWithTimeout(seconds: lspToolTimeoutSeconds, operationName: name) {
                try await DotnetLSPService.shared.completion(
                    permissions: permissions,
                    filePath: filePath,
                    line: line,
                    character: character
                )
            }
            return .success(completion)
        } catch {
            return .error(error.localizedDescription)
        }
    }
}

public struct LSPSignatureHelpTool: Tool {
    public let name = "lsp_signature_help"
    public let description = "Get method signature help at a symbol position in a C# file."
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "file_path": PropertySchema(type: "string", description: "Path to the C# file (relative to workspace root)"),
            "line": PropertySchema(type: "integer", description: "0-based line index"),
            "character": PropertySchema(type: "integer", description: "0-based character index"),
        ],
        required: ["file_path", "line", "character"]
    )

    private let permissions: PermissionEngine

    public init(permissions: PermissionEngine) {
        self.permissions = permissions
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let filePath = arguments["file_path"] as? String else {
            return .error("Missing required argument: file_path")
        }
        guard let line = arguments["line"] as? Int else {
            return .error("Missing required argument: line")
        }
        guard let character = arguments["character"] as? Int else {
            return .error("Missing required argument: character")
        }

        do {
            let result = try await runWithTimeout(seconds: lspToolTimeoutSeconds, operationName: name) {
                try await DotnetLSPService.shared.signatureHelp(
                    permissions: permissions,
                    filePath: filePath,
                    line: line,
                    character: character
                )
            }
            return .success(result)
        } catch {
            return .error(error.localizedDescription)
        }
    }
}

public struct LSPDocumentSymbolsTool: Tool {
    public let name = "lsp_document_symbols"
    public let description = "List document symbols for a C# file."
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "file_path": PropertySchema(type: "string", description: "Path to the C# file (relative to workspace root)"),
        ],
        required: ["file_path"]
    )

    private let permissions: PermissionEngine

    public init(permissions: PermissionEngine) {
        self.permissions = permissions
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let filePath = arguments["file_path"] as? String else {
            return .error("Missing required argument: file_path")
        }

        do {
            let result = try await runWithTimeout(seconds: lspDocumentSymbolsTimeoutSeconds, operationName: name) {
                try await DotnetLSPService.shared.documentSymbols(permissions: permissions, filePath: filePath)
            }
            return .success(result)
        } catch {
            if case .requestTimedOut = error as? LSPBridgeError {
                return fallbackDocumentSymbols(filePath: filePath, timeoutError: error)
            }
            if case .disabledForSession = error as? LSPBridgeError {
                return fallbackDocumentSymbols(filePath: filePath, timeoutError: error)
            }
            return .error(error.localizedDescription)
        }
    }

    private func fallbackDocumentSymbols(filePath: String, timeoutError: Error) -> ToolResult {
        do {
            let resolved = try permissions.validatePath(filePath)
            let source = try String(contentsOfFile: resolved, encoding: .utf8)
            let lines = source.components(separatedBy: .newlines)

            let symbolRegex = try NSRegularExpression(
                pattern: #"\b(class|record|struct|interface|enum|delegate)\s+([A-Za-z_][A-Za-z0-9_]*)"#,
                options: []
            )

            var symbols: [[String: Any]] = []
            symbols.reserveCapacity(min(lines.count, 200))

            for (lineIndex, line) in lines.enumerated() {
                let nsLine = line as NSString
                let matches = symbolRegex.matches(in: line, options: [], range: NSRange(location: 0, length: nsLine.length))
                for match in matches {
                    guard match.numberOfRanges >= 3 else { continue }
                    let kindToken = nsLine.substring(with: match.range(at: 1)).lowercased()
                    let name = nsLine.substring(with: match.range(at: 2))
                    let character = match.range(at: 2).location

                    // LSP SymbolKind values for type declarations.
                    let kindValue: Int
                    switch kindToken {
                    case "class": kindValue = 5
                    case "struct": kindValue = 23
                    case "interface": kindValue = 11
                    case "enum": kindValue = 10
                    case "delegate": kindValue = 12
                    case "record": kindValue = 5
                    default: kindValue = 13
                    }

                    symbols.append([
                        "name": name,
                        "kind": kindValue,
                        "detail": "fallback_regex",
                        "line": lineIndex,
                        "character": character,
                    ])
                }
            }

            let payload: [String: Any] = [
                "count": symbols.count,
                "symbols": symbols,
                "source": "fallback_regex",
                "warning": "\(timeoutError.localizedDescription). Returned best-effort regex symbols.",
            ]
            return .success(LSPResultFormatter.prettyJSON(payload))
        } catch {
            return .error(timeoutError.localizedDescription)
        }
    }
}

public struct LSPRenameTool: Tool {
    public let name = "lsp_rename"
    public let description = "Rename a C# symbol and return a workspace edit summary, or apply edits when apply=true."
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "file_path": PropertySchema(type: "string", description: "Path to the C# file (relative to workspace root)"),
            "line": PropertySchema(type: "integer", description: "0-based line index"),
            "character": PropertySchema(type: "integer", description: "0-based character index"),
            "new_name": PropertySchema(type: "string", description: "New symbol name"),
            "apply": PropertySchema(type: "boolean", description: "When true, apply the rename workspace edits to files. Defaults to false."),
        ],
        required: ["file_path", "line", "character", "new_name"]
    )

    private let permissions: PermissionEngine

    public init(permissions: PermissionEngine) {
        self.permissions = permissions
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        guard let filePath = arguments["file_path"] as? String else {
            return .error("Missing required argument: file_path")
        }
        guard let line = arguments["line"] as? Int else {
            return .error("Missing required argument: line")
        }
        guard let character = arguments["character"] as? Int else {
            return .error("Missing required argument: character")
        }
        guard let newName = arguments["new_name"] as? String, !newName.isEmpty else {
            return .error("Missing required argument: new_name")
        }
        let apply = (arguments["apply"] as? Bool) ?? false

        do {
            let result = try await runWithTimeout(seconds: lspToolTimeoutSeconds, operationName: name) {
                try await DotnetLSPService.shared.rename(
                    permissions: permissions,
                    filePath: filePath,
                    line: line,
                    character: character,
                    newName: newName,
                    apply: apply
                )
            }
            return .success(result)
        } catch {
            return .error(error.localizedDescription)
        }
    }
}
