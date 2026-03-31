import XCTest
@testable import NativeAgent

final class LSPMessageFramerTests: XCTestCase {

    func testParsesSingleMessage() throws {
        var framer = LSPMessageFramer()
        let payload = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}".utf8)
        let packet = framed(payload)

        framer.append(packet)
        let message = try framer.nextMessage()

        XCTAssertEqual(message, payload)
        XCTAssertNil(try framer.nextMessage())
    }

    func testParsesMultipleMessagesInBuffer() throws {
        var framer = LSPMessageFramer()
        let first = Data("{\"id\":1}".utf8)
        let second = Data("{\"id\":2}".utf8)

        framer.append(framed(first) + framed(second))

        XCTAssertEqual(try framer.nextMessage(), first)
        XCTAssertEqual(try framer.nextMessage(), second)
        XCTAssertNil(try framer.nextMessage())
    }

    func testReturnsNilForPartialPayload() throws {
        var framer = LSPMessageFramer()
        let payload = Data("{\"id\":1}".utf8)
        let packet = framed(payload)

        let split = packet.count - 2
        framer.append(packet.prefix(split))
        XCTAssertNil(try framer.nextMessage())

        framer.append(packet.suffix(2))
        XCTAssertEqual(try framer.nextMessage(), payload)
    }

    func testSkipsBlockWhenContentLengthMissing() throws {
        var framer = LSPMessageFramer()
        framer.append(Data("X-Test: 1\r\n\r\n{}".utf8))

        XCTAssertNil(try framer.nextMessage())
    }

    func testResyncsAfterJunkPreamble() throws {
        var framer = LSPMessageFramer()
        let payload = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}".utf8)
        var packet = Data("csharp-ls booting...\r\n\r\n".utf8)
        packet.append(framed(payload))

        framer.append(packet)
        XCTAssertEqual(try framer.nextMessage(), payload)
        XCTAssertNil(try framer.nextMessage())
    }

    func testParsesMessageWithLFOnlyHeaders() throws {
        var framer = LSPMessageFramer()
        let payload = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}".utf8)
        var packet = Data("Content-Length: \(payload.count)\n\n".utf8)
        packet.append(payload)

        framer.append(packet)
        XCTAssertEqual(try framer.nextMessage(), payload)
        XCTAssertNil(try framer.nextMessage())
    }

    private func framed(_ body: Data) -> Data {
        var data = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        data.append(body)
        return data
    }
}

private func + (lhs: Data, rhs: Data) -> Data {
    var combined = Data()
    combined.append(lhs)
    combined.append(rhs)
    return combined
}
