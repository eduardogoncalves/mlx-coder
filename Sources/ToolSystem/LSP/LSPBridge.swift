// Sources/ToolSystem/LSP/LSPBridge.swift
// Actor-backed bridge to csharp-ls over stdio JSON-RPC.

import Foundation
import Darwin

actor LSPBridge {
    private struct EmptyCapabilities: Encodable {}

    private struct MinimalInitializeParams: Encodable {
        let processId: Int32
        let rootUri: String
        let capabilities: EmptyCapabilities
        let workspaceFolders: [LSPInitializeParams.WorkspaceFolder]?
    }

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var pendingRequests: [Int: CheckedContinuation<String, Error>] = [:]
    private var nextId: Int = 1
    private var framer = LSPMessageFramer()
    private var readerTask: Task<Void, Never>?
    private var errorReaderTask: Task<Void, Never>?
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    private var diagnosticsByURI: [String: [LSPDiagnostic]] = [:]
    private var openedDocuments: Set<String> = []
    private var rootURI: String?
    private var didInitialize = false
    private var restartCount = 0
    private var didAttemptSelfHealInstall = false
    private var isShuttingDown = false
    private var serverCapabilities: [String: Any] = [:]
    private var stderrTail = Data()
    private var stdoutTail = Data()
    private let maxStderrTailBytes = 16 * 1024
    private let maxStdoutTailBytes = 16 * 1024
    private let initializeTimeoutSeconds: Double = 60

    deinit {
        readerTask?.cancel()
        errorReaderTask?.cancel()
        process?.terminate()
    }

    func start(workspacePath: URL, startupTargetPath: String? = nil) async throws {
        let root = workspacePath.standardizedFileURL
        if let proc = process, proc.isRunning, didInitialize, rootURI == root.absoluteString {
            return
        }

        if process != nil {
            await shutdown()
        }

        isShuttingDown = false
        rootURI = root.absoluteString
        didInitialize = false
        openedDocuments.removeAll()
        diagnosticsByURI.removeAll()
        framer = LSPMessageFramer()

        let input = Pipe()
        let output = Pipe()
        let err = Pipe()
        let proc = makeServerProcess(
            workspacePath: root,
            startupTargetPath: startupTargetPath,
            input: input,
            output: output,
            error: err
        )

        do {
            try proc.run()
        } catch {
            if try await attemptSelfHealIfNeeded(reason: error.localizedDescription) {
                try await start(workspacePath: workspacePath)
                return
            }
            throw LSPBridgeError.serverUnavailable("Install with: dotnet tool install -g csharp-ls")
        }

        self.process = proc
        self.inputPipe = input
        self.outputPipe = output
        self.errorPipe = err
        stderrTail.removeAll(keepingCapacity: true)
        stdoutTail.removeAll(keepingCapacity: true)

        let readHandle = output.fileHandleForReading
        readerTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                let chunk = readHandle.availableData
                if chunk.isEmpty {
                    break
                }
                await self?.consumeIncomingChunk(chunk)
            }

            await self?.notifyTransportClosed()
        }

        let errorHandle = err.fileHandleForReading
        errorReaderTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                let chunk = errorHandle.availableData
                if chunk.isEmpty {
                    break
                }
                await self?.consumeStderrChunk(chunk)
            }
        }

        // Give the server a brief moment to fail fast if unavailable.
        try await Task.sleep(nanoseconds: 150_000_000)
        if !proc.isRunning {
            let stderrText = stderrTailText()

            if try await attemptSelfHealIfNeeded(reason: stderrText) {
                try await start(workspacePath: workspacePath)
                return
            }

            throw LSPBridgeError.serverUnavailable(
                stderrText.isEmpty
                ? "Install with: dotnet tool install -g csharp-ls"
                : stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        do {
            try await initializeHandshake(workspacePath: root)
        } catch {
            // Some workspaces stall when forcing --solution; retry once from CWD.
            if startupTargetPath != nil,
               !isInitializeTimeout(error) {
                await shutdown()
                try await start(workspacePath: root, startupTargetPath: nil)
                return
            }
            throw error
        }
    }

    func shutdown() async {
        guard process != nil else { return }
        isShuttingDown = true

        if didInitialize {
            _ = try? await sendRequest(method: "shutdown", params: Optional<String>.none, timeoutSeconds: 3)
            try? await sendNotification(method: "exit", params: Optional<String>.none)
        }

        readerTask?.cancel()
        readerTask = nil
        errorReaderTask?.cancel()
        errorReaderTask = nil

        if let proc = process, proc.isRunning {
            proc.terminate()
        }

        process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        didInitialize = false
        openedDocuments.removeAll()
        serverCapabilities.removeAll()
        stderrTail.removeAll(keepingCapacity: true)
        stdoutTail.removeAll(keepingCapacity: true)

        for (_, timeoutTask) in timeoutTasks {
            timeoutTask.cancel()
        }
        timeoutTasks.removeAll()

        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: LSPBridgeError.transportClosed)
        }
    }

    func pullDocumentDiagnostics(filePath: String) async throws -> [LSPDiagnostic] {
        let uri = fileURI(fromPath: filePath)
        try await openDocumentIfNeeded(filePath: filePath, uri: uri)

        let params = LSPDiagnosticParams(
            textDocument: .init(uri: uri),
            identifier: nil,
            previousResultId: nil
        )
        let result = try await sendRequest(method: "textDocument/diagnostic", params: params, timeoutSeconds: 8)

        if let object = parseJSONObject(fromJSONText: result) {
            if let dict = object as? [String: Any],
               let items = dict["items"] as? [[String: Any]] {
                let parsed = parseDiagnosticItems(items, defaultURI: uri)
                diagnosticsByURI[uri] = parsed
                return parsed
            }

            if let items = object as? [[String: Any]] {
                let parsed = parseDiagnosticItems(items, defaultURI: uri)
                diagnosticsByURI[uri] = parsed
                return parsed
            }
        }

        return diagnosticsByURI[uri] ?? []
    }

    func pullWorkspaceDiagnostics() async throws -> [LSPDiagnostic] {
        let params = LSPWorkspaceDiagnosticParams()
        let result = try await sendRequest(method: "workspace/diagnostic", params: params, timeoutSeconds: 8)

        var collected: [LSPDiagnostic] = []
        if let object = parseJSONObject(fromJSONText: result),
           let dict = object as? [String: Any],
           let items = dict["items"] as? [[String: Any]] {
            for item in items {
                guard let uri = item["uri"] as? String else { continue }
                let diagnostics = parseDiagnosticItems(item["items"] as? [[String: Any]] ?? [], defaultURI: uri)
                diagnosticsByURI[uri] = diagnostics
                collected.append(contentsOf: diagnostics)
            }
        }

        if !collected.isEmpty {
            return collected
        }

        return diagnosticsByURI.values.flatMap { $0 }
    }

    func cachedDiagnostics(filePath: String?) -> [LSPDiagnostic] {
        if let filePath {
            let uri = fileURI(fromPath: filePath)
            return diagnosticsByURI[uri] ?? []
        }
        return diagnosticsByURI.values.flatMap { $0 }
    }

    func hover(filePath: String, line: Int, character: Int) async throws -> String {
        let uri = fileURI(fromPath: filePath)
        try await openDocumentIfNeeded(filePath: filePath, uri: uri)

        let params = LSPTextDocumentPositionParams(
            textDocument: .init(uri: uri),
            position: .init(line: line, character: character)
        )

        let result = try await sendRequest(method: "textDocument/hover", params: params, timeoutSeconds: 60)
        return result == "null" ? "No hover information available." : result
    }

    func references(filePath: String, line: Int, character: Int) async throws -> [LSPReference] {
        let uri = fileURI(fromPath: filePath)
        try await openDocumentIfNeeded(filePath: filePath, uri: uri)

        let params = LSPReferenceParams(
            textDocument: .init(uri: uri),
            position: .init(line: line, character: character),
            context: .init(includeDeclaration: true)
        )

        let result = try await sendRequest(method: "textDocument/references", params: params, timeoutSeconds: 60)

        guard let object = parseJSONObject(fromJSONText: result),
              let locations = object as? [[String: Any]] else {
            return []
        }

        var refs: [LSPReference] = []
        for location in locations {
            guard let uriValue = location["uri"] as? String else { continue }
            let range = location["range"] as? [String: Any]
            let start = range?["start"] as? [String: Any]
            let lineValue = start?["line"] as? Int ?? 0
            let charValue = start?["character"] as? Int ?? 0
            refs.append(LSPReference(uri: uriValue, line: lineValue, character: charValue))
        }

        return refs
    }

    func definition(filePath: String, line: Int, character: Int) async throws -> [LSPReference] {
        let uri = fileURI(fromPath: filePath)
        try await openDocumentIfNeeded(filePath: filePath, uri: uri)

        let params = LSPDefinitionParams(
            textDocument: .init(uri: uri),
            position: .init(line: line, character: character)
        )

        let result = try await sendRequest(method: "textDocument/definition", params: params, timeoutSeconds: 60)

        guard let object = parseJSONObject(fromJSONText: result) else {
            return []
        }

        if let single = object as? [String: Any] {
            return parseLocations([single])
        }

        if let locations = object as? [[String: Any]] {
            return parseLocations(locations)
        }

        return []
    }

    func completion(filePath: String, line: Int, character: Int) async throws -> String {
        let uri = fileURI(fromPath: filePath)
        try await openDocumentIfNeeded(filePath: filePath, uri: uri)

        let params = LSPCompletionParams(
            textDocument: .init(uri: uri),
            position: .init(line: line, character: character)
        )

        let result = try await sendRequest(method: "textDocument/completion", params: params, timeoutSeconds: 60)
        return result == "null" ? "{}" : result
    }

    func signatureHelp(filePath: String, line: Int, character: Int) async throws -> String {
        let uri = fileURI(fromPath: filePath)
        try await openDocumentIfNeeded(filePath: filePath, uri: uri)

        let params = LSPSignatureHelpParams(
            textDocument: .init(uri: uri),
            position: .init(line: line, character: character)
        )

        let result = try await sendRequest(method: "textDocument/signatureHelp", params: params, timeoutSeconds: 60)
        return result == "null" ? "{}" : result
    }

    func documentSymbols(filePath: String) async throws -> String {
        let uri = fileURI(fromPath: filePath)
        try await openDocumentIfNeeded(filePath: filePath, uri: uri)

        let params = LSPDocumentSymbolParams(textDocument: .init(uri: uri))
        let result = try await sendRequest(method: "textDocument/documentSymbol", params: params, timeoutSeconds: 60)
        return result == "null" ? "[]" : result
    }

    func rename(filePath: String, line: Int, character: Int, newName: String) async throws -> String {
        let uri = fileURI(fromPath: filePath)
        try await openDocumentIfNeeded(filePath: filePath, uri: uri)

        let params = LSPRenameParams(
            textDocument: .init(uri: uri),
            position: .init(line: line, character: character),
            newName: newName
        )
        let result = try await sendRequest(method: "textDocument/rename", params: params, timeoutSeconds: 60)
        return result == "null" ? "{}" : result
    }

    func prepareRename(filePath: String, line: Int, character: Int) async throws -> String {
        let uri = fileURI(fromPath: filePath)
        try await openDocumentIfNeeded(filePath: filePath, uri: uri)

        let params = LSPTextDocumentPositionParams(
            textDocument: .init(uri: uri),
            position: .init(line: line, character: character)
        )
        let result = try await sendRequest(method: "textDocument/prepareRename", params: params, timeoutSeconds: 20)
        return result
    }

    func supportsWorkspaceDiagnostics() -> Bool {
        if serverCapabilities["diagnosticProvider"] != nil {
            return true
        }

        if let workspace = serverCapabilities["workspace"] as? [String: Any],
           workspace["diagnosticProvider"] != nil {
            return true
        }

        return false
    }

    // MARK: - Private

    private func initializeHandshake(workspacePath: URL) async throws {
        let params = MinimalInitializeParams(
            processId: getpid(),
            rootUri: workspacePath.absoluteString,
            capabilities: .init(),
            workspaceFolders: nil
        )

        let responseText = try await sendRequest(
            method: "initialize",
            params: params,
            timeoutSeconds: initializeTimeoutSeconds
        )
        if let object = parseJSONObject(fromJSONText: responseText),
           let responseDict = object as? [String: Any],
           let capabilitiesDict = responseDict["capabilities"] as? [String: Any] {
            serverCapabilities = capabilitiesDict
        }

        try await sendNotification(method: "initialized", params: [String: String]())
        didInitialize = true
        restartCount = 0
    }

    private func openDocumentIfNeeded(filePath: String, uri: String) async throws {
        guard !openedDocuments.contains(uri) else {
            return
        }

        let source = try String(contentsOfFile: filePath, encoding: .utf8)
        let params = LSPDidOpenTextDocumentParams(
            textDocument: .init(uri: uri, languageId: "csharp", version: 0, text: source)
        )

        try await sendNotification(method: "textDocument/didOpen", params: params)
        openedDocuments.insert(uri)
    }

    private func parseLocations(_ locations: [[String: Any]]) -> [LSPReference] {
        var refs: [LSPReference] = []
        for location in locations {
            guard let uriValue = location["uri"] as? String else { continue }
            let range = location["range"] as? [String: Any]
            let start = range?["start"] as? [String: Any]
            let lineValue = start?["line"] as? Int ?? 0
            let charValue = start?["character"] as? Int ?? 0
            refs.append(LSPReference(uri: uriValue, line: lineValue, character: charValue))
        }
        return refs
    }

    /// Send a JSON-RPC request to the language server with request-level timeout.
    ///
    /// **Timeout Architecture**:
    /// This function implements a request-level timeout using a separate timeout task.
    /// Each request gets its own timeout task that will cancel the request if no response
    /// is received within `timeoutSeconds`. This outer timeout is critical to prevent
    /// hanging requests from blocking the agent indefinitely.
    ///
    /// - Important: The timeout fires at the request level. Even if stdio reads have their own
    /// timeouts, this request timeout is the primary mechanism preventing hangs.
    /// - Note: When the request completes successfully via `consumeIncomingMessage`, the
    /// timeout task is cancelled, preventing spurious timeout errors.
    ///
    /// - Parameters:
    ///   - method: The JSON-RPC method name (e.g., "textDocument/diagnostic")
    ///   - params: The parameters object (can be nil)
    ///   - timeoutSeconds: Maximum time to wait for a response
    /// - Returns: The full response string from the server
    /// - Throws: `LSPBridgeError.requestTimedOut` if timeout expires
    private func sendRequest<T: Encodable>(method: String, params: T?, timeoutSeconds: Double) async throws -> String {
        if process == nil || !(process?.isRunning ?? false) {
            if restartCount == 0, let rootURI, let rootURL = URL(string: rootURI) {
                restartCount = 1
                try await start(workspacePath: rootURL)
            } else {
                throw LSPBridgeError.disabledForSession("csharp-ls crashed twice.")
            }
        }

        let requestId = nextId
        nextId += 1

        let paramsObject: Any
        if let params {
            paramsObject = try encodeAsJSONObject(params)
        } else {
            paramsObject = NSNull()
        }

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestId,
            "method": method,
            "params": paramsObject,
        ]

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestId] = continuation

            timeoutTasks[requestId] = Task { [weak self] in
                let nanos = UInt64(timeoutSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                await self?.timeoutRequest(id: requestId, method: method, timeoutSeconds: timeoutSeconds)
            }

            do {
                try sendRawMessage(request)
            } catch {
                timeoutTasks[requestId]?.cancel()
                timeoutTasks[requestId] = nil
                pendingRequests[requestId] = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendNotification<T: Encodable>(method: String, params: T?) async throws {
        let paramsObject: Any
        if let params {
            paramsObject = try encodeAsJSONObject(params)
        } else {
            paramsObject = NSNull()
        }

        let notification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": paramsObject,
        ]

        try sendRawMessage(notification)
    }

    private func sendRawMessage(_ object: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw LSPBridgeError.invalidResponse("Attempted to send non-JSON object")
        }
        guard let inputPipe else {
            throw LSPBridgeError.transportClosed
        }

        let body = try JSONSerialization.data(withJSONObject: object, options: [])
        let header = "Content-Length: \(body.count)\r\n\r\n"
        var packet = Data(header.utf8)
        packet.append(body)

        try inputPipe.fileHandleForWriting.write(contentsOf: packet)
    }

    private func consumeIncomingChunk(_ data: Data) async {
        stdoutTail.append(data)
        if stdoutTail.count > maxStdoutTailBytes {
            let overflow = stdoutTail.count - maxStdoutTailBytes
            stdoutTail.removeSubrange(0..<overflow)
        }

        do {
            try await handleIncomingData(data)
        } catch {
            // Invalid wire payloads are surfaced via request failures.
        }
    }

    private func notifyTransportClosed() {
        handleTransportClosed()
    }

    private func consumeStderrChunk(_ data: Data) {
        stderrTail.append(data)
        if stderrTail.count > maxStderrTailBytes {
            let overflow = stderrTail.count - maxStderrTailBytes
            stderrTail.removeSubrange(0..<overflow)
        }
    }

    private func stderrTailText() -> String {
        String(data: stderrTail, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func stdoutTailText() -> String {
        String(data: stdoutTail, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func handleIncomingData(_ data: Data) async throws {
        framer.append(data)

        while let messageData = try framer.nextMessage() {
            guard let object = try JSONSerialization.jsonObject(with: messageData) as? [String: Any] else {
                throw LSPBridgeError.invalidResponse("message body is not a JSON object")
            }

            if let method = object["method"] as? String,
               method == "textDocument/publishDiagnostics",
               let params = object["params"] as? [String: Any] {
                handlePublishDiagnostics(params)
                continue
            }

            if let idValue = object["id"] {
                guard let id = extractID(idValue) else {
                    continue
                }

                guard let continuation = pendingRequests.removeValue(forKey: id) else {
                    continue
                }
                timeoutTasks[id]?.cancel()
                timeoutTasks[id] = nil

                if let errorObject = object["error"] as? [String: Any] {
                    let code = errorObject["code"] as? Int ?? -32000
                    let message = errorObject["message"] as? String ?? "Unknown LSP error"
                    continuation.resume(throwing: LSPBridgeError.responseError(code: code, message: message))
                } else {
                    continuation.resume(returning: jsonText(fromAny: object["result"]))
                }
            }
        }
    }

    private func handlePublishDiagnostics(_ params: [String: Any]) {
        guard let uri = params["uri"] as? String else {
            return
        }

        let diagnosticsRaw = params["diagnostics"] as? [[String: Any]] ?? []
        diagnosticsByURI[uri] = parseDiagnosticItems(diagnosticsRaw, defaultURI: uri)
    }

    private func parseDiagnosticItems(_ items: [[String: Any]], defaultURI: String) -> [LSPDiagnostic] {
        var parsed: [LSPDiagnostic] = []
        parsed.reserveCapacity(items.count)

        for item in items {
            let range = item["range"] as? [String: Any]
            let start = range?["start"] as? [String: Any]

            let line = start?["line"] as? Int ?? 0
            let character = start?["character"] as? Int ?? 0
            let message = item["message"] as? String ?? ""
            let severity = item["severity"] as? Int

            let codeString: String?
            if let code = item["code"] as? String {
                codeString = code
            } else if let code = item["code"] as? Int {
                codeString = String(code)
            } else {
                codeString = nil
            }

            parsed.append(
                LSPDiagnostic(
                    uri: defaultURI,
                    code: codeString,
                    severity: severity,
                    message: message,
                    line: line,
                    character: character
                )
            )
        }

        return parsed
    }

    private func encodeAsJSONObject<T: Encodable>(_ value: T) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [])
    }

    private func extractID(_ value: Any) -> Int? {
        if let intID = value as? Int {
            return intID
        }
        if let strID = value as? String, let intID = Int(strID) {
            return intID
        }
        return nil
    }

    private func timeoutRequest(id: Int, method: String, timeoutSeconds: Double) {
        guard let continuation = pendingRequests.removeValue(forKey: id) else {
            return
        }
        timeoutTasks[id] = nil
        if method == "initialize" {
            let stderr = stderrTailText()
            if !stderr.isEmpty {
                let suffix = stderr.count > 600 ? String(stderr.suffix(600)) : stderr
                continuation.resume(
                    throwing: LSPBridgeError.serverUnavailable(
                        "initialize timed out after \(Int(timeoutSeconds))s. csharp-ls stderr tail: \(suffix)"
                    )
                )
                return
            }

            let stdout = stdoutTailText()
            if !stdout.isEmpty {
                let suffix = stdout.count > 600 ? String(stdout.suffix(600)) : stdout
                continuation.resume(
                    throwing: LSPBridgeError.serverUnavailable(
                        "initialize timed out after \(Int(timeoutSeconds))s. csharp-ls stdout tail: \(suffix)"
                    )
                )
                return
            }
        }

        continuation.resume(throwing: LSPBridgeError.requestTimedOut(method: method, timeoutSeconds: timeoutSeconds))
    }

    private func handleTransportClosed() {
        guard !isShuttingDown else {
            return
        }

        let pending = pendingRequests
        pendingRequests.removeAll()

        for (id, continuation) in pending {
            timeoutTasks[id]?.cancel()
            timeoutTasks[id] = nil
            continuation.resume(throwing: LSPBridgeError.transportClosed)
        }
    }

    private func isInitializeTimeout(_ error: Error) -> Bool {
        guard case let LSPBridgeError.requestTimedOut(method, _) = error else {
            return false
        }
        return method == "initialize"
    }

    private func fileURI(fromPath path: String) -> String {
        URL(filePath: path).standardizedFileURL.absoluteString
    }

    private func parseJSONObject(fromJSONText text: String) -> Any? {
        guard let data = text.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data, options: [])
    }

    private func jsonText(fromAny value: Any?) -> String {
        guard let value else {
            return "null"
        }

        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }

        if let stringValue = value as? String {
            return stringValue
        }

        return String(describing: value)
    }

    private func makeServerProcess(
        workspacePath: URL,
        startupTargetPath: String?,
        input: Pipe,
        output: Pipe,
        error: Pipe
    ) -> Process {
        let process = Process()

        let home = NSHomeDirectory()
        let dotnetToolBinary = URL(filePath: "\(home)/.dotnet/tools/csharp-ls")
        var csharpArguments = ["--loglevel", "warning"]

          if let startupTargetPath,
              !startupTargetPath.isEmpty,
              (startupTargetPath.hasSuffix(".sln") || startupTargetPath.hasSuffix(".slnx")) {
            let rootPath = workspacePath.path
            if startupTargetPath.hasPrefix(rootPath + "/") {
                let relative = String(startupTargetPath.dropFirst(rootPath.count + 1))
                csharpArguments.append(contentsOf: ["--solution", relative])
            } else {
                csharpArguments.append(contentsOf: ["--solution", startupTargetPath])
            }
        }

        // Check if CSHARP_LS_PATH env var provides a custom binary path
        if let customPath = ProcessInfo.processInfo.environment["CSHARP_LS_PATH"],
           FileManager.default.isExecutableFile(atPath: customPath) {
            process.executableURL = URL(filePath: customPath)
            process.arguments = csharpArguments
        } else if FileManager.default.isExecutableFile(atPath: dotnetToolBinary.path) {
            process.executableURL = dotnetToolBinary
            process.arguments = csharpArguments
        } else {
            process.executableURL = URL(filePath: "/usr/bin/env")
            process.arguments = ["csharp-ls"] + csharpArguments
        }

        process.currentDirectoryURL = workspacePath
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        var environment = ProcessInfo.processInfo.environment
        let homeFromEnv = environment["HOME"] ?? home
        let dotnetToolsPath = "\(homeFromEnv)/.dotnet/tools"
        let existingPath = environment["PATH"] ?? ""

        let pathParts = existingPath.split(separator: ":").map(String.init)
        if !pathParts.contains(dotnetToolsPath) {
            environment["PATH"] = existingPath.isEmpty ? dotnetToolsPath : "\(existingPath):\(dotnetToolsPath)"
        }

        process.environment = environment
        return process
    }

    private func attemptSelfHealIfNeeded(reason: String) async throws -> Bool {
        // Don't self-heal if NATIVE_AGENT_LSP_DISABLED is set
        if ProcessInfo.processInfo.environment["NATIVE_AGENT_LSP_DISABLED"] == "1" {
            return false
        }
        
        guard !didAttemptSelfHealInstall else {
            return false
        }

        let lower = reason.lowercased()
        let indicatesMissingBinary = lower.contains("csharp-ls") && (
            lower.contains("no such file") ||
            lower.contains("not found") ||
            lower.contains("file doesn't exist") ||
            lower.contains("does not exist")
        )

        guard indicatesMissingBinary else {
            return false
        }

        didAttemptSelfHealInstall = true
        try await runSelfHealInstallCommands()
        return true
    }

    private func runSelfHealInstallCommands() async throws {
        // In restricted sandboxes dotnet may be unavailable even when host has it.
        // Skip self-heal with a clear message so caller can degrade gracefully.
        let checkDotnetProcess = Process()
        checkDotnetProcess.executableURL = URL(filePath: "/usr/bin/env")
        checkDotnetProcess.arguments = ["which", "dotnet"]
        let devNull = FileHandle.nullDevice
        checkDotnetProcess.standardOutput = devNull
        checkDotnetProcess.standardError = devNull

        do {
            try checkDotnetProcess.run()
            checkDotnetProcess.waitUntilExit()
            if checkDotnetProcess.terminationStatus != 0 {
                throw LSPBridgeError.serverUnavailable(
                    "dotnet CLI not available in sandbox. Set CSHARP_LS_PATH=/path/to/csharp-ls or NATIVE_AGENT_LSP_DISABLED=1 to skip LSP"
                )
            }
        } catch {
            throw LSPBridgeError.serverUnavailable(
                "dotnet CLI not available in sandbox. Set CSHARP_LS_PATH=/path/to/csharp-ls or NATIVE_AGENT_LSP_DISABLED=1 to skip LSP"
            )
        }

        let process = Process()
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = [
            "-lc",
            "dotnet tool install --global csharp-ls",
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        let timeoutNanos: UInt64 = 45_000_000_000
        let pollIntervalNanos: UInt64 = 200_000_000
        var waitedNanos: UInt64 = 0
        while process.isRunning {
            if waitedNanos >= timeoutNanos {
                process.terminate()
                throw LSPBridgeError.serverUnavailable(
                    "Self-heal timed out while installing csharp-ls. Run manually: dotnet tool install --global csharp-ls"
                )
            }
            try await Task.sleep(nanoseconds: pollIntervalNanos)
            waitedNanos += pollIntervalNanos
        }

        if process.terminationStatus != 0 {
            let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let combined = (stdout + "\n" + stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw LSPBridgeError.serverUnavailable(
                combined.isEmpty
                ? "Self-heal failed while installing csharp-ls."
                : "Self-heal failed while installing csharp-ls: \(combined)"
            )
        }
    }
}
