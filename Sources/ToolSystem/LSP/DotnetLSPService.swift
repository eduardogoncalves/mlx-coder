// Sources/ToolSystem/LSP/DotnetLSPService.swift
// Session-scoped lazy coordinator for Roslyn language server usage.

import Foundation

actor DotnetLSPService {
    static let shared = DotnetLSPService()
    // Must exceed LSP initialize/request timeouts so underlying bridge errors
    // can propagate instead of being masked by service-level timeout.
    private let operationTimeoutSeconds: Double = 75

    private let detector = DotnetWorkspaceDetector()
    private var bridge: LSPBridge?
    private var activeWorkspaceRoot: String?
    private var disabledReason: String?
    private var diagnoseCache: [String: CSharpLSDiagnoseSummary] = [:]

    private init() {}

    private struct CSharpLSDiagnoseSummary: Sendable {
        let status: String
        let failureCount: Int
        let failureLines: [String]
        let exitCode: Int
        let outputExcerpt: String

        var payload: [String: Any] {
            [
                "status": status,
                "failure_count": failureCount,
                "failure_lines": failureLines,
                "exit_code": exitCode,
                "output_excerpt": outputExcerpt,
            ]
        }
    }

    func shutdown() async {
        if let bridge {
            await bridge.shutdown()
        }
        self.bridge = nil
        self.activeWorkspaceRoot = nil
        self.disabledReason = nil
        self.diagnoseCache.removeAll()
    }

    func diagnostics(permissions: PermissionEngine, filePath: String?) async throws -> String {
        return try await withTimeout(seconds: operationTimeoutSeconds, operationName: "lsp_diagnostics") { [self] in
            let info = await detector.workspaceInfo(permissions.workspaceRoot)
            guard info.isDotnet else {
                throw LSPBridgeError.notDotnetWorkspace
            }

            let bridge = try await self.ensureBridge(workspaceRoot: permissions.workspaceRoot)

            let diagnostics: [LSPDiagnostic]
            if let filePath {
                let resolved = try permissions.validatePath(filePath)
                diagnostics = try await bridge.pullDocumentDiagnostics(filePath: resolved)
            } else {
                if await bridge.supportsWorkspaceDiagnostics() {
                    do {
                        diagnostics = try await bridge.pullWorkspaceDiagnostics()
                    } catch {
                        diagnostics = await bridge.cachedDiagnostics(filePath: nil)
                    }
                } else {
                    diagnostics = await bridge.cachedDiagnostics(filePath: nil)
                }
            }

            let rows = diagnostics.map { diagnostic in
                [
                    "file_path": self.relativizePath(diagnostic.uri, workspaceRoot: permissions.workspaceRoot),
                    "line": diagnostic.line,
                    "character": diagnostic.character,
                    "severity": diagnostic.severity as Any,
                    "code": diagnostic.code as Any,
                    "message": diagnostic.message,
                ]
            }
            let payload: [String: Any] = [
                "count": rows.count,
                "diagnostics": rows,
            ]

            let diagnoseSummary = await self.cachedDiagnoseSummary(
                workspaceRoot: permissions.workspaceRoot,
                startupTargetPath: info.startupTargetPath
            )

            var enrichedPayload = payload
            enrichedPayload["server_health"] = diagnoseSummary.payload
            return LSPResultFormatter.prettyJSON(enrichedPayload)
        }
    }

    func hover(permissions: PermissionEngine, filePath: String, line: Int, character: Int) async throws -> String {
        try await withTimeout(seconds: operationTimeoutSeconds, operationName: "lsp_hover") { [self] in
            let bridge = try await self.ensureBridge(workspaceRoot: permissions.workspaceRoot)
            let resolved = try permissions.validatePath(filePath)
            return try await bridge.hover(filePath: resolved, line: line, character: character)
        }
    }

    func references(permissions: PermissionEngine, filePath: String, line: Int, character: Int) async throws -> String {
        try await withTimeout(seconds: operationTimeoutSeconds, operationName: "lsp_references") { [self] in
            let bridge = try await self.ensureBridge(workspaceRoot: permissions.workspaceRoot)
            let resolved = try permissions.validatePath(filePath)
            let refs = try await bridge.references(filePath: resolved, line: line, character: character)

            let rows = refs.map { ref in
                [
                    "file_path": self.relativizePath(ref.uri, workspaceRoot: permissions.workspaceRoot),
                    "line": ref.line,
                    "character": ref.character,
                ]
            }
            let payload: [String: Any] = [
                "count": rows.count,
                "references": rows,
            ]
            return LSPResultFormatter.prettyJSON(payload)
        }
    }

    func definition(permissions: PermissionEngine, filePath: String, line: Int, character: Int) async throws -> String {
        try await withTimeout(seconds: operationTimeoutSeconds, operationName: "lsp_definition") { [self] in
            let bridge = try await self.ensureBridge(workspaceRoot: permissions.workspaceRoot)
            let resolved = try permissions.validatePath(filePath)
            let refs = try await bridge.definition(filePath: resolved, line: line, character: character)

            let rows = refs.map { ref in
                [
                    "file_path": self.relativizePath(ref.uri, workspaceRoot: permissions.workspaceRoot),
                    "line": ref.line,
                    "character": ref.character,
                ]
            }
            let payload: [String: Any] = [
                "count": rows.count,
                "definitions": rows,
            ]
            return LSPResultFormatter.prettyJSON(payload)
        }
    }

    func completion(permissions: PermissionEngine, filePath: String, line: Int, character: Int) async throws -> String {
        try await withTimeout(seconds: operationTimeoutSeconds, operationName: "lsp_completion") { [self] in
            let bridge = try await self.ensureBridge(workspaceRoot: permissions.workspaceRoot)
            let resolved = try permissions.validatePath(filePath)
            let raw = try await bridge.completion(filePath: resolved, line: line, character: character)

            guard let object = Self.parseJSONObject(fromJSONText: raw) else {
                return LSPResultFormatter.prettyJSON(["count": 0, "items": []])
            }

            var items: [[String: Any]] = []
            if let list = object as? [String: Any], let rawItems = list["items"] as? [[String: Any]] {
                items = rawItems
            } else if let rawItems = object as? [[String: Any]] {
                items = rawItems
            }

            let simplified = items.map { item in
                [
                    "label": item["label"] as? String ?? "",
                    "kind": item["kind"] as Any,
                    "detail": item["detail"] as Any,
                ]
            }

            let payload: [String: Any] = [
                "count": simplified.count,
                "items": simplified,
            ]
            return LSPResultFormatter.prettyJSON(payload)
        }
    }

    func signatureHelp(permissions: PermissionEngine, filePath: String, line: Int, character: Int) async throws -> String {
        try await withTimeout(seconds: operationTimeoutSeconds, operationName: "lsp_signature_help") { [self] in
            let bridge = try await self.ensureBridge(workspaceRoot: permissions.workspaceRoot)
            let resolved = try permissions.validatePath(filePath)
            let raw = try await bridge.signatureHelp(filePath: resolved, line: line, character: character)

            guard let object = Self.parseJSONObject(fromJSONText: raw) as? [String: Any] else {
                return LSPResultFormatter.prettyJSON(["count": 0, "signatures": []])
            }

            let rawSignatures = object["signatures"] as? [[String: Any]] ?? []
            let signatures = rawSignatures.map { sig in
                [
                    "label": sig["label"] as? String ?? "",
                    "documentation": sig["documentation"] as Any,
                ]
            }

            let payload: [String: Any] = [
                "count": signatures.count,
                "active_signature": object["activeSignature"] as Any,
                "active_parameter": object["activeParameter"] as Any,
                "signatures": signatures,
            ]
            return LSPResultFormatter.prettyJSON(payload)
        }
    }

    func documentSymbols(permissions: PermissionEngine, filePath: String) async throws -> String {
        try await withTimeout(seconds: operationTimeoutSeconds, operationName: "lsp_document_symbols") { [self] in
            let bridge = try await self.ensureBridge(workspaceRoot: permissions.workspaceRoot)
            let resolved = try permissions.validatePath(filePath)
            let raw = try await bridge.documentSymbols(filePath: resolved)

            guard let object = Self.parseJSONObject(fromJSONText: raw) else {
                return LSPResultFormatter.prettyJSON(["count": 0, "symbols": []])
            }

            let symbolsArray = object as? [[String: Any]] ?? []
            let symbols = symbolsArray.map { item in
                [
                    "name": item["name"] as? String ?? "",
                    "kind": item["kind"] as Any,
                    "detail": item["detail"] as Any,
                    "line": item["line"] as Any,
                    "character": item["character"] as Any,
                ]
            }

            let payload: [String: Any] = [
                "count": symbols.count,
                "symbols": symbols,
            ]
            return LSPResultFormatter.prettyJSON(payload)
        }
    }

    func rename(permissions: PermissionEngine, filePath: String, line: Int, character: Int, newName: String, apply: Bool = false) async throws -> String {
        try await withTimeout(seconds: operationTimeoutSeconds, operationName: "lsp_rename") { [self] in
            let bridge = try await self.ensureBridge(workspaceRoot: permissions.workspaceRoot)
            let resolved = try permissions.validatePath(filePath)

            var effectiveLine = line
            let effectiveCharacter = character
            var normalizedFromOneBasedLine = false

            // Validate renameability at the provided position before issuing rename.
            // This helps avoid silent zero-edit responses when the cursor is off-token.
            var prepareSupported = true
            do {
                let prepareRaw = try await bridge.prepareRename(filePath: resolved, line: effectiveLine, character: effectiveCharacter)
                if prepareRaw.trimmingCharacters(in: .whitespacesAndNewlines) == "null" {
                    // Common caller mistake: line numbers from grep/read_file are 1-based.
                    // Try line-1 once before failing fast.
                    if effectiveLine > 0 {
                        let fallbackLine = effectiveLine - 1
                        let fallbackPrepareRaw = try await bridge.prepareRename(filePath: resolved, line: fallbackLine, character: effectiveCharacter)
                        if fallbackPrepareRaw.trimmingCharacters(in: .whitespacesAndNewlines) != "null" {
                            effectiveLine = fallbackLine
                            normalizedFromOneBasedLine = true
                        } else {
                            let payload: [String: Any] = [
                                "file_count": 0,
                                "edit_count": 0,
                                "files": [],
                                "warning": "No renameable symbol at the provided position.",
                                "hint": "Use 0-based line/character on the symbol token. Run lsp_document_symbols first to get exact coordinates.",
                            ]
                            return LSPResultFormatter.prettyJSON(payload)
                        }
                    } else {
                        let payload: [String: Any] = [
                            "file_count": 0,
                            "edit_count": 0,
                            "files": [],
                            "warning": "No renameable symbol at the provided position.",
                            "hint": "Use 0-based line/character on the symbol token. Run lsp_document_symbols first to get exact coordinates.",
                        ]
                        return LSPResultFormatter.prettyJSON(payload)
                    }
                }
            } catch LSPBridgeError.responseError(let code, _) where code == -32601 {
                // Server does not implement prepareRename; proceed with rename.
                prepareSupported = false
            }

            let raw = try await bridge.rename(filePath: resolved, line: effectiveLine, character: effectiveCharacter, newName: newName)

            guard let object = Self.parseJSONObject(fromJSONText: raw) as? [String: Any] else {
                return LSPResultFormatter.prettyJSON(["file_count": 0, "edit_count": 0, "files": []])
            }

            let workspaceEdits = Self.extractWorkspaceEdits(from: object)

            var fileSummaries: [[String: Any]] = []
            var editCount = 0
            var appliedFiles = 0
            var appliedEdits = 0
            var applyErrors: [[String: Any]] = []

            for editEntry in workspaceEdits {
                let edits = editEntry.edits
                editCount += edits.count
                let relativePath = self.relativizePath(editEntry.uri, workspaceRoot: permissions.workspaceRoot)
                fileSummaries.append([
                    "file_path": relativePath,
                    "edits": edits.count,
                ])

                guard apply else {
                    continue
                }

                do {
                    let absolutePath = try permissions.validatePath(relativePath)
                    let originalText = try String(contentsOfFile: absolutePath, encoding: .utf8)
                    let updatedText = try LSPWorkspaceEditApplier.applyEdits(originalText: originalText, rawEdits: edits)
                    try updatedText.write(toFile: absolutePath, atomically: true, encoding: .utf8)
                    appliedFiles += 1
                    appliedEdits += edits.count
                } catch {
                    applyErrors.append([
                        "file_path": relativePath,
                        "error": error.localizedDescription,
                    ])
                }
            }

            var payload: [String: Any] = [
                "file_count": fileSummaries.count,
                "edit_count": editCount,
                "files": fileSummaries,
                "resolved_line": effectiveLine,
                "resolved_character": effectiveCharacter,
            ]

            if normalizedFromOneBasedLine {
                payload["note"] = "Input line looked 1-based; normalized to 0-based by subtracting 1."
            }

            if editCount == 0 {
                payload["warning"] = "Rename completed with zero edits."
                payload["hint"] = "Check 0-based line/character and place the cursor on the symbol identifier."
                if !prepareSupported {
                    payload["note"] = "prepareRename is not supported by this language server; pre-validation was skipped."
                }
            }

            if apply {
                payload["applied"] = true
                payload["applied_file_count"] = appliedFiles
                payload["applied_edit_count"] = appliedEdits
                payload["apply_error_count"] = applyErrors.count
                if !applyErrors.isEmpty {
                    payload["apply_errors"] = applyErrors
                }
            }

            return LSPResultFormatter.prettyJSON(payload)
        }
    }

    nonisolated private static func parseJSONObject(fromJSONText text: String) -> Any? {
        guard let data = text.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data)
    }

    nonisolated private static func extractWorkspaceEdits(from workspaceEdit: [String: Any]) -> [(uri: String, edits: [[String: Any]])] {
        var results: [(uri: String, edits: [[String: Any]])] = []

        if let changes = workspaceEdit["changes"] as? [String: Any] {
            for (uri, editsAny) in changes {
                let edits = editsAny as? [[String: Any]] ?? []
                results.append((uri: uri, edits: edits))
            }
        }

        if let documentChanges = workspaceEdit["documentChanges"] as? [[String: Any]] {
            for docChange in documentChanges {
                if let textDocument = docChange["textDocument"] as? [String: Any],
                   let uri = textDocument["uri"] as? String,
                   let edits = docChange["edits"] as? [[String: Any]] {
                    results.append((uri: uri, edits: edits))
                }
            }
        }

        return results
    }

    // MARK: - Private

    private func ensureBridge(workspaceRoot: String) async throws -> LSPBridge {
        if let disabledReason {
            throw LSPBridgeError.disabledForSession(disabledReason)
        }

        let info = await detector.workspaceInfo(workspaceRoot)
        guard info.isDotnet else {
            throw LSPBridgeError.notDotnetWorkspace
        }

        if activeWorkspaceRoot != workspaceRoot {
            if let bridge {
                await bridge.shutdown()
            }
            self.bridge = nil
            self.activeWorkspaceRoot = workspaceRoot
        }

        if bridge == nil {
            let newBridge = LSPBridge()
            do {
                try await newBridge.start(
                    workspacePath: URL(filePath: workspaceRoot),
                    startupTargetPath: info.startupTargetPath
                )
                bridge = newBridge
            } catch {
                // Gracefully disable LSP on startup failure
                let reason: String
                if let bridgeError = error as? LSPBridgeError, case .serverUnavailable(let msg) = bridgeError {
                    reason = "LSP disabled: \(msg)"
                } else {
                    reason = "Failed to initialize LSP bridge: \(error.localizedDescription)"
                }
                self.disabledReason = reason
                throw LSPBridgeError.disabledForSession(reason)
            }
        }

        guard let bridge else {
            throw LSPBridgeError.transportClosed
        }

        return bridge
    }

    nonisolated private func relativizePath(_ uri: String, workspaceRoot: String) -> String {
        let absolutePath = LSPResultFormatter.pathFromURI(uri)
        if absolutePath.hasPrefix(workspaceRoot + "/") {
            return String(absolutePath.dropFirst(workspaceRoot.count + 1))
        }
        return absolutePath
    }

    private func withTimeout<T: Sendable>(
        seconds: Double,
        operationName: String,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                let nanos = UInt64(seconds * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanos)
                throw LSPBridgeError.requestTimedOut(method: operationName, timeoutSeconds: seconds)
            }

            let first = try await group.next()
            group.cancelAll()

            guard let first else {
                throw LSPBridgeError.transportClosed
            }
            return first
        }
    }

    private func cachedDiagnoseSummary(workspaceRoot: String, startupTargetPath: String?) async -> CSharpLSDiagnoseSummary {
        if let cached = diagnoseCache[workspaceRoot] {
            return cached
        }

        let computed: CSharpLSDiagnoseSummary
        do {
            computed = try await runCSharpLSDiagnose(workspaceRoot: workspaceRoot, startupTargetPath: startupTargetPath)
        } catch {
            // Don't expose detailed error information - could reveal system paths or implementation details
            computed = CSharpLSDiagnoseSummary(
                status: "unavailable",
                failureCount: 0,
                failureLines: [],
                exitCode: -1,
                outputExcerpt: "Diagnostic failed"
            )
        }
        diagnoseCache[workspaceRoot] = computed
        return computed
    }

    private func runCSharpLSDiagnose(workspaceRoot: String, startupTargetPath: String?) async throws -> CSharpLSDiagnoseSummary {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        let workspaceURL = URL(filePath: workspaceRoot)
        let home = NSHomeDirectory()
        let dotnetToolBinary = URL(filePath: "\(home)/.dotnet/tools/csharp-ls")
        var args = ["--diagnose"]

        if let startupTargetPath,
           !startupTargetPath.isEmpty,
           (startupTargetPath.hasSuffix(".sln") || startupTargetPath.hasSuffix(".slnx")) {
            if startupTargetPath.hasPrefix(workspaceRoot + "/") {
                let relative = String(startupTargetPath.dropFirst(workspaceRoot.count + 1))
                args.append(contentsOf: ["--solution", relative])
            } else {
                args.append(contentsOf: ["--solution", startupTargetPath])
            }
        }

        if FileManager.default.isExecutableFile(atPath: dotnetToolBinary.path) {
            process.executableURL = dotnetToolBinary
            process.arguments = args
        } else {
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.arguments = ["csharp-ls"] + args
        }

        var env = ProcessInfo.processInfo.environment
        let dotnetToolsPath = "\(env["HOME"] ?? home)/.dotnet/tools"
        let existingPath = env["PATH"] ?? ""
        let pathParts = existingPath.split(separator: ":").map(String.init)
        if !pathParts.contains(dotnetToolsPath) {
            env["PATH"] = existingPath.isEmpty ? dotnetToolsPath : "\(existingPath):\(dotnetToolsPath)"
        }

        process.environment = env
        process.currentDirectoryURL = workspaceURL
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        let timeoutNanos: UInt64 = 30_000_000_000
        let pollIntervalNanos: UInt64 = 200_000_000
        var waitedNanos: UInt64 = 0
        while process.isRunning {
            if waitedNanos >= timeoutNanos {
                process.terminate()
                throw LSPBridgeError.serverUnavailable("csharp-ls --diagnose timed out after 30s")
            }
            try await Task.sleep(nanoseconds: pollIntervalNanos)
            waitedNanos += pollIntervalNanos
        }

        let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let combined = [stdout, stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        let allLines = combined
            .split(whereSeparator: \.isNewline)
            .map { String($0) }
        let failureLines = allLines
            .filter { $0.localizedCaseInsensitiveContains("[Failure]") }

        let maxExcerptLines = 120
        let excerpt: String
        if allLines.count > maxExcerptLines {
            let shown = allLines.prefix(maxExcerptLines).joined(separator: "\n")
            let omitted = allLines.count - maxExcerptLines
            excerpt = "\(shown)\n[... \(omitted) lines omitted ...]"
        } else {
            excerpt = combined
        }

        let status = failureLines.isEmpty ? "ok" : "failure"
        return CSharpLSDiagnoseSummary(
            status: status,
            failureCount: failureLines.count,
            failureLines: failureLines,
            exitCode: Int(process.terminationStatus),
            outputExcerpt: excerpt
        )
    }
}

enum LSPWorkspaceEditApplier {
    struct Edit {
        let startLine: Int
        let startCharacter: Int
        let endLine: Int
        let endCharacter: Int
        let newText: String
    }

    enum ApplyError: LocalizedError {
        case invalidEditPayload
        case invalidRange(line: Int, character: Int)
        case overlappingEdits

        var errorDescription: String? {
            switch self {
            case .invalidEditPayload:
                return "Invalid LSP text edit payload."
            case .invalidRange(let line, let character):
                return "Invalid LSP range position line=\(line), character=\(character)."
            case .overlappingEdits:
                return "Overlapping LSP text edits are not supported."
            }
        }
    }

    static func applyEdits(originalText: String, rawEdits: [[String: Any]]) throws -> String {
        let edits = try rawEdits.map(parseEdit)
        return try applyEdits(originalText: originalText, edits: edits)
    }

    static func applyEdits(originalText: String, edits: [Edit]) throws -> String {
        let nsText = originalText as NSString
        let lineStarts = computeLineStarts(nsText)

        var rangesWithText: [(NSRange, String)] = []
        rangesWithText.reserveCapacity(edits.count)

        for edit in edits {
            let startOffset = try offset(forLine: edit.startLine, character: edit.startCharacter, in: nsText, lineStarts: lineStarts)
            let endOffset = try offset(forLine: edit.endLine, character: edit.endCharacter, in: nsText, lineStarts: lineStarts)
            guard endOffset >= startOffset else {
                throw ApplyError.invalidRange(line: edit.endLine, character: edit.endCharacter)
            }
            rangesWithText.append((NSRange(location: startOffset, length: endOffset - startOffset), edit.newText))
        }

        let ascendingRanges = rangesWithText
            .map { $0.0 }
            .sorted(by: { $0.location < $1.location })

        if ascendingRanges.count > 1 {
            for index in 1..<ascendingRanges.count {
                let previous = ascendingRanges[index - 1]
                let current = ascendingRanges[index]
                if current.location < previous.location + previous.length {
                    throw ApplyError.overlappingEdits
                }
            }
        }

        let mutable = NSMutableString(string: originalText)
        for (range, replacement) in rangesWithText.sorted(by: { $0.0.location > $1.0.location }) {
            mutable.replaceCharacters(in: range, with: replacement)
        }
        return mutable as String
    }

    private static func parseEdit(_ raw: [String: Any]) throws -> Edit {
        guard let range = raw["range"] as? [String: Any],
              let start = range["start"] as? [String: Any],
              let end = range["end"] as? [String: Any],
              let startLine = start["line"] as? Int,
              let startCharacter = start["character"] as? Int,
              let endLine = end["line"] as? Int,
              let endCharacter = end["character"] as? Int,
              let newText = raw["newText"] as? String else {
            throw ApplyError.invalidEditPayload
        }

        return Edit(
            startLine: startLine,
            startCharacter: startCharacter,
            endLine: endLine,
            endCharacter: endCharacter,
            newText: newText
        )
    }

    private static func computeLineStarts(_ text: NSString) -> [Int] {
        if text.length == 0 {
            return [0]
        }

        var starts: [Int] = [0]
        var index = 0
        while index < text.length {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            index = lineRange.location + lineRange.length
            if index <= text.length {
                starts.append(index)
            }
        }
        return starts
    }

    private static func offset(forLine line: Int, character: Int, in text: NSString, lineStarts: [Int]) throws -> Int {
        guard line >= 0, character >= 0 else {
            throw ApplyError.invalidRange(line: line, character: character)
        }

        guard line < lineStarts.count else {
            throw ApplyError.invalidRange(line: line, character: character)
        }

        let lineStart = lineStarts[line]
        let lineEnd = (line + 1 < lineStarts.count) ? lineStarts[line + 1] : text.length
        var contentEnd = lineEnd
        while contentEnd > lineStart {
            let scalar = text.character(at: contentEnd - 1)
            if scalar == 10 || scalar == 13 { // \n or \r
                contentEnd -= 1
            } else {
                break
            }
        }

        let maxCharacter = contentEnd - lineStart
        guard character <= maxCharacter else {
            throw ApplyError.invalidRange(line: line, character: character)
        }

        return lineStart + character
    }
}
