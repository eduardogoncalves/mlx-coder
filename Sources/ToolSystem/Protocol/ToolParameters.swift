// Sources/ToolSystem/Protocol/ToolParameters.swift
// Type-safe parameter wrapper for tool execution

import Foundation

/// A type-safe wrapper for tool parameters that eliminates boilerplate casting.
/// Instead of each tool implementing guard let casting of [String: Any] arguments,
/// use this helper to provide compile-time assistance and consistent error handling.
///
/// Conforms to @unchecked Sendable because [String: Any] is not officially Sendable,
/// but the data is safely sent via tool parameters which are created and immediately consumed.
///
/// Example usage:
/// ```swift
/// public func execute(arguments: ToolParameters) async throws -> ToolResult {
///     let query = try arguments.required("query", as: String.self)
///     let limit = arguments.optional("limit", as: Int.self, default: 10)
///     // ...
/// }
/// ```
public struct ToolParameters: @unchecked Sendable {
    private let dict: [String: Any]
    
    /// Initialize with a dictionary of parameters.
    public init(_ dict: [String: Any]) {
        self.dict = dict
    }
    
    /// Retrieve a required parameter, throwing if missing or wrong type.
    ///
    /// - Parameters:
    ///   - key: The parameter name
    ///   - type: The expected type
    /// - Returns: The parameter value
    /// - Throws: `ParameterError.missingRequired` or `ParameterError.incorrectType`
    public func required<T>(_ key: String, as type: T.Type) throws -> T {
        guard let value = dict[key] else {
            throw ParameterError.missingRequired(key: key)
        }
        guard let typedValue = value as? T else {
            throw ParameterError.incorrectType(key: key, expected: String(describing: type), got: String(describing: Swift.type(of: value)))
        }
        return typedValue
    }
    
    /// Retrieve an optional parameter, returning nil if missing.
    /// Throws if present but wrong type.
    ///
    /// - Parameters:
    ///   - key: The parameter name
    ///   - type: The expected type
    /// - Returns: The parameter value or nil
    /// - Throws: `ParameterError.incorrectType` if present but wrong type
    public func optional<T>(_ key: String, as type: T.Type) throws -> T? {
        guard let value = dict[key] else {
            return nil
        }
        guard let typedValue = value as? T else {
            throw ParameterError.incorrectType(key: key, expected: String(describing: type), got: String(describing: Swift.type(of: value)))
        }
        return typedValue
    }
    
    /// Retrieve an optional parameter with a default value.
    /// Returns default if missing; throws if present but wrong type.
    ///
    /// - Parameters:
    ///   - key: The parameter name
    ///   - type: The expected type
    ///   - defaultValue: Value to return if parameter is missing
    /// - Returns: The parameter value or defaultValue
    /// - Throws: `ParameterError.incorrectType` if present but wrong type
    public func optional<T>(_ key: String, as type: T.Type, default defaultValue: T) throws -> T {
        guard let value = dict[key] else {
            return defaultValue
        }
        guard let typedValue = value as? T else {
            throw ParameterError.incorrectType(key: key, expected: String(describing: type), got: String(describing: Swift.type(of: value)))
        }
        return typedValue
    }
    
    /// Check if a parameter exists in the dictionary.
    public func hasKey(_ key: String) -> Bool {
        return dict[key] != nil
    }
}

/// Errors thrown during parameter validation.
public enum ParameterError: LocalizedError {
    case missingRequired(key: String)
    case incorrectType(key: String, expected: String, got: String)
    
    public var errorDescription: String? {
        switch self {
        case .missingRequired(let key):
            return "Missing required parameter: \(key)"
        case .incorrectType(let key, let expected, let got):
            return "Parameter '\(key)' has incorrect type. Expected \(expected), got \(got)"
        }
    }
}
