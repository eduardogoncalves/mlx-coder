// Sources/ToolSystem/LSP/LSPModels.swift
// JSON-RPC and LSP model types used by the C# bridge.

import Foundation

public enum LSPBridgeError: LocalizedError {
    case serverUnavailable(String)
    case notDotnetWorkspace
    case invalidResponse(String)
    case requestTimedOut(method: String, timeoutSeconds: Double)
    case responseError(code: Int, message: String)
    case transportClosed
    case disabledForSession(String)

    public var errorDescription: String? {
        switch self {
        case .serverUnavailable(let hint):
            return "Unable to start csharp-ls. \(hint)"
        case .notDotnetWorkspace:
            return "LSP tools are only available in .NET workspaces (.csproj/.sln/global.json)."
        case .invalidResponse(let details):
            return "Invalid LSP response: \(details)"
        case .requestTimedOut(let method, let timeoutSeconds):
            return "LSP request '\(method)' timed out after \(Int(timeoutSeconds))s"
        case .responseError(let code, let message):
            return "LSP error \(code): \(message)"
        case .transportClosed:
            return "LSP transport closed unexpectedly."
        case .disabledForSession(let reason):
            return "LSP is disabled for this session: \(reason)"
        }
    }
}

public struct LSPDiagnostic: Sendable {
    public let uri: String
    public let code: String?
    public let severity: Int?
    public let message: String
    public let line: Int
    public let character: Int
}

public struct LSPReference: Sendable {
    public let uri: String
    public let line: Int
    public let character: Int
}

public struct LSPTextDocumentIdentifier: Codable, Sendable {
    public let uri: String
}

public struct LSPPosition: Codable, Sendable {
    public let line: Int
    public let character: Int
}

public struct LSPTextDocumentPositionParams: Codable, Sendable {
    public let textDocument: LSPTextDocumentIdentifier
    public let position: LSPPosition
}

public struct LSPReferenceContext: Codable, Sendable {
    public let includeDeclaration: Bool
}

public struct LSPReferenceParams: Codable, Sendable {
    public let textDocument: LSPTextDocumentIdentifier
    public let position: LSPPosition
    public let context: LSPReferenceContext
}

public struct LSPDefinitionParams: Codable, Sendable {
    public let textDocument: LSPTextDocumentIdentifier
    public let position: LSPPosition
}

public struct LSPCompletionParams: Codable, Sendable {
    public let textDocument: LSPTextDocumentIdentifier
    public let position: LSPPosition
}

public struct LSPSignatureHelpParams: Codable, Sendable {
    public let textDocument: LSPTextDocumentIdentifier
    public let position: LSPPosition
}

public struct LSPDocumentSymbolParams: Codable, Sendable {
    public let textDocument: LSPTextDocumentIdentifier
}

public struct LSPRenameParams: Codable, Sendable {
    public let textDocument: LSPTextDocumentIdentifier
    public let position: LSPPosition
    public let newName: String
}

public struct LSPDidOpenTextDocumentParams: Codable, Sendable {
    public struct TextDocumentItem: Codable, Sendable {
        public let uri: String
        public let languageId: String
        public let version: Int
        public let text: String
    }

    public let textDocument: TextDocumentItem
}

public struct LSPInitializeParams: Codable, Sendable {
    public struct WorkspaceFolder: Codable, Sendable {
        public let uri: String
        public let name: String
    }

    public struct Capabilities: Codable, Sendable {
        public struct TextDocumentCapabilities: Codable, Sendable {
            public struct DiagnosticCapability: Codable, Sendable {
                public let dynamicRegistration: Bool
            }

            public let diagnostic: DiagnosticCapability?
            public let hover: [String: Bool]?
            public let references: [String: Bool]?
        }

        public struct WorkspaceCapabilities: Codable, Sendable {
            public let diagnostic: [String: Bool]?
        }

        public let textDocument: TextDocumentCapabilities?
        public let workspace: WorkspaceCapabilities?
    }

    public let processId: Int32
    public let rootUri: String
    public let capabilities: Capabilities
    public let workspaceFolders: [WorkspaceFolder]
}

public struct LSPDiagnosticParams: Codable, Sendable {
    public struct Identifier: Codable, Sendable {
        public let uri: String
    }

    public struct PreviousResultId: Codable, Sendable {
        public let uri: String
        public let value: String
    }

    public let textDocument: Identifier
    public let identifier: String?
    public let previousResultId: String?
}

public struct LSPWorkspaceDiagnosticParams: Codable, Sendable {
    public let identifier: String?
    public let previousResultIds: [[String: String]]

    public init(identifier: String? = nil, previousResultIds: [[String: String]] = []) {
        self.identifier = identifier
        self.previousResultIds = previousResultIds
    }
}

public enum LSPResultFormatter {
    static func prettyJSON(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: object)
        }
        return text
    }

    static func pathFromURI(_ uri: String) -> String {
        guard let url = URL(string: uri), url.isFileURL else {
            return uri
        }
        return url.path
    }
}
