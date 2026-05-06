import Foundation

struct StreamingMarkdownTableNormalizer {
    private var carry: String = ""
    private var pending: [String] = []
    private var tableRows: [[String]] = []
    private var inTable = false
    private var inFenceBlock = false

    mutating func consume(_ chunk: String) -> String {
        guard !chunk.isEmpty else { return "" }
        carry += chunk
        var output = ""

        while let newlineRange = carry.range(of: "\n") {
            let line = String(carry[..<newlineRange.lowerBound])
            carry.removeSubrange(carry.startIndex...newlineRange.lowerBound)
            output += handleCompleteLine(line)
        }

        return output
    }

    mutating func finish() -> String {
        var output = ""
        if !carry.isEmpty {
            pending.append(carry)
            carry = ""
        }
        output += flushPending(finalFlush: true)
        return output
    }

    mutating func reset() {
        carry = ""
        pending = []
        tableRows = []
        inTable = false
        inFenceBlock = false
    }

    private mutating func handleCompleteLine(_ line: String) -> String {
        var output = ""
        if inTable {
            if isTableRow(line) {
                tableRows.append(parseTableRow(line))
            } else {
                output += renderTable(tableRows) + "\n"
                tableRows = []
                inTable = false
                pending.append(line)
                output += flushPending(finalFlush: false)
            }
            return output
        }

        pending.append(line)
        output += flushPending(finalFlush: false)
        return output
    }

    private mutating func flushPending(finalFlush: Bool) -> String {
        var output = ""

        while !pending.isEmpty {
            let first = pending[0]

            if isFenceDelimiter(first) {
                if inTable {
                    output += renderTable(tableRows) + "\n"
                    tableRows = []
                    inTable = false
                    continue
                }
                inFenceBlock.toggle()
                output += pending.removeFirst() + "\n"
                continue
            }

            if inFenceBlock {
                output += pending.removeFirst() + "\n"
                continue
            }

            if inTable {
                if isTableRow(first) {
                    tableRows.append(parseTableRow(first))
                    pending.removeFirst()
                    continue
                } else {
                    output += renderTable(tableRows) + "\n"
                    tableRows = []
                    inTable = false
                    continue
                }
            }

            if isTableRow(first) {
                if pending.count < 2 && !finalFlush {
                    break
                }
                let header = parseTableRow(pending[0])
                if pending.count >= 2 && isTableSeparator(pending[1], expectedColumnCount: header.count) {
                    tableRows = [parseTableRow(pending[0])]
                    pending.removeFirst(2)
                    inTable = true
                    continue
                }
            }

            output += pending.removeFirst() + "\n"
        }

        if finalFlush {
            if inTable {
                output += renderTable(tableRows)
                inTable = false
                tableRows = []
            }
            while !pending.isEmpty {
                output += (output.isEmpty ? "" : "\n") + pending.removeFirst()
            }
        }

        return output
    }

    private func isTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        guard !isFenceDelimiter(trimmed) else { return false }
        let segments = splitTableSegments(trimmed)
        return segments.count >= 2
    }

    private func isTableSeparator(_ line: String, expectedColumnCount: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        guard !isFenceDelimiter(trimmed) else { return false }
        let parts = splitTableSegments(trimmed)
        guard !parts.isEmpty else { return false }
        if expectedColumnCount > 0 && parts.count != expectedColumnCount {
            return false
        }
        for rawPart in parts {
            var part = rawPart.trimmingCharacters(in: .whitespaces)
            guard !part.isEmpty else { return false }
            while part.hasPrefix(":") { part.removeFirst() }
            while part.hasSuffix(":") { part.removeLast() }
            guard part.count >= 3, part.allSatisfy({ $0 == "-" }) else { return false }
        }
        return true
    }

    private func parseTableRow(_ line: String) -> [String] {
        return splitTableSegments(line).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func splitTableSegments(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    }

    private func isFenceDelimiter(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    private func renderTable(_ rows: [[String]]) -> String {
        guard !rows.isEmpty else { return "" }
        let header = rows[0]
        let body = Array(rows.dropFirst())
        let colCount = max(header.count, body.map(\.count).max() ?? 0)
        guard colCount > 0 else { return "" }

        var widths = Array(repeating: 0, count: colCount)
        for row in rows {
            for i in 0..<colCount {
                let value = i < row.count ? row[i] : ""
                widths[i] = max(widths[i], value.count)
            }
        }

        func separator() -> String {
            var line = "+"
            for i in 0..<colCount {
                line += String(repeating: "-", count: widths[i] + 2)
                line += (i < colCount - 1) ? "+" : "+"
            }
            return line
        }

        func rowLine(_ row: [String]) -> String {
            var line = "|"
            for i in 0..<colCount {
                let value = i < row.count ? row[i] : ""
                let pad = String(repeating: " ", count: max(0, widths[i] - value.count))
                line += " \(value)\(pad) |"
            }
            return line
        }

        var out: [String] = []
        out.append(separator())
        out.append(rowLine(header))
        out.append(separator())
        for row in body {
            out.append(rowLine(row))
        }
        out.append(separator())
        return out.joined(separator: "\n")
    }
}
