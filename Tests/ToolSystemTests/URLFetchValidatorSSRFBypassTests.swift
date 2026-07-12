// Tests/ToolSystemTests/URLFetchValidatorSSRFBypassTests.swift
// Tests for SSRF bypass vectors fixed in URLFetchValidator.
//
// Covers: numeric decimal IPv4, octal IPv4, hex IPv4, IPv4-mapped IPv6,
// IPv4-compatible IPv6, unique-local IPv6 (fc00::/7), and CGNAT (100.64/10).
// The synchronous validate(_:) overload tests IP-literal blocking; DNS-rebinding
// tests are async and exercise the full validate(_:) async overload.

import XCTest
@testable import MLXCoder

final class URLFetchValidatorSSRFBypassTests: XCTestCase {

    // MARK: - Helpers

    private func assertBlocked(_ urlString: String, file: StaticString = #file, line: UInt = #line) {
        guard let url = URL(string: urlString) else {
            XCTFail("Could not construct URL from \(urlString)", file: file, line: line)
            return
        }
        XCTAssertThrowsError(try URLFetchValidator.validate(url), file: file, line: line) { error in
            guard let e = error as? URLFetchValidator.ValidationError, case .blockedHost = e else {
                XCTFail("Expected blockedHost for \(urlString), got \(error)", file: file, line: line)
                return
            }
        }
    }

    private func assertAllowed(_ urlString: String, file: StaticString = #file, line: UInt = #line) {
        guard let url = URL(string: urlString) else {
            XCTFail("Could not construct URL from \(urlString)", file: file, line: line)
            return
        }
        XCTAssertNoThrow(try URLFetchValidator.validate(url), file: file, line: line)
    }

    // MARK: - parseIPv4Literal

    func testParseIPv4DecimalInteger() {
        // 2130706433 == 0x7F000001 == 127.0.0.1
        let addr = URLFetchValidator.parseIPv4Literal("2130706433")
        XCTAssertNotNil(addr)
        XCTAssertTrue(URLFetchValidator.isBlockedIPv4Addr(addr!),
                      "Decimal integer 2130706433 should map to 127.0.0.1 (loopback)")
    }

    func testParseIPv4HexInteger() {
        // 0x7f000001 == 127.0.0.1
        let addr = URLFetchValidator.parseIPv4Literal("0x7f000001")
        XCTAssertNotNil(addr)
        XCTAssertTrue(URLFetchValidator.isBlockedIPv4Addr(addr!),
                      "Hex integer 0x7f000001 should map to 127.0.0.1 (loopback)")
    }

    func testParseIPv4OctalOctet() {
        // 0177.0.0.1 == 127.0.0.1 in octal-dotted form
        let addr = URLFetchValidator.parseIPv4Literal("0177.0.0.1")
        XCTAssertNotNil(addr)
        XCTAssertTrue(URLFetchValidator.isBlockedIPv4Addr(addr!),
                      "Octal dotted 0177.0.0.1 should map to 127.0.0.1 (loopback)")
    }

    func testParseIPv4HexDottedOctet() {
        // 0x7f.0.0.1 == 127.0.0.1 in hex-dotted form
        let addr = URLFetchValidator.parseIPv4Literal("0x7f.0.0.1")
        XCTAssertNotNil(addr)
        XCTAssertTrue(URLFetchValidator.isBlockedIPv4Addr(addr!),
                      "Hex dotted 0x7f.0.0.1 should map to 127.0.0.1 (loopback)")
    }

    func testParseIPv4CloudMetadataDecimalInt() {
        // 169.254.169.254 in decimal: 169*16777216 + 254*65536 + 169*256 + 254 = 2852039166
        let expected: UInt32 = (169 << 24) | (254 << 16) | (169 << 8) | 254
        let addr = URLFetchValidator.parseIPv4Literal(String(expected))
        XCTAssertNotNil(addr)
        XCTAssertTrue(URLFetchValidator.isBlockedIPv4Addr(addr!),
                      "Decimal integer of 169.254.169.254 should be blocked (cloud metadata)")
    }

    // MARK: - isBlockedIPv4Addr range coverage

    func testCGNATBlocked() {
        // 100.64.0.1 — CGNAT range 100.64.0.0/10
        let addr: UInt32 = (100 << 24) | (64 << 16) | 0 | 1
        XCTAssertTrue(URLFetchValidator.isBlockedIPv4Addr(addr), "100.64.0.1 should be blocked (CGNAT)")
    }

    func testCGNATEdgeBlocked() {
        // 100.127.255.255 — last address in 100.64/10
        let addr: UInt32 = (100 << 24) | (127 << 16) | (255 << 8) | 255
        XCTAssertTrue(URLFetchValidator.isBlockedIPv4Addr(addr), "100.127.255.255 should be blocked (CGNAT)")
    }

    func testCGNATOutsideNotBlocked() {
        // 100.128.0.1 — just outside CGNAT range
        let addr: UInt32 = (100 << 24) | (128 << 16) | 0 | 1
        XCTAssertFalse(URLFetchValidator.isBlockedIPv4Addr(addr), "100.128.0.1 should not be blocked")
    }

    func testReservedClass240Blocked() {
        // 240.0.0.1 — reserved range 240.0.0.0/4
        let addr: UInt32 = (240 << 24) | 1
        XCTAssertTrue(URLFetchValidator.isBlockedIPv4Addr(addr), "240.0.0.1 should be blocked (reserved)")
    }

    func testTestNet1Blocked() {
        // 192.0.2.1 — TEST-NET-1 (RFC 5737)
        let addr: UInt32 = (192 << 24) | (0 << 16) | (2 << 8) | 1
        XCTAssertTrue(URLFetchValidator.isBlockedIPv4Addr(addr), "192.0.2.1 should be blocked (TEST-NET-1)")
    }

    func testBenchmarkingRangeBlocked() {
        // 198.18.0.1 — benchmarking range (RFC 2544)
        let addr: UInt32 = (198 << 24) | (18 << 16) | 0 | 1
        XCTAssertTrue(URLFetchValidator.isBlockedIPv4Addr(addr), "198.18.0.1 should be blocked (benchmarking)")
    }

    // MARK: - Full URL blocking for numeric bypass forms

    func testDecimalIPv4URLBlocked() {
        // http://2130706433/ should be blocked (= 127.0.0.1)
        // URL parsing may not accept this form on all systems; guard for that.
        guard let url = URL(string: "http://2130706433/") else { return }
        XCTAssertThrowsError(try URLFetchValidator.validate(url)) { error in
            guard let e = error as? URLFetchValidator.ValidationError, case .blockedHost = e else {
                XCTFail("Expected blockedHost for decimal IP 2130706433, got \(error)")
                return
            }
        }
    }

    func testOctalIPv4URLBlocked() {
        guard let url = URL(string: "http://0177.0.0.1/") else { return }
        XCTAssertThrowsError(try URLFetchValidator.validate(url)) { error in
            guard let e = error as? URLFetchValidator.ValidationError, case .blockedHost = e else {
                XCTFail("Expected blockedHost for octal IP 0177.0.0.1, got \(error)")
                return
            }
        }
    }

    func testHexIPv4URLBlocked() {
        guard let url = URL(string: "http://0x7f000001/") else { return }
        XCTAssertThrowsError(try URLFetchValidator.validate(url)) { error in
            guard let e = error as? URLFetchValidator.ValidationError, case .blockedHost = e else {
                XCTFail("Expected blockedHost for hex IP 0x7f000001, got \(error)")
                return
            }
        }
    }

    func testHexDottedIPv4URLBlocked() {
        guard let url = URL(string: "http://0x7f.0.0.1/") else { return }
        XCTAssertThrowsError(try URLFetchValidator.validate(url)) { error in
            guard let e = error as? URLFetchValidator.ValidationError, case .blockedHost = e else {
                XCTFail("Expected blockedHost for hex-dotted IP 0x7f.0.0.1, got \(error)")
                return
            }
        }
    }

    // MARK: - IPv6 unique-local (fc00::/7)

    func testUniqueLocalFC00Blocked() {
        assertBlocked("http://[fc00::1]/")
    }

    func testUniqueLocalFD00Blocked() {
        assertBlocked("http://[fd00::1]/")
    }

    func testUniqueLocalFD12Blocked() {
        assertBlocked("http://[fd12:3456:789a::1]/")
    }

    // MARK: - IPv4-mapped IPv6

    func testIPv4MappedLoopbackBlocked() {
        // ::ffff:127.0.0.1
        assertBlocked("http://[::ffff:127.0.0.1]/")
    }

    func testIPv4MappedCloudMetadataBlocked() {
        // ::ffff:169.254.169.254
        assertBlocked("http://[::ffff:169.254.169.254]/")
    }

    func testIPv4MappedPrivateBlocked() {
        // ::ffff:192.168.1.1
        assertBlocked("http://[::ffff:192.168.1.1]/")
    }

    func testIPv4CompatibleLoopbackBlocked() {
        // ::127.0.0.1  (IPv4-compatible, deprecated but still parsed)
        assertBlocked("http://[::127.0.0.1]/")
    }

    func testIPv4MappedPublicAllowed() {
        // ::ffff:8.8.8.8 — public IP, should not be blocked
        assertAllowed("http://[::ffff:8.8.8.8]/")
    }

    // MARK: - isBlockedHost convenience

    func testIsBlockedHostDecimalInteger() {
        // inet_aton("2130706433") == 127.0.0.1
        XCTAssertTrue(URLFetchValidator.isBlockedHost("2130706433"),
                      "Decimal integer 2130706433 should be blocked")
    }

    func testIsBlockedHostHexInteger() {
        XCTAssertTrue(URLFetchValidator.isBlockedHost("0x7f000001"),
                      "Hex integer 0x7f000001 should be blocked")
    }

    func testIsBlockedHostUniqueLocal() {
        XCTAssertTrue(URLFetchValidator.isBlockedHost("fd00::1"),
                      "Unique-local fd00::1 should be blocked")
    }

    func testIsBlockedHostPublicIPv4NotBlocked() {
        XCTAssertFalse(URLFetchValidator.isBlockedHost("8.8.8.8"),
                       "Public IP 8.8.8.8 should not be blocked")
    }

    func testIsBlockedHostPublicIPv6NotBlocked() {
        XCTAssertFalse(URLFetchValidator.isBlockedHost("2001:4860:4860::8888"),
                       "Public IPv6 2001:4860:4860::8888 should not be blocked")
    }

    // MARK: - Async validate (DNS check)

    func testAsyncValidatePublicURL() async throws {
        let url = URL(string: "https://example.com/")!
        try await URLFetchValidator.validate(url)
    }

    func testAsyncValidateLocalhostBlocked() async {
        let url = URL(string: "http://localhost/")!
        do {
            try await URLFetchValidator.validate(url)
            XCTFail("Expected blockedHost error for localhost")
        } catch let e as URLFetchValidator.ValidationError {
            if case .blockedHost = e { /* expected */ } else {
                XCTFail("Expected blockedHost, got \(e)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testAsyncValidateIPv4MappedCloudMetadataBlocked() async {
        let url = URL(string: "http://[::ffff:169.254.169.254]/")!
        do {
            try await URLFetchValidator.validate(url)
            XCTFail("Expected blockedHost for IPv4-mapped cloud metadata")
        } catch let e as URLFetchValidator.ValidationError {
            if case .blockedHost = e { /* expected */ } else {
                XCTFail("Expected blockedHost, got \(e)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}
