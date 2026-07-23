import Foundation

/// Detects build errors by running actual build tools
/// Fallback strategy when LSP is unavailable
public actor BuildToolErrorDetector {
    private let timeout: TimeInterval
    
    public init(timeout: TimeInterval = 60.0) {
        self.timeout = timeout
    }
    
    /// Run build check using the appropriate tool for the project type
    public func detect(
        workspace: String,
        projectInfo: ProjectInfo
    ) async -> BuildCheckResult {
        let startTime = Date()
        
        do {
            let errors: [BuildError]
            
            switch projectInfo.type {
            case .dotnet:
                errors = try await detectDotnet(workspace: workspace, projectInfo: projectInfo)
            case .nodejs:
                errors = try await detectNodejs(workspace: workspace, projectInfo: projectInfo)
            case .go:
                errors = try await detectGo(workspace: workspace, projectInfo: projectInfo)
            case .rust:
                errors = try await detectRust(workspace: workspace, projectInfo: projectInfo)
            case .python:
                errors = try await detectPython(workspace: workspace, projectInfo: projectInfo)
            case .unknown:
                return .error(message: "Unknown project type", tool: "unknown", duration: Date().timeIntervalSince(startTime))
            }
            
            let hasErrors = !errors.isEmpty
            let duration = Date().timeIntervalSince(startTime)
            
            return BuildCheckResult(
                hasErrors: hasErrors,
                errors: errors,
                warnings: [],
                tool: projectInfo.buildTool,
                duration: duration,
                usedLSP: false
            )
        } catch {
            let duration = Date().timeIntervalSince(startTime)
            return .error(
                message: "Build check failed: \(error.localizedDescription)",
                tool: projectInfo.buildTool,
                duration: duration
            )
        }
    }
    
    // MARK: - .NET Detection
    
    private func detectDotnet(workspace: String, projectInfo: ProjectInfo) async throws -> [BuildError] {
        // Find the project or solution file
        let targetFile = projectInfo.mainProjectFilePath ?? workspace
        
        let process = Process()
        process.executableURL = try getExecutableURL(for: "dotnet")
        process.arguments = [
            "build",
            targetFile,
            "--no-restore",
            "--verbosity", "minimal",
            "--nologo"
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: projectInfo.buildWorkingDirectory)
        
        let (output, _) = try runProcess(process)
        
        // Parse .NET build output for errors
        return parseNetErrors(output)
    }
    
    private func detectNodejs(workspace: String, projectInfo: ProjectInfo) async throws -> [BuildError] {
        // Check for build script in package.json
        let process = Process()
        
        let npmBinary = try findNodePackageManager(in: projectInfo.buildWorkingDirectory)
        process.executableURL = try getExecutableURL(for: npmBinary)
        
        if npmBinary == "npm" {
            process.arguments = ["run", "build", "--", "--json"]
        } else if npmBinary == "yarn" {
            process.arguments = ["build"]
        } else { // pnpm
            process.arguments = ["build"]
        }
        
        process.currentDirectoryURL = URL(fileURLWithPath: projectInfo.buildWorkingDirectory)
        
        // This might fail, which is expected if build fails
        let (output, _) = try runProcess(process, allowNonZeroExit: true)
        
        return parseNodeErrors(output)
    }
    
    private func detectGo(workspace: String, projectInfo: ProjectInfo) async throws -> [BuildError] {
        let process = Process()
        process.executableURL = try getExecutableURL(for: "go")
        process.arguments = ["build", "./..."]
        process.currentDirectoryURL = URL(fileURLWithPath: projectInfo.buildWorkingDirectory)
        
        let (_, errors) = try runProcess(process, allowNonZeroExit: true)
        
        return parseGoErrors(errors)
    }
    
    private func detectRust(workspace: String, projectInfo: ProjectInfo) async throws -> [BuildError] {
        let process = Process()
        process.executableURL = try getExecutableURL(for: "cargo")
        process.arguments = ["check", "--message-format", "json"]
        process.currentDirectoryURL = URL(fileURLWithPath: projectInfo.buildWorkingDirectory)
        
        let (output, _) = try runProcess(process, allowNonZeroExit: true)
        
        return parseRustErrors(output)
    }
    
    private func detectPython(workspace: String, projectInfo: ProjectInfo) async throws -> [BuildError] {
        // Python doesn't have a traditional build, but we can check syntax
        let process = Process()
        process.executableURL = try getExecutableURL(for: "python3")
        process.arguments = ["-m", "py_compile", "."]
        process.currentDirectoryURL = URL(fileURLWithPath: projectInfo.buildWorkingDirectory)
        
        let (_, errors) = try runProcess(process, allowNonZeroExit: true)
        
        return parsePythonErrors(errors)
    }
    
    // MARK: - Error Parsing
    
    private func parseNetErrors(_ output: String) -> [BuildError] {
        var errors: [BuildError] = []
        
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for line in lines {
            // .NET format: file.cs(line,col): error|warning CODE: message
            // Example: src/Program.cs(42,34): error CS1002: ; expected
            let pattern = #"(.+?)\((\d+),(\d+)\):\s*(error|warning)\s*([A-Z]+\d+)?:?\s*(.+?)$"#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                
                if let fileRange = Range(match.range(at: 1), in: line),
                   let lineRange = Range(match.range(at: 2), in: line),
                   let colRange = Range(match.range(at: 3), in: line),
                   let severityRange = Range(match.range(at: 4), in: line),
                   let messageRange = Range(match.range(at: 6), in: line) {
                    
                    let file = String(line[fileRange])
                    let lineNum = Int(line[lineRange]) ?? 0
                    let col = Int(line[colRange]) ?? 0
                    let severity = String(line[severityRange]) == "error" ? ErrorSeverity.error : .warning
                    let message = String(line[messageRange])
                    let code = match.range(at: 5).location != NSNotFound ? String(line[Range(match.range(at: 5), in: line)!]) : nil
                    
                    errors.append(BuildError(
                        file: file,
                        line: lineNum,
                        column: col,
                        message: message,
                        code: code,
                        severity: severity
                    ))
                }
            }
        }
        
        return errors
    }
    
    private func parseNodeErrors(_ output: String) -> [BuildError] {
        var errors: [BuildError] = []
        
        // Try parsing JSON output first (npm with --json flag)
        if output.contains("\"errors\"") || output.contains("\"message\"") {
            if let data = output.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorList = json["errors"] as? [[String: Any]] {
                
                for errorObj in errorList {
                    if let file = errorObj["file"] as? String,
                       let line = errorObj["line"] as? Int,
                       let message = errorObj["message"] as? String {
                        errors.append(BuildError(
                            file: file,
                            line: line,
                            message: message
                        ))
                    }
                }
            }
        } else {
            // Fallback to text parsing for common errors
            let lines = output.split(separator: "\n").map(String.init)
            for line in lines {
                // Look for "ERROR in" or "ERROR" patterns in webpack-style output
                if line.contains("ERROR") || line.contains("error TS") {
                    errors.append(BuildError(
                        file: "unknown",
                        line: 1,
                        message: line
                    ))
                }
            }
        }
        
        return errors
    }
    
    private func parseGoErrors(_ stderr: String) -> [BuildError] {
        var errors: [BuildError] = []
        
        // Go format: ./main.go:10:2: undefined: x
        let pattern = #"^(\.?/?.+?):(\d+):(\d+):\s*(.+?)$"#
        
        let lines = stderr.split(separator: "\n").map(String.init)
        for line in lines {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                
                if let fileRange = Range(match.range(at: 1), in: line),
                   let lineRange = Range(match.range(at: 2), in: line),
                   let colRange = Range(match.range(at: 3), in: line),
                   let msgRange = Range(match.range(at: 4), in: line) {
                    
                    errors.append(BuildError(
                        file: String(line[fileRange]),
                        line: Int(line[lineRange]) ?? 0,
                        column: Int(line[colRange]) ?? 0,
                        message: String(line[msgRange])
                    ))
                }
            }
        }
        
        return errors
    }
    
    private func parseRustErrors(_ jsonLines: String) -> [BuildError] {
        var errors: [BuildError] = []
        
        // Rust outputs JSON, one object per line
        let lines = jsonLines.split(separator: "\n").map(String.init)
        
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = json["message"] as? [String: Any] else {
                continue
            }
            
            if let level = message["level"] as? String,
               level == "error" || level == "warning",
               let text = message["message"] as? String,
               let spans = message["spans"] as? [[String: Any]],
               let span = spans.first,
               let file = span["file_name"] as? String,
               let lineNum = span["line_start"] as? Int,
               let col = span["column_start"] as? Int {
                
                errors.append(BuildError(
                    file: file,
                    line: lineNum,
                    column: col,
                    message: text,
                    severity: level == "error" ? .error : .warning
                ))
            }
        }
        
        return errors
    }
    
    private func parsePythonErrors(_ stderr: String) -> [BuildError] {
        var errors: [BuildError] = []
        
        // Python format: File "file.py", line 42, in <module>
        let pattern = #"File "(.+?)", line (\d+)"#
        
        let lines = stderr.split(separator: "\n").map(String.init)
        var i = 0
        
        while i < lines.count {
            let line = lines[i]
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                
                if let fileRange = Range(match.range(at: 1), in: line),
                   let lineRange = Range(match.range(at: 2), in: line) {
                    
                    let file = String(line[fileRange])
                    let lineNum = Int(line[lineRange]) ?? 0
                    
                    // Next line usually contains the error message
                    var message = ""
                    if i + 1 < lines.count {
                        message = lines[i + 1]
                    }
                    
                    errors.append(BuildError(
                        file: file,
                        line: lineNum,
                        message: message
                    ))
                }
            }
            i += 1
        }
        
        return errors
    }
    
    // MARK: - Utilities
    
    private func runProcess(_ process: Process, allowNonZeroExit: Bool = false) throws -> (stdout: String, stderr: String) {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Install readability handlers BEFORE the child starts so it can
        // produce output of arbitrary size without blocking on the pipe.
        // Without this, `swift build` / `tsc` / `cargo` output (frequently
        // hundreds of KiB of warnings) overflows the kernel pipe buffer and
        // wedges the loop below forever.
        let collector = PipeOutputCollector()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            collector.appendStdout(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            collector.appendStderr(data)
        }

        try process.run()

        // Cooperative timeout: poll until the deadline. `terminate()` is a
        // no-op if the child has already exited, so we don't need an
        // `isRunning` TOCTOU check around it.
        let stopDate = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < stopDate {
            usleep(100_000) // 100ms
        }

        if process.isRunning {
            process.terminate()
            // Wait for terminate to take effect so the handlers settle and
            // we don't leak a still-running child past this scope.
            process.waitUntilExit()
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw NSError(domain: "BuildToolErrorDetector", code: -1, userInfo: [NSLocalizedDescriptionKey: "Build check timed out"])
        }

        // Make sure we have collected all bytes the child emitted before we
        // read termination status. Uses a non-blocking read (see
        // `ProcessIO.nonBlockingDrain`) — a detached grandchild (e.g. an
        // MSBuild node-reuse worker) can still hold the pipe's write end
        // open after `waitUntilExit` returns, and a blocking `.availableData`
        // read here would then hang forever.
        process.waitUntilExit()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let tailOut = ProcessIO.nonBlockingDrain(stdoutPipe.fileHandleForReading)
        let tailErr = ProcessIO.nonBlockingDrain(stderrPipe.fileHandleForReading)
        if !tailOut.isEmpty { collector.appendStdout(tailOut) }
        if !tailErr.isEmpty { collector.appendStderr(tailErr) }

        let stdout = String(data: collector.stdoutSnapshot(), encoding: .utf8) ?? ""
        let stderr = String(data: collector.stderrSnapshot(), encoding: .utf8) ?? ""

        if !allowNonZeroExit && process.terminationStatus != 0 {
            // Include both stdout and stderr in the diagnostic — many build
            // tools (e.g. `swift build`, `tsc`) write errors to stdout, not
            // stderr, so dropping stdout here would lose the actual error
            // text the caller needs to surface.
            let combined: String
            if stdout.isEmpty {
                combined = stderr
            } else if stderr.isEmpty {
                combined = stdout
            } else {
                combined = "\(stdout)\n[stderr]\n\(stderr)"
            }
            throw NSError(domain: "BuildToolErrorDetector", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: combined])
        }

        return (stdout, stderr)
    }
    
    private func getExecutableURL(for binary: String) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [binary]

        // `which` output is small but using the shared helper keeps the
        // pattern uniform and removes another deadlock-prone call site.
        let (stdout, _) = try ProcessIO.runCapturing(process)
        let path = stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !path.isEmpty else {
            throw NSError(domain: "BuildToolErrorDetector", code: -1, userInfo: [NSLocalizedDescriptionKey: "\(binary) not found in PATH"])
        }

        return URL(fileURLWithPath: path)
    }
    
    private func findNodePackageManager(in workspace: String) throws -> String {
        let fileManager = FileManager.default
        
        // Check for yarn.lock
        if fileManager.fileExists(atPath: (workspace as NSString).appendingPathComponent("yarn.lock")) {
            return "yarn"
        }
        
        // Check for pnpm-lock.yaml
        if fileManager.fileExists(atPath: (workspace as NSString).appendingPathComponent("pnpm-lock.yaml")) {
            return "pnpm"
        }
        
        // Default to npm
        return "npm"
    }
}
