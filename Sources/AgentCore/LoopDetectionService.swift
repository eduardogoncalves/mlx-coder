// Sources/AgentCore/LoopDetectionService.swift
// Pure utility for detecting repeated tool call loops and validating arguments.

import Foundation

/// Detects repetitive tool call patterns and provides argument validation.
/// Stateless — all methods are static and require no actor involvement.
enum LoopDetectionService {

    static let repeatedReadFileStreakLimit = 2
    static let repeatedReadOnlyToolStreakLimit = 1
    static let repeatedReadOnlyLoopTools: Set<String> = [
        "list_dir",
        "glob",
        "grep",
        "read_many",
        "code_search",
        "web_fetch",
        "web_search"
    ]

    static func evaluateReadFileLoop(
        callName: String,
        arguments: [String: Any],
        previousSignature: String?,
        previousStreak: Int,
        limit: Int = LoopDetectionService.repeatedReadFileStreakLimit
    ) -> (nextSignature: String?, nextStreak: Int, shouldBlock: Bool, normalizedPath: String?, rawPath: String?) {
        guard callName == "read_file" else {
            return (nil, 0, false, nil, nil)
        }

        let rawPath = ((arguments["path"] as? String) ?? (arguments["file_path"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else {
            return (nil, 0, false, nil, nil)
        }

        let normalizedPath = NSString(string: rawPath).standardizingPath
        let startLineSignature = readFileLoopSignatureValue(arguments["start_line"])
        let endLineSignature = readFileLoopSignatureValue(arguments["end_line"])
        let currentSignature = "\(normalizedPath)|start:\(startLineSignature)|end:\(endLineSignature)"
        let nextStreak = (currentSignature == previousSignature) ? (previousStreak + 1) : 1
        let shouldBlock = nextStreak > limit
        return (currentSignature, nextStreak, shouldBlock, normalizedPath, rawPath)
    }

    static func evaluateReadOnlyToolLoop(
        callName: String,
        arguments: [String: Any],
        previousSignature: String?,
        previousStreak: Int,
        limit: Int = LoopDetectionService.repeatedReadOnlyToolStreakLimit
    ) -> (nextSignature: String?, nextStreak: Int, shouldBlock: Bool, signature: String?) {
        guard repeatedReadOnlyLoopTools.contains(callName) else {
            return (nil, 0, false, nil)
        }

        let normalizedArgs = normalizedReadOnlyLoopArguments(arguments)
        let argsSignature = stableReadOnlyLoopArgumentsSignature(normalizedArgs)
        let currentSignature = "\(callName)|\(argsSignature)"
        let nextStreak = (currentSignature == previousSignature) ? (previousStreak + 1) : 1
        let shouldBlock = nextStreak > limit
        return (currentSignature, nextStreak, shouldBlock, currentSignature)
    }

    static func missingRequiredArgumentNames(required: [String]?, arguments: [String: Any]) -> [String] {
        guard let required, !required.isEmpty else { return [] }
        return required.filter { key in
            guard let value = arguments[key] else { return true }
            if let stringValue = value as? String {
                return stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if let arrayValue = value as? [Any] {
                return arrayValue.isEmpty
            }
            return false
        }
    }

    static func makeTokenCountLookup(contents: [String], counts: [Int]) -> [String: Int] {
        var lookup: [String: Int] = [:]
        lookup.reserveCapacity(min(contents.count, counts.count))
        for (content, count) in zip(contents, counts) {
            // Duplicate message content is expected; token count for identical text is identical.
            lookup[content] = count
        }
        return lookup
    }

    static func sanitizeAuditField(_ value: String) -> String {
        var sanitized = ""
        sanitized.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\":
                sanitized += "\\\\\\\\"
            case "\r":
                sanitized += "\\r"
            case "\n":
                sanitized += "\\n"
            case "\t":
                sanitized += "\\t"
            default:
                sanitized.unicodeScalars.append(scalar)
            }
        }
        return sanitized
    }

    // MARK: - Private Helpers

    private static func readFileLoopSignatureValue(_ value: Any?) -> String {
        switch value {
        case let stringValue as String:
            return stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        case let intValue as Int:
            return String(intValue)
        case nil:
            return "nil"
        default:
            return String(describing: value!)
        }
    }

    private static func normalizedReadOnlyLoopArguments(_ arguments: [String: Any]) -> [String: Any] {
        var normalized = arguments
        let pathKeys = ["path", "file_path"]
        for key in pathKeys {
            if let path = normalized[key] as? String {
                let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                normalized[key] = NSString(string: trimmed).standardizingPath
            }
        }
        if let paths = normalized["paths"] as? [String] {
            normalized["paths"] = paths.map {
                NSString(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)).standardizingPath
            }
        }
        return normalized
    }

    private static func stableReadOnlyLoopArgumentsSignature(_ arguments: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(arguments),
              let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: arguments)
        }
        return text
    }
}
