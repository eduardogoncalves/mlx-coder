// Sources/ToolSystem/Protocol/ToolProtocol.swift
// Base protocol and types for all agent tools

import Foundation

public typealias ToolProgressHandler = @Sendable (String) -> Void

/// Result of a tool execution.
public struct ToolResult: Sendable {
    /// The primary output content.
    public let content: String
    /// If output was truncated, the marker text (e.g. "[... 42 lines omitted ...]")
    public let truncationMarker: String?
    /// Whether this result represents an error.
    public let isError: Bool

    public init(content: String, truncationMarker: String? = nil, isError: Bool = false) {
        self.content = content
        self.truncationMarker = truncationMarker
        self.isError = isError
    }

    /// Convenience for a successful result.
    public static func success(_ content: String) -> ToolResult {
        ToolResult(content: content)
    }

    /// Convenience for an error result.
    public static func error(_ message: String) -> ToolResult {
        ToolResult(content: message, isError: true)
    }
}

/// JSON Schema representation for tool parameters.
public struct JSONSchema: Sendable, Codable {
    public let type: String
    public let properties: [String: PropertySchema]?
    public let required: [String]?

    public init(type: String = "object", properties: [String: PropertySchema]? = nil, required: [String]? = nil) {
        self.type = type
        self.properties = properties
        self.required = required
    }
}

/// Schema for a single property within a JSON Schema.
/// Uses a final class (reference type) to support recursive `items` field.
public final class PropertySchema: Sendable, Codable {
    public let type: String
    public let description: String?
    public let items: PropertySchema?
    public let enumValues: [String]?

    enum CodingKeys: String, CodingKey {
        case type, description, items
        case enumValues = "enum"
    }

    public init(type: String, description: String? = nil, items: PropertySchema? = nil, enumValues: [String]? = nil) {
        self.type = type
        self.description = description
        self.items = items
        self.enumValues = enumValues
    }
}

/// Protocol that all agent tools must conform to.
public protocol Tool: Sendable {
    /// The unique name used to invoke this tool.
    var name: String { get }
    /// A human-readable description of what the tool does.
    var description: String { get }
    /// JSON Schema describing the tool's parameters.
    var parameters: JSONSchema { get }
    /// Execute the tool with the given arguments.
    func execute(arguments: [String: Any]) async throws -> ToolResult
}

/// Optional protocol for tools that can report execution progress.
public protocol ProgressReportingTool: Tool {
    /// Execute with a progress callback for user-facing status updates.
    func execute(arguments: [String: Any], reportProgress: @escaping ToolProgressHandler) async throws -> ToolResult
}
