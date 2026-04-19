// Sources/AgentCore/AgentLoop+LoopDetectionBridge.swift
// Thin forwarding helpers so tests and call sites can access loop-detection utilities via AgentLoop.

import Foundation

extension AgentLoop {

    static func evaluateReadFileLoop(
        callName: String,
        arguments: [String: Any],
        previousSignature: String?,
        previousStreak: Int,
        limit: Int = LoopDetectionService.repeatedReadFileStreakLimit
    ) -> (nextSignature: String?, nextStreak: Int, shouldBlock: Bool, normalizedPath: String?, rawPath: String?) {
        LoopDetectionService.evaluateReadFileLoop(
            callName: callName,
            arguments: arguments,
            previousSignature: previousSignature,
            previousStreak: previousStreak,
            limit: limit
        )
    }

    static func evaluateReadOnlyToolLoop(
        callName: String,
        arguments: [String: Any],
        previousSignature: String?,
        previousStreak: Int,
        limit: Int = LoopDetectionService.repeatedReadOnlyToolStreakLimit
    ) -> (nextSignature: String?, nextStreak: Int, shouldBlock: Bool, signature: String?) {
        LoopDetectionService.evaluateReadOnlyToolLoop(
            callName: callName,
            arguments: arguments,
            previousSignature: previousSignature,
            previousStreak: previousStreak,
            limit: limit
        )
    }

    static func missingRequiredArgumentNames(required: [String]?, arguments: [String: Any]) -> [String] {
        LoopDetectionService.missingRequiredArgumentNames(required: required, arguments: arguments)
    }

    static func makeTokenCountLookup(contents: [String], counts: [Int]) -> [String: Int] {
        LoopDetectionService.makeTokenCountLookup(contents: contents, counts: counts)
    }

    static func sanitizeAuditField(_ value: String) -> String {
        LoopDetectionService.sanitizeAuditField(value)
    }
}
