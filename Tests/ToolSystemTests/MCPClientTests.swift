import XCTest
@testable import MLXCoder

final class MCPClientTests: XCTestCase {
    func testConnectFailsWhenNoTransportConfigured() async {
        let config = MCPClient.ServerConfig(name: "local", command: "")

        do {
            _ = try await MCPClient.connect(to: config)
            XCTFail("Expected MCPClient.connect to fail for unsupported transport")
        } catch let error as MCPClient.Error {
            switch error {
            case .unsupportedTransport(let name):
                XCTAssertEqual(name, "local")
            default:
                XCTFail("Unexpected MCP error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testConnectAttemptsStdioTransportWhenCommandProvided() async {
        let config = MCPClient.ServerConfig(
            name: "stdio",
            command: "/usr/bin/false",
            timeoutSeconds: 1
        )

        do {
            _ = try await MCPClient.connect(to: config)
            XCTFail("Expected MCPClient.connect to fail because stdio process exits without handshake")
        } catch let error as MCPClient.Error {
            switch error {
            case .rpcFailure(let details):
                XCTAssertFalse(details.isEmpty)
            default:
                XCTFail("Unexpected MCP error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testConnectStdioTimeoutForSilentProcess() async {
        let config = MCPClient.ServerConfig(
            name: "stdio-timeout",
            command: "/bin/sleep",
            arguments: ["5"],
            timeoutSeconds: 1
        )

        do {
            _ = try await MCPClient.connect(to: config)
            XCTFail("Expected MCPClient.connect to time out for silent stdio process")
        } catch let error as MCPClient.Error {
            switch error {
            case .rpcFailure(let details):
                XCTAssertTrue(details.contains("timed out") || details.contains("failed"))
            default:
                XCTFail("Unexpected MCP error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testConnectFailsForInvalidEndpointURL() async {
        let config = MCPClient.ServerConfig(
            name: "bad-url",
            command: "not-a-url",
            endpointURL: "not-a-url"
        )

        do {
            _ = try await MCPClient.connect(to: config)
            XCTFail("Expected MCPClient.connect to fail for invalid endpoint URL")
        } catch let error as MCPClient.Error {
            switch error {
            case .invalidEndpoint(let value):
                XCTAssertEqual(value, "not-a-url")
            case .rpcFailure:
                XCTAssertTrue(true)
            default:
                XCTFail("Unexpected MCP error: \(error)")
            }
        } catch {
            XCTAssertTrue(error is URLError)
        }
    }

    func testConnectUsesCommandWhenItIsHTTPURL() async {
        let config = MCPClient.ServerConfig(
            name: "http-command",
            command: "http://127.0.0.1:9"
        )

        do {
            _ = try await MCPClient.connect(to: config)
            XCTFail("Expected MCPClient.connect to fail because endpoint is unreachable")
        } catch let error as MCPClient.Error {
            switch error {
            case .rpcFailure:
                XCTAssertTrue(true)
            case .invalidResponse:
                XCTAssertTrue(true)
            default:
                XCTFail("Unexpected MCP error: \(error)")
            }
        } catch {
            // URLSession transport errors can surface as URLError; this still validates endpoint resolution path.
            XCTAssertTrue(error is URLError)
        }
    }
}