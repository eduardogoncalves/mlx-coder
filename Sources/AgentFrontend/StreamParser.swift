// Sources/AgentFrontend/StreamParser.swift
// Pure state machine that splits a streaming token feed into
// AgentEvent.assistantTextChunk / .thinkingStarted / .thinkingChunk /
// .thinkingEnded events.
//
// Ported from the inline parser previously in AgentLoop+Generation.swift
// (see commit history for the pre-refactor version).

import Foundation

public struct StreamParser: Sendable {

    // MARK: Configuration

    public let openTag: String
    public let closeTag: String

    /// Prefixes the buffer might end with that are *partial* matches of
    /// `openTag`. Computed once at init.
    private let openPrefixes: [String]
    private let closePrefixes: [String]

    // MARK: State

    /// Bytes parsed but not yet emitted (might still complete a tag).
    private var pending: String = ""
    /// True when we're currently inside an open `<think>` block.
    private(set) public var isThinking: Bool

    // MARK: Init

    public init(
        openTag: String = "<think>",
        closeTag: String = "</think>",
        startsThinking: Bool = false
    ) {
        self.openTag = openTag
        self.closeTag = closeTag
        self.isThinking = startsThinking
        self.openPrefixes = Self.prefixes(of: openTag)
        self.closePrefixes = Self.prefixes(of: closeTag)
    }

    private static func prefixes(of tag: String) -> [String] {
        // All non-empty proper prefixes of the tag, longest first so that
        // `hasSuffix` checks short-circuit on the most likely match.
        guard tag.count > 1 else { return [] }
        var out: [String] = []
        for n in 1..<tag.count {
            out.append(String(tag.prefix(n)))
        }
        return out
    }

    // MARK: Feeding

    /// Append `chunk` to the buffer and drain whatever is unambiguously
    /// classifiable into events.
    public mutating func feed(_ chunk: String) -> [AgentEvent] {
        pending += chunk
        var events: [AgentEvent] = []
        drain(into: &events)
        return events
    }

    /// Flush all remaining buffered content as the appropriate event type.
    /// Call once when the stream ends.
    public mutating func flush() -> [AgentEvent] {
        guard !pending.isEmpty else { return [] }
        let event: AgentEvent = isThinking
            ? .thinkingChunk(pending)
            : .assistantTextChunk(pending)
        pending = ""
        return [event]
    }

    // MARK: Driver

    private mutating func drain(into events: inout [AgentEvent]) {
        while !pending.isEmpty {
            if isThinking {
                if let range = pending.range(of: closeTag) {
                    let before = String(pending[..<range.lowerBound])
                    if !before.isEmpty {
                        events.append(.thinkingChunk(before))
                    }
                    events.append(.thinkingEnded)
                    isThinking = false
                    pending = String(pending[range.upperBound...])
                    if pending.hasPrefix("\n") { pending.removeFirst() }
                } else if closePrefixes.contains(where: pending.hasSuffix) {
                    // Could be the start of `</think>` — wait for more bytes.
                    return
                } else {
                    events.append(.thinkingChunk(pending))
                    pending = ""
                }
            } else {
                if let range = pending.range(of: openTag) {
                    let before = String(pending[..<range.lowerBound])
                    if !before.isEmpty {
                        events.append(.assistantTextChunk(before))
                    }
                    events.append(.thinkingStarted)
                    isThinking = true
                    pending = String(pending[range.upperBound...])
                    if pending.hasPrefix("\n") { pending.removeFirst() }
                } else if openPrefixes.contains(where: pending.hasSuffix) {
                    // Could be the start of `<think>` — wait for more bytes.
                    return
                } else {
                    events.append(.assistantTextChunk(pending))
                    pending = ""
                }
            }
        }
    }
}
