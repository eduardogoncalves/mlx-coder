// Sources/ToolSystem/LSP/LSPFraming.swift
// Content-Length based message framing for JSON-RPC over stdio.

import Foundation

struct LSPMessageFramer {
    private var buffer = Data()

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    mutating func nextMessage() throws -> Data? {
        let crlfDelimiter = Data("\r\n\r\n".utf8)
        let lfDelimiter = Data("\n\n".utf8)
        while true {
            let delimiterInfo: (range: Range<Int>, lineSeparator: String)
            if let range = buffer.range(of: crlfDelimiter) {
                delimiterInfo = (range, "\r\n")
            } else if let range = buffer.range(of: lfDelimiter) {
                delimiterInfo = (range, "\n")
            } else {
                return nil
            }

            let headerData = buffer.subdata(in: buffer.startIndex..<delimiterInfo.range.lowerBound)
            guard let headerText = String(data: headerData, encoding: .utf8) else {
                // Non-UTF8 preamble; drop this block and keep scanning.
                buffer.removeSubrange(buffer.startIndex..<delimiterInfo.range.upperBound)
                continue
            }

            var contentLength: Int?
            for rawLine in headerText.components(separatedBy: delimiterInfo.lineSeparator) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.lowercased().hasPrefix("content-length:") {
                    let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                    contentLength = Int(value)
                    break
                }
            }

            guard let length = contentLength, length >= 0 else {
                // Some servers emit banner/log blocks on stdout. Discard the
                // non-LSP block and resync at the next header delimiter.
                buffer.removeSubrange(buffer.startIndex..<delimiterInfo.range.upperBound)
                continue
            }

            let bodyStart = delimiterInfo.range.upperBound
            let availableBody = buffer.count - bodyStart
            guard availableBody >= length else {
                return nil
            }

            let bodyEnd = bodyStart + length
            let body = buffer.subdata(in: bodyStart..<bodyEnd)
            buffer.removeSubrange(buffer.startIndex..<bodyEnd)
            return body
        }
    }
}
