// Sources/MLXCoder/ShowConfigCommand.swift
// Show merged runtime configuration.

import ArgumentParser
import Foundation

struct ShowConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show-config",
        abstract: "Show merged runtime config from user and workspace files"
    )

    @Option(name: .long, help: "Workspace root used for resolving workspace config")
    var workspace: String = "."

    @Flag(name: .long, help: "Emit machine-readable JSON output")
    var json: Bool = false

    @OptionGroup var testAbsorber: TestAbsorber

    mutating func run() async throws {
        guard !testAbsorber.isTestInvocation else { return }

        let workspacePath = NSString(string: workspace).expandingTildeInPath
        let rawWorkspace = workspacePath.hasPrefix("/")
            ? workspacePath
            : FileManager.default.currentDirectoryPath + "/" + workspacePath
        let absWorkspace = URL(filePath: rawWorkspace).standardized.path()

        let merged = RuntimeConfigLoader.loadMerged(workspaceRoot: absWorkspace)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(merged)
        let serialized = String(decoding: data, as: UTF8.self)

        if json {
            print(serialized)
            return
        }

        print("Workspace: \(absWorkspace)")
        print("Merged runtime config:")
        print(serialized)
    }
}
