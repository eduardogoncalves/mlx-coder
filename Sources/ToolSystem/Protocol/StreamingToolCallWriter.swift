// Sources/ToolSystem/Protocol/StreamingToolCallWriter.swift
// Streams tool call content directly to .tmp files during model generation
// to avoid memory bloat from large file contents.

import Foundation

/// A tool call whose content was streamed to a temporary file during generation.
public struct StreamedToolCall: @unchecked Sendable {
    public let toolName: String
    public let path: String
    public let contentFile: URL
    public let otherArgs: [String: Any]

    public init(toolName: String, path: String, contentFile: URL, otherArgs: [String: Any]) {
        self.toolName = toolName
        self.path = path
        self.contentFile = contentFile
        self.otherArgs = otherArgs
    }
}

/// Result of processing a chunk of tokens.
public struct StreamProcessResult: Sendable {
    public let displayText: String
}

/// Incremental state machine that detects tool calls in the token stream,
/// parses JSON arguments, and streams content fields directly to .tmp files.
public final class StreamingToolCallWriter: @unchecked Sendable {

    // MARK: - States

    private enum State: Equatable {
        case idle
        case accumulatingJSON(buffer: String)
        case streamingContent(
            jsonBuffer: String,
            path: String,
            toolName: String,
            contentKey: String,
            tmpFile: URL,
            fileHandle: FileHandle,
            inContentString: Bool,
            escapeState: EscapeState
        )
    }

    private enum EscapeState: Equatable {
        case normal
        case sawBackslash
        case sawUnicode(prefix: String)
    }

    // MARK: - Properties

    private var state: State = .idle
    private var completedCalls: [StreamedToolCall] = []
    private var failedCalls: [String] = []
    private var tmpDir: URL
    private let toolCallOpen: String
    private let toolCallClose: String
    private let onStatusChange: (@Sendable (String) -> Void)?
    private var inThinkBlock = false
    private var thinkBuffer = ""

    public var hasActiveStream: Bool {
        switch state {
        case .streamingContent: return true
        default: return false
        }
    }

    public init(
        tmpDir: URL? = nil,
        toolCallOpen: String = "\u{ee7d4}\u{ee7d4}",
        toolCallClose: String = "\u{ee7d4}\u{ee7d4}\u{ee7d4}",
        onStatusChange: (@Sendable (String) -> Void)? = nil
    ) {
        self.tmpDir = tmpDir ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mlx-coder-streaming")
        self.toolCallOpen = toolCallOpen
        self.toolCallClose = toolCallClose
        self.onStatusChange = onStatusChange
        try? FileManager.default.createDirectory(at: self.tmpDir, withIntermediateDirectories: true)
    }

    public func drainCompletedCalls() -> [StreamedToolCall] {
        let calls = completedCalls
        completedCalls.removeAll()
        return calls
    }

    public func drainFailedCalls() -> [String] {
        let calls = failedCalls
        failedCalls.removeAll()
        return calls
    }

    public func cleanupAllTmpFiles() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Processing

    public func process(_ text: String) -> StreamProcessResult {
        thinkBuffer += text
        var displayText = ""

        while !thinkBuffer.isEmpty {
            if inThinkBlock {
                if let closeRange = thinkBuffer.range(of: ToolCallPattern.thinkClose) {
                    let beforeClose = String(thinkBuffer[..<closeRange.lowerBound])
                    if !beforeClose.isEmpty {
                        displayText += beforeClose
                    }
                    displayText += ToolCallPattern.thinkClose
                    thinkBuffer = String(thinkBuffer[closeRange.upperBound...])
                    inThinkBlock = false
                    continue
                }

                let keep = trailingPossibleTagPrefix(in: thinkBuffer, for: ToolCallPattern.thinkClose)
                let emitCount = max(0, thinkBuffer.count - keep.count)
                if emitCount > 0 {
                    let split = thinkBuffer.index(thinkBuffer.startIndex, offsetBy: emitCount)
                    displayText += String(thinkBuffer[..<split])
                    thinkBuffer = String(thinkBuffer[split...])
                }
                break
            }

            if let openRange = thinkBuffer.range(of: ToolCallPattern.thinkOpen) {
                let beforeThink = String(thinkBuffer[..<openRange.lowerBound])
                if !beforeThink.isEmpty {
                    displayText += processOutsideThinking(beforeThink)
                }
                displayText += ToolCallPattern.thinkOpen
                thinkBuffer = String(thinkBuffer[openRange.upperBound...])
                inThinkBlock = true
                continue
            }

            let keep = trailingPossibleTagPrefix(in: thinkBuffer, for: ToolCallPattern.thinkOpen)
            let emitCount = max(0, thinkBuffer.count - keep.count)
            if emitCount > 0 {
                let split = thinkBuffer.index(thinkBuffer.startIndex, offsetBy: emitCount)
                displayText += processOutsideThinking(String(thinkBuffer[..<split]))
                thinkBuffer = String(thinkBuffer[split...])
            }
            break
        }

        return StreamProcessResult(displayText: displayText)
    }

    private func processOutsideThinking(_ text: String) -> String {
        var displayText = ""
        var remaining = text

        while !remaining.isEmpty {
            switch state {
            case .idle:
                if let openRange = remaining.range(of: toolCallOpen) {
                    displayText += String(remaining[..<openRange.lowerBound])
                    onStatusChange?("Generating tool call...")
                    remaining = String(remaining[openRange.upperBound...])
                    state = .accumulatingJSON(buffer: "")
                } else {
                    displayText += remaining
                    remaining = ""
                }

            case .accumulatingJSON(var buffer):
                // Check for closing tag first
                if let closeRange = remaining.range(of: toolCallClose) {
                    buffer += String(remaining[..<closeRange.lowerBound])
                    remaining = String(remaining[closeRange.upperBound...])
                    // Try to parse the JSON and handle
                    handleCompletedJSON(buffer)
                    state = .idle
                } else {
                    buffer += remaining
                    remaining = ""

                    // Check if this is a content-heavy tool call we should stream
                    if let (key, _) = detectContentField(buffer) {
                        if let (path, toolName) = extractPathAndArgs(buffer, contentKey: key) {
                            let safeName = path.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ".", with: "_")
                            let tmpFile = tmpDir.appendingPathComponent(safeName + ".tmp")
                            FileManager.default.createFile(atPath: tmpFile.path, contents: nil)
                            onStatusChange?("Writing to tmp file \(tmpFile.path)")
                            if let fh = try? FileHandle(forWritingTo: tmpFile) {
                                try? fh.truncate(atOffset: 0)
                                state = .streamingContent(
                                    jsonBuffer: buffer,
                                    path: path,
                                    toolName: toolName,
                                    contentKey: key,
                                    tmpFile: tmpFile,
                                    fileHandle: fh,
                                    inContentString: false,
                                    escapeState: .normal
                                )
                            } else {
                                failedCalls.append("write_file:\(path)")
                                state = .idle
                            }
                        } else {
                            state = .accumulatingJSON(buffer: buffer)
                        }
                    } else if buffer.count > 50000 {
                        failedCalls.append("json_too_long")
                        state = .idle
                    } else {
                        state = .accumulatingJSON(buffer: buffer)
                    }
                }

            case .streamingContent(let jsonBuffer, let path, let toolName, let contentKey, let tmpFile, let fileHandle, var inContentString, var escapeState):
                var currentBuffer = jsonBuffer
                let chars = Array(remaining)
                var i = 0

                while i < chars.count {
                    let char = chars[i]

                    // Check if we've hit the closing tag
                    let suffixFromHere = String(chars[i...])
                    if suffixFromHere.hasPrefix(toolCallClose) {
                        // Close file and finalize
                        try? fileHandle.close()
                        let otherArgs = extractOtherArgs(currentBuffer, contentKey: contentKey, path: path)
                        completedCalls.append(StreamedToolCall(
                            toolName: toolName,
                            path: path,
                            contentFile: tmpFile,
                            otherArgs: otherArgs
                        ))
                        remaining = String(chars[(i + toolCallClose.count)...])
                        state = .idle
                        break
                    }

                    currentBuffer.append(char)

                    // Track whether we're inside the content string value
                    if inContentString {
                        // A non-escaped quote closes the JSON string; do not write it.
                        if escapeState == .normal && char == "\"" {
                            inContentString = false
                            i += 1
                            continue
                        }

                        let (output, newState) = processEscapeChar(char, state: escapeState)
                        escapeState = newState
                        if let bytes = output {
                            try? fileHandle.write(contentsOf: bytes)
                        }
                    } else {
                        // Check if we just consumed the opening quote of the content string.
                        let noSpacePrefix = "\"" + contentKey + "\":\""
                        let spacePrefix = "\"" + contentKey + "\": \""
                        if currentBuffer.hasSuffix(noSpacePrefix) || currentBuffer.hasSuffix(spacePrefix) {
                            inContentString = true
                        }
                    }

                    i += 1
                }

                if state != .idle {
                    remaining = ""
                    state = .streamingContent(
                        jsonBuffer: currentBuffer,
                        path: path,
                        toolName: toolName,
                        contentKey: contentKey,
                        tmpFile: tmpFile,
                        fileHandle: fileHandle,
                        inContentString: inContentString,
                        escapeState: escapeState
                    )
                }
            }
        }

        return displayText
    }

    // MARK: - JSON handling

    private func handleCompletedJSON(_ buffer: String) {
        // Try to parse the JSON
        guard let data = buffer.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let toolName = json["name"] as? String else {
            failedCalls.append("parse_failed")
            return
        }

        let arguments = json["arguments"] as? [String: Any] ?? [:]

        // Check if this is a content-heavy tool call
        if let contentKey = detectContentField(buffer)?.key,
           let path = arguments["path"] as? String {
            // Content was streamed to tmp during generation, but we didn't catch it
            // This means the content was small enough to fit in the buffer before
            // we detected the closing tag. Parse it normally.
            let safeName = path.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ".", with: "_")
            let tmpFile = tmpDir.appendingPathComponent(safeName + ".tmp")

            if let content = arguments[contentKey] as? String {
                try? content.write(to: tmpFile, atomically: true, encoding: .utf8)
                var otherArgs = arguments
                otherArgs.removeValue(forKey: contentKey)
                completedCalls.append(StreamedToolCall(
                    toolName: toolName,
                    path: path,
                    contentFile: tmpFile,
                    otherArgs: otherArgs
                ))
            }
        }
    }

    private func extractOtherArgs(_ buffer: String, contentKey: String, path: String) -> [String: Any] {
        // Parse the JSON buffer to extract non-content arguments.
        // During streaming, models may emit slightly malformed JSON; we try
        // strict parsing first, then bounded repairs, then key recovery.
        if let arguments = extractArgumentsDict(from: buffer) {
            var otherArgs = arguments
            otherArgs.removeValue(forKey: contentKey)
            return otherArgs
        }

        // Fallback: recover key string fields that appear before the streamed content.
        // This is primarily to preserve edit_file.old_text for retry loops.
        var recovered: [String: Any] = [:]
        let beforeContent = bufferBeforeContentField(buffer, contentKey: contentKey)

        if let oldText = extractJSONStringValue(forKey: "old_text", in: beforeContent) {
            recovered["old_text"] = oldText
        } else if let oldTextAlias = ["oldText", "old", "search_text", "searchText"].compactMap({ extractJSONStringValue(forKey: $0, in: beforeContent) }).first {
            recovered["old_text"] = oldTextAlias
        }

        if let parsedPath = extractJSONStringValue(forKey: "path", in: beforeContent), !parsedPath.isEmpty {
            recovered["path"] = parsedPath
        } else {
            recovered["path"] = path
        }

        return recovered
    }

    // MARK: - Helpers

    private func trailingPossibleTagPrefix(in text: String, for tag: String) -> String {
        guard !text.isEmpty else { return "" }

        let maxPrefix = min(text.count, max(0, tag.count - 1))
        guard maxPrefix > 0 else { return "" }

        for length in stride(from: maxPrefix, through: 1, by: -1) {
            let candidate = String(text.suffix(length))
            if tag.hasPrefix(candidate) {
                return candidate
            }
        }

        return ""
    }

    private func detectContentField(_ buffer: String) -> (key: String, afterKey: String.Index)? {
        let fields = ["content", "file_content", "new_text"]
        for field in fields {
            let pattern = "\"" + field + "\":"
            if let range = buffer.range(of: pattern) {
                return (field, range.upperBound)
            }
        }
        return nil
    }

    private func extractPathAndArgs(_ buffer: String, contentKey: String) -> (path: String, toolName: String)? {
        let beforeContent = bufferBeforeContentField(buffer, contentKey: contentKey)

        var toolName: String?
        var path: String?

        let namePattern = "\"name\":\\s*\"([^\"]+)\""
        if let regex = try? NSRegularExpression(pattern: namePattern) {
            let range = NSRange(beforeContent.startIndex..., in: beforeContent)
            if let match = regex.firstMatch(in: beforeContent, range: range),
               let nameRange = Range(match.range(at: 1), in: beforeContent) {
                toolName = String(beforeContent[nameRange])
            }
        }

        let pathPattern = "\"path\":\\s*\"([^\"]+)\""
        if let regex = try? NSRegularExpression(pattern: pathPattern) {
            let range = NSRange(beforeContent.startIndex..., in: beforeContent)
            if let match = regex.firstMatch(in: beforeContent, range: range),
               let pathRange = Range(match.range(at: 1), in: beforeContent) {
                path = String(beforeContent[pathRange])
            }
        }

        guard let name = toolName, let p = path else { return nil }
        return (p, name)
    }

    private func extractArgumentsDict(from buffer: String) -> [String: Any]? {
        if let parsed = parseJSONObject(buffer),
           let arguments = parsed["arguments"] as? [String: Any] {
            return arguments
        }

        if let extracted = extractLikelyJSONObject(buffer),
           let parsed = parseJSONObject(extracted),
           let arguments = parsed["arguments"] as? [String: Any] {
            return arguments
        }

        // Try bounded repair for common malformed outputs.
        var repaired = buffer
        if let extracted = extractLikelyJSONObject(repaired) {
            repaired = extracted
        }
        repaired = repaired.replacingOccurrences(of: ",\\s*([}\\]])", with: "$1", options: .regularExpression)
        if repaired.hasPrefix("{") && !repaired.hasSuffix("}") {
            repaired += "}"
        }
        if !repaired.hasPrefix("{") {
            repaired = "{" + repaired
        }
        if !repaired.hasSuffix("}") {
            repaired += "}"
        }

        if let parsed = parseJSONObject(repaired),
           let arguments = parsed["arguments"] as? [String: Any] {
            return arguments
        }

        return nil
    }

    private func parseJSONObject(_ jsonString: String) -> [String: Any]? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func extractLikelyJSONObject(_ text: String) -> String? {
        guard let first = text.firstIndex(of: "{"),
              let last = text.lastIndex(of: "}"),
              first <= last else {
            return nil
        }

        return String(text[first...last]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func bufferBeforeContentField(_ buffer: String, contentKey: String) -> String {
        if let range = buffer.range(of: "\"" + contentKey + "\":\"") {
            return String(buffer[..<range.lowerBound])
        }
        if let range = buffer.range(of: "\"" + contentKey + "\": \"") {
            return String(buffer[..<range.lowerBound])
        }
        return buffer
    }

    private func extractJSONStringValue(forKey key: String, in text: String) -> String? {
        let pattern = "\"" + NSRegularExpression.escapedPattern(for: key) + "\"\\s*:\\s*\"((?:\\\\.|[^\"\\\\])*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }

        let encoded = String(text[valueRange])
        return decodeJSONString(encoded)
    }

    private func decodeJSONString(_ encoded: String) -> String? {
        let wrapped = "{\"v\":\"" + encoded + "\"}"
        guard let data = wrapped.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["v"] as? String else {
            return nil
        }
        return value
    }

    private func processEscapeChar(_ char: Character, state: EscapeState) -> (Data?, EscapeState) {
        switch state {
        case .normal:
            if char == "\\" {
                return (nil, .sawBackslash)
            } else {
                return (String(char).data(using: .utf8), .normal)
            }
        case .sawBackslash:
            switch char {
            case "\"": return ("\"".data(using: .utf8), .normal)
            case "\\": return ("\\".data(using: .utf8), .normal)
            case "/": return ("/".data(using: .utf8), .normal)
            case "n": return ("\n".data(using: .utf8), .normal)
            case "t": return ("\t".data(using: .utf8), .normal)
            case "r": return ("\r".data(using: .utf8), .normal)
            case "u": return (nil, .sawUnicode(prefix: ""))
            default: return (String(char).data(using: .utf8), .normal)
            }
        case .sawUnicode(let prefix):
            let newPrefix = prefix + String(char)
            if newPrefix.count == 4 {
                if let codePoint = Int(newPrefix, radix: 16),
                   let scalar = Unicode.Scalar(codePoint) {
                    let str = String(scalar)
                    return (str.data(using: .utf8), .normal)
                }
                return (nil, .normal)
            }
            return (nil, .sawUnicode(prefix: newPrefix))
        }
    }
}
