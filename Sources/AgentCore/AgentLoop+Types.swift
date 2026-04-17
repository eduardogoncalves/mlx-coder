// Sources/AgentCore/AgentLoop+Types.swift
// Type definitions for AgentLoop modes, thinking levels, and task types.

import Foundation

extension AgentLoop {

    public enum WorkingMode: String, Codable, Sendable {
        case agent
        case plan
    }

    public enum ThinkingLevel: String, Codable, Sendable {
        /// No thinking blocks — fastest, deterministic responses.
        case fast
        /// ~100-token thinking budget — one or two sentences of internal reasoning.
        case minimal
        /// ~300-token thinking budget — concise reasoning focused on the key insight.
        case low
        /// ~600-token thinking budget — moderate depth, balances speed and quality.
        case medium
        /// ~2000-token thinking budget — deep reasoning, explores multiple approaches.
        case high

        /// Approximate token budget for the thinking block at this level.
        public var budgetTokens: Int {
            switch self {
            case .fast:    return 0
            case .minimal: return 100
            case .low:     return 300
            case .medium:  return 600
            case .high:    return 2000
            }
        }

        /// Human-readable label shown in status messages and the REPL.
        public var displayName: String {
            switch self {
            case .fast:    return "fast (off)"
            case .minimal: return "minimal (~\(budgetTokens) tokens)"
            case .low:     return "low (~\(budgetTokens) tokens)"
            case .medium:  return "medium (~\(budgetTokens) tokens)"
            case .high:    return "high (~\(budgetTokens) tokens)"
            }
        }
    }

    public enum TaskType: String, Codable, Sendable {
        case general
        case coding
        case reasoning
    }

    public enum ModelMode: String, Codable, Sendable, CaseIterable {
        case planLow = "Plan (low)"
        case planHigh = "Plan (high)"
        case agentGeneralFast = "Agent (general/fast)"
        case agentGeneralLow = "Agent (general/low)"
        case agentCodingFast = "Agent (coding/fast)"
        case agentCodingLow = "Agent (coding/low)"
        case agentCodingHigh = "Agent (coding/high)"
    }
}
