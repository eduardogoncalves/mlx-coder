// Sources/MLXCoder/ShowAuditCommand.swift
// Show recent tool audit events.

import ArgumentParser
import Foundation

struct ShowAuditCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show-audit",
        abstract: "Show recent tool audit events"
    )

    @Option(name: .long, help: "Path to audit log file")
    var path: String = "~/.mlx-coder/audit.log.jsonl"

    @Option(name: .long, help: "Number of most recent lines to print")
    var tail: Int = 50

    @OptionGroup var testAbsorber: TestAbsorber

    mutating func run() async throws {
        guard !testAbsorber.isTestInvocation else { return }

        let expandedPath = NSString(string: path).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            print("Audit log not found: \(expandedPath)")
            return
        }

        let text = try String(contentsOfFile: expandedPath, encoding: .utf8)
        let lines = text
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        let count = max(1, tail)
        let output = Array(lines.suffix(count))
        print(output.joined(separator: "\n"))
    }
}
