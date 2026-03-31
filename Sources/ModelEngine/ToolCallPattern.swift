// Sources/ModelEngine/ToolCallPattern.swift
// AUTO-GENERATED from tokenizer_config.json — do not edit manually
// Re-run bootstrap skill to regenerate after model change
//
// Values below are based on the Qwen3 / Qwen3.5 ChatML format.
// Verify against the actual model's tokenizer_config.json once downloaded.

public enum ToolCallPattern {
    // Chat role delimiters (ChatML)
    public static let imStart            = "<|im_start|>"
    public static let imEnd              = "<|im_end|>"

    // Tool calling tokens
    public static let toolCallOpen       = "<tool_call>"
    public static let toolCallClose      = "</tool_call>"
    public static let toolResponseOpen   = "<tool_response>"
    public static let toolResponseClose  = "</tool_response>"

    // Thinking tokens
    public static let thinkOpen          = "<think>"
    public static let thinkClose         = "</think>"

    // Role identifiers
    public static let roleSystem         = "system"
    public static let roleUser           = "user"
    public static let roleAssistant      = "assistant"
    public static let roleTool           = "tool"

    // End-of-sequence token
    public static let eosToken           = "<|im_end|>"

    // Tool definition wrapper (used in system prompt)
    public static let toolsOpen          = "<tools>"
    public static let toolsClose         = "</tools>"
}
