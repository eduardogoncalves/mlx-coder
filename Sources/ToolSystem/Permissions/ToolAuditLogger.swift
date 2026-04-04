// Sources/ToolSystem/Permissions/ToolAuditLogger.swift
// Persistent audit logging for tool approval and execution events

import Foundation

public actor ToolAuditLogger {
    private let logFilePath: String
    private let workspaceRoot: String
    private let approvalMode: String
    private let isoFormatter = ISO8601DateFormatter()

    public init(logFilePath: String? = nil, workspaceRoot: String, approvalMode: String) {
        self.workspaceRoot = workspaceRoot
        self.approvalMode = approvalMode

        if let logFilePath {
            self.logFilePath = logFilePath
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            self.logFilePath = "\(home)/.native-agent/audit.log.jsonl"
        }

        self.isoFormatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
    }

    public func logApprovalDecision(
        toolName: String,
        mode: String,
        isPlanModePrompt: Bool,
        approved: Bool,
        suggestion: String?
    ) {
        let payload: [String: Any] = [
            "event": "approval_decision",
            "timestamp": isoFormatter.string(from: Date()),
            "workspace_root": workspaceRoot,
            "approval_mode": approvalMode,
            "agent_mode": mode,
            "plan_mode_prompt": isPlanModePrompt,
            "tool": toolName,
            "approved": approved,
            "suggestion": clamp(suggestion)
        ]

        write(payload)
    }

    public func logExecutionResult(
        toolName: String,
        arguments: [String: Any],
        approved: Bool,
        isError: Bool,
        resultPreview: String
    ) {
        let payload: [String: Any] = [
            "event": "tool_execution",
            "timestamp": isoFormatter.string(from: Date()),
            "workspace_root": workspaceRoot,
            "approval_mode": approvalMode,
            "tool": toolName,
            "approved": approved,
            "is_error": isError,
            "arguments": serializeArguments(arguments),
            "result_preview": clamp(resultPreview)
        ]

        write(payload)
    }

    public func logHookEvent(
        hookName: String,
        eventName: String,
        toolName: String?,
        details: String
    ) {
        let payload: [String: Any] = [
            "event": "hook_event",
            "timestamp": isoFormatter.string(from: Date()),
            "workspace_root": workspaceRoot,
            "approval_mode": approvalMode,
            "hook": hookName,
            "hook_event": eventName,
            "tool": toolName ?? "",
            "details": clamp(details)
        ]

        write(payload)
    }

    public func logParameterCorrection(
        toolName: String,
        originalArgumentsJSON: String,
        correctedArgumentsJSON: String,
        corrections: [String]
    ) {
        let payload: [String: Any] = [
            "event": "parameter_correction",
            "timestamp": isoFormatter.string(from: Date()),
            "workspace_root": workspaceRoot,
            "approval_mode": approvalMode,
            "tool": toolName,
            "original_arguments": originalArgumentsJSON,
            "corrected_arguments": correctedArgumentsJSON,
            "corrections": corrections.joined(separator: "; ")
        ]

        write(payload)
    }

    // MARK: - Private

    private func clamp(_ value: String?, limit: Int = 500) -> String {
        let text = value ?? ""
        if text.count <= limit {
            return text
        }
        let end = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<end]) + "... [truncated]"
    }

    private func serializeArguments(_ arguments: [String: Any]) -> String {
        if JSONSerialization.isValidJSONObject(arguments),
           let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            return json
        }

        return String(describing: arguments)
    }

    private func write(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8)?.appending("\n") else {
            return
        }

        let fileManager = FileManager.default
        let directory = URL(filePath: logFilePath).deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        if !fileManager.fileExists(atPath: logFilePath) {
            fileManager.createFile(atPath: logFilePath, contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: URL(filePath: logFilePath)) else {
            return
        }

        defer {
            try? handle.close()
        }

        do {
            try handle.seekToEnd()
            if let lineData = line.data(using: .utf8) {
                try handle.write(contentsOf: lineData)
            }
        } catch {
            // Keep logging best-effort and non-fatal.
        }
    }
}