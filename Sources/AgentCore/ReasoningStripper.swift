// Sources/AgentCore/ReasoningStripper.swift
// Removes hidden model reasoning from text before it is persisted to history.
//
// History must represent what was actually communicated to the user — visible
// assistant responses — not the model's internal deliberation. This is the single
// place that knows which markers wrap reasoning, so support for new hidden-reasoning
// formats is added by extending `reasoningTags` alone.

import Foundation

/// Strips hidden reasoning/analysis blocks from assistant text while leaving the
/// visible response (and any tool-call markup) untouched.
public enum ReasoningStripper {

    /// Marker tag names whose `<tag>…</tag>` content is model reasoning, not a
    /// visible response. Extend this list to support future hidden-reasoning
    /// formats without touching call sites.
    public static let reasoningTags = ["think", "reasoning", "analysis"]

    /// Remove every configured reasoning block from `text`.
    ///
    /// Handles two shapes per tag:
    /// 1. Full blocks: `<tag>…</tag>` anywhere in the text.
    /// 2. Force-started blocks: when the opening tag was pre-filled into the prompt
    ///    the response begins *inside* the block and only a trailing `</tag>` remains;
    ///    everything up to and including that close tag is dropped.
    public static func strip(_ text: String) -> String {
        var result = text
        for tag in reasoningTags {
            result = stripTag(tag, from: result)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripTag(_ tag: String, from text: String) -> String {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        var result = text

        // 1. Remove complete <tag>…</tag> blocks.
        while let openRange = result.range(of: open),
              let closeRange = result.range(of: close, range: openRange.upperBound..<result.endIndex) {
            let before = result[..<openRange.lowerBound]
            let after = result[closeRange.upperBound...]
            result = String(before) + String(after)
        }

        // 2. Force-started block: a lone closing tag with no matching opener means the
        // response began inside reasoning that was opened by the prompt. Keep only what
        // follows the close tag (the visible answer).
        if let closeRange = result.range(of: close) {
            result = String(result[closeRange.upperBound...])
        }

        // 3. Strip any remaining orphaned close tags — the model sometimes emits a
        //    spurious second </tag> in its visible response after the block already
        //    closed. There is no valid semantic reason for a bare close tag to appear
        //    in assistant-visible text, so stripping is always safe here.
        result = result.replacingOccurrences(of: close, with: "")

        return result
    }
}
