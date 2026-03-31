// Sources/ToolSystem/MCP/MCPClient.swift
// Model Context Protocol client (HTTP JSON-RPC foundation)

import Foundation

/// MCP client for connecting to MCP servers and registering their tools.
public struct MCPClient: Sendable {

    /// An MCP server connection configuration.
    public struct ServerConfig: Sendable {
        public let name: String
        public let command: String
        public let arguments: [String]
        public let environment: [String: String]
        public let endpointURL: String?
        public let timeoutSeconds: Int

        public init(
            name: String,
            command: String,
            arguments: [String] = [],
            environment: [String: String] = [:],
            endpointURL: String? = nil,
            timeoutSeconds: Int = 30
        ) {
            self.name = name
            self.command = command
            self.arguments = arguments
            self.environment = environment
            self.endpointURL = endpointURL
            self.timeoutSeconds = timeoutSeconds
        }
    }

    public enum Error: LocalizedError {
        case unsupportedTransport(configName: String)
        case invalidEndpoint(String)
        case invalidResponse(String)
        case rpcFailure(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedTransport(let configName):
                return "MCP server '\(configName)' is not configured with an HTTP endpoint or stdio command"
            case .invalidEndpoint(let endpoint):
                return "Invalid MCP endpoint URL: \(endpoint)"
            case .invalidResponse(let details):
                return "Invalid MCP response: \(details)"
            case .rpcFailure(let details):
                return "MCP RPC request failed: \(details)"
            }
        }
    }

    /// Connect to an MCP server and discover its tools.
    /// - Returns: Array of tools exposed by the server
    public static func connect(to config: ServerConfig) async throws -> [any Tool] {
        let listedTools = try await listTools(config: config)
        return listedTools.map { MCPRemoteTool(config: config, definition: $0) }
    }

    // MARK: - Private

    private struct MCPToolDefinition: Sendable {
        let name: String
        let description: String
        let inputSchema: JSONSchema
    }

    private enum Transport {
        case http(URL)
        case stdio
    }

    private struct MCPMessageFramer {
        private var buffer = Data()

        mutating func append(_ data: Data) {
            buffer.append(data)
        }

        mutating func nextMessage() -> Data? {
            let delimiter = Data("\r\n\r\n".utf8)
            guard let headerRange = buffer.range(of: delimiter) else {
                return nil
            }

            let headerData = buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound)
            guard let headerText = String(data: headerData, encoding: .utf8) else {
                buffer.removeSubrange(buffer.startIndex..<headerRange.upperBound)
                return nil
            }

            var contentLength: Int?
            for rawLine in headerText.components(separatedBy: "\r\n") {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.lowercased().hasPrefix("content-length:") {
                    let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                    contentLength = Int(value)
                    break
                }
            }

            guard let length = contentLength, length >= 0 else {
                buffer.removeSubrange(buffer.startIndex..<headerRange.upperBound)
                return nil
            }

            let bodyStart = headerRange.upperBound
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

    private struct MCPRemoteTool: Tool {
        let config: ServerConfig
        let definition: MCPToolDefinition

        var name: String { "mcp_\(config.name)_\(definition.name)" }
        var description: String { "[MCP:\(config.name)] \(definition.description)" }
        var parameters: JSONSchema { definition.inputSchema }

        func execute(arguments: [String : Any]) async throws -> ToolResult {
            let params: [String: Any] = [
                "name": definition.name,
                "arguments": arguments
            ]

            let response = try await rpcRequest(config: config, method: "tools/call", params: params)
            return formatToolCallResponse(response)
        }
    }

    private static func formatToolCallResponse(_ response: [String: Any]) -> ToolResult {
        guard let result = response["result"] as? [String: Any] else {
            if let error = response["error"] as? [String: Any] {
                return .error("MCP error: \(error)")
            }
            return .error("MCP call did not include a result")
        }

        if let isError = result["isError"] as? Bool, isError {
            return .error("MCP tool reported an error: \(result)")
        }

        if let contentItems = result["content"] as? [[String: Any]] {
            let textParts = contentItems.compactMap { item -> String? in
                if let text = item["text"] as? String {
                    return text
                }
                return nil
            }

            if !textParts.isEmpty {
                return .success(textParts.joined(separator: "\n"))
            }
        }

        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]),
           let pretty = String(data: data, encoding: .utf8) {
            return .success(pretty)
        }

        return .success(String(describing: result))
    }

    private static func listTools(config: ServerConfig) async throws -> [MCPToolDefinition] {
        let response = try await rpcRequest(config: config, method: "tools/list", params: [:])

        guard let result = response["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else {
            throw Error.invalidResponse("Missing result.tools payload")
        }

        return tools.compactMap { toolDict in
            guard let name = toolDict["name"] as? String else {
                return nil
            }

            let description = (toolDict["description"] as? String) ?? "MCP tool"
            let inputSchema = jsonSchema(from: toolDict["inputSchema"])
            return MCPToolDefinition(name: name, description: description, inputSchema: inputSchema)
        }
    }

    private static func rpcRequest(config: ServerConfig, method: String, params: [String: Any]) async throws -> [String: Any] {
        switch try resolveTransport(config: config) {
        case .http(let url):
            return try await httpRPCRequest(url: url, config: config, method: method, params: params)
        case .stdio:
            return try await stdioRPCRequest(config: config, method: method, params: params)
        }
    }

    private static func httpRPCRequest(url: URL, config: ServerConfig, method: String, params: [String: Any]) async throws -> [String: Any] {

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": Int.random(in: 1...1_000_000),
            "method": method,
            "params": params
        ]

        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = TimeInterval(config.timeoutSeconds)
        request.httpBody = body
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw Error.rpcFailure("HTTP status \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.invalidResponse("Response is not a JSON object")
        }

        return json
    }

    private static func stdioRPCRequest(config: ServerConfig, method: String, params: [String: Any]) async throws -> [String: Any] {
        guard !config.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.unsupportedTransport(configName: config.name)
        }

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = [config.command] + config.arguments

        var env = ProcessInfo.processInfo.environment
        for (key, value) in config.environment {
            env[key] = value
        }
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw Error.rpcFailure("stdio launch failed: \(error.localizedDescription)")
        }

        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        let initializeRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:],
                "clientInfo": [
                    "name": "native-agent",
                    "version": "0.1.0"
                ]
            ]
        ]

        let initializedNotification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
            "params": [:]
        ]

        let targetRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": method,
            "params": params
        ]

        let writer = stdinPipe.fileHandleForWriting
        try writeFramedJSON(initializeRequest, to: writer)
        try writeFramedJSON(initializedNotification, to: writer)
        try writeFramedJSON(targetRequest, to: writer)

        let reader = stdoutPipe.fileHandleForReading
        do {
            let responseData = try await readStdioResponseData(
                reader: reader,
                timeoutSeconds: max(1, config.timeoutSeconds)
            )
            guard let responseObject = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                throw Error.invalidResponse("stdio response is not a JSON object")
            }
            return responseObject
        } catch {
            if let mcpError = error as? Error {
                throw mcpError
            }
            throw Error.rpcFailure("stdio request failed: \(error.localizedDescription)")
        }
    }

    private static func readStdioResponseData(reader: FileHandle, timeoutSeconds: Int) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                var framer = MCPMessageFramer()
                var initializeSucceeded = false

                for try await byte in reader.bytes {
                    framer.append(Data([byte]))

                    while let message = framer.nextMessage() {
                        guard let object = try JSONSerialization.jsonObject(with: message) as? [String: Any] else {
                            continue
                        }

                        guard let responseId = rpcID(from: object) else {
                            continue
                        }

                        if responseId == 1 {
                            if object["error"] != nil {
                                throw Error.rpcFailure("stdio initialize failed: \(object)")
                            }
                            initializeSucceeded = true
                            continue
                        }

                        if responseId == 2 {
                            if !initializeSucceeded {
                                throw Error.invalidResponse("Received target response before initialize completed")
                            }
                            return message
                        }
                    }
                }

                throw Error.rpcFailure("stdio process ended before target response")
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                throw Error.rpcFailure("stdio request timed out after \(timeoutSeconds)s")
            }

            let first = try await group.next()
            group.cancelAll()

            guard let first else {
                throw Error.rpcFailure("stdio request failed without response")
            }

            return first
        }
    }

    private static func resolveTransport(config: ServerConfig) throws -> Transport {
        let raw: String
        if let endpoint = config.endpointURL, !endpoint.isEmpty {
            raw = endpoint
        } else if config.command.lowercased().hasPrefix("http://") || config.command.lowercased().hasPrefix("https://") {
            raw = config.command
        } else {
            if config.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw Error.unsupportedTransport(configName: config.name)
            }
            return .stdio
        }

        guard let url = URL(string: raw) else {
            throw Error.invalidEndpoint(raw)
        }
        return .http(url)
    }

    private static func writeFramedJSON(_ payload: [String: Any], to handle: FileHandle) throws {
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let header = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        try handle.write(contentsOf: header)
        try handle.write(contentsOf: body)
    }

    private static func rpcID(from object: [String: Any]) -> Int? {
        if let id = object["id"] as? Int {
            return id
        }
        if let idString = object["id"] as? String {
            return Int(idString)
        }
        if let idNumber = object["id"] as? NSNumber {
            return idNumber.intValue
        }
        return nil
    }

    private static func jsonSchema(from raw: Any?) -> JSONSchema {
        guard let dict = raw as? [String: Any] else {
            return JSONSchema(type: "object", properties: [:], required: [])
        }

        let type = (dict["type"] as? String) ?? "object"
        let required = dict["required"] as? [String]

        var properties: [String: PropertySchema] = [:]
        if let props = dict["properties"] as? [String: Any] {
            for (key, value) in props {
                if let property = propertySchema(from: value) {
                    properties[key] = property
                }
            }
        }

        return JSONSchema(type: type, properties: properties, required: required)
    }

    private static func propertySchema(from raw: Any) -> PropertySchema? {
        guard let dict = raw as? [String: Any] else { return nil }

        let type = (dict["type"] as? String) ?? "string"
        let description = dict["description"] as? String
        let enumValues = dict["enum"] as? [String]

        var items: PropertySchema?
        if let itemRaw = dict["items"] {
            items = propertySchema(from: itemRaw)
        }

        return PropertySchema(type: type, description: description, items: items, enumValues: enumValues)
    }
}
