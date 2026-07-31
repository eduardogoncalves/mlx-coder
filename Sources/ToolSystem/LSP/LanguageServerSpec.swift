// Sources/ToolSystem/LSP/LanguageServerSpec.swift
// Per-language LSP server launch spec (plan §13.1) — the data half of
// `LanguageServerRegistry`'s "+ later LSP spec" column (§3 module table,
// Phase B). Phase C wires this into a generalized `LSPBridge.makeServerProcess`
// (today hardcoded to csharp-ls) and `SemanticEdgeEnricher`; Phase B only
// needs the data shape to exist so `LanguageServerRegistry` can carry it.

import Foundation

/// Everything needed to launch and identify a language server, generalized
/// from the csharp-ls-specific logic in `LSPBridge.makeServerProcess`.
public struct LSPServerSpec: Sendable, Equatable {
    /// LSP `textDocument/didOpen` `languageId` (e.g. "csharp", "swift", "typescript").
    public let languageId: String
    /// Preferred executable name, resolved against `PATH` (and any
    /// language-specific well-known install locations — see
    /// `LSPBridge.makeServerProcess` for the csharp-ls precedent of checking
    /// `~/.dotnet/tools` first).
    public let executableName: String
    /// Extra fixed arguments always passed to the server.
    public let arguments: [String]
    /// Human-readable install instructions surfaced when the binary can't be
    /// found (mirrors `LSPBridgeError.serverUnavailable`'s existing csharp-ls
    /// message).
    public let installHint: String

    public init(languageId: String, executableName: String, arguments: [String] = [], installHint: String) {
        self.languageId = languageId
        self.executableName = executableName
        self.arguments = arguments
        self.installHint = installHint
    }

    public static let csharpLS = LSPServerSpec(
        languageId: "csharp",
        executableName: "csharp-ls",
        arguments: ["--loglevel", "warning"],
        installHint: "Install with: dotnet tool install -g csharp-ls"
    )

    public static let sourcekitLSP = LSPServerSpec(
        languageId: "swift",
        executableName: "sourcekit-lsp",
        installHint: "Install with Xcode / Swift toolchain (bundled as `sourcekit-lsp`); ensure it's on PATH."
    )

    public static let typescriptLanguageServer = LSPServerSpec(
        languageId: "typescript",
        executableName: "typescript-language-server",
        arguments: ["--stdio"],
        installHint: "Install with: npm install -g typescript-language-server typescript"
    )
}
