// Tests/ToolSystemTests/URLFetchValidatorTests.swift

import XCTest
@testable import MLXCoder

final class URLFetchValidatorTests: XCTestCase {

    // MARK: - Allowed URLs

    func testHTTPSPublicURLAllowed() throws {
        let url = URL(string: "https://example.com/page")!
        XCTAssertNoThrow(try URLFetchValidator.validate(url))
    }

    func testHTTPPublicURLAllowed() throws {
        let url = URL(string: "http://example.com/page")!
        XCTAssertNoThrow(try URLFetchValidator.validate(url))
    }

    // MARK: - Blocked schemes

    func testFileSchemeBlocked() {
        let url = URL(string: "file:///etc/passwd")!
        XCTAssertThrowsError(try URLFetchValidator.validate(url)) { error in
            guard let validationError = error as? URLFetchValidator.ValidationError,
                  case .disallowedScheme = validationError else {
                XCTFail("Expected disallowedScheme error, got \(error)")
                return
            }
        }
    }

    func testFTPSchemeBlocked() {
        let url = URL(string: "ftp://example.com/file")!
        XCTAssertThrowsError(try URLFetchValidator.validate(url)) { error in
            guard let validationError = error as? URLFetchValidator.ValidationError,
                  case .disallowedScheme = validationError else {
                XCTFail("Expected disallowedScheme error, got \(error)")
                return
            }
        }
    }

    // MARK: - Blocked hosts

    func testLocalhostBlocked() {
        let url = URL(string: "http://localhost/admin")!
        XCTAssertThrowsError(try URLFetchValidator.validate(url)) { error in
            guard let validationError = error as? URLFetchValidator.ValidationError,
                  case .blockedHost = validationError else {
                XCTFail("Expected blockedHost error, got \(error)")
                return
            }
        }
    }

    func testLoopbackIPv4Blocked() {
        let url = URL(string: "http://127.0.0.1/")!
        XCTAssertThrowsError(try URLFetchValidator.validate(url)) { error in
            guard let validationError = error as? URLFetchValidator.ValidationError,
                  case .blockedHost = validationError else {
                XCTFail("Expected blockedHost error, got \(error)")
                return
            }
        }
    }

    func testLoopback127xBlocked() {
        let url = URL(string: "http://127.1.2.3/")!
        XCTAssertThrowsError(try URLFetchValidator.validate(url)) { error in
            guard let validationError = error as? URLFetchValidator.ValidationError,
                  case .blockedHost = validationError else {
                XCTFail("Expected blockedHost error for 127.x.x.x, got \(error)")
                return
            }
        }
    }

    func testIPv6LoopbackBlocked() {
        // URL hosts for IPv6 use bracket notation
        let url = URL(string: "http://[::1]/")!
        XCTAssertThrowsError(try URLFetchValidator.validate(url)) { error in
            guard let validationError = error as? URLFetchValidator.ValidationError,
                  case .blockedHost = validationError else {
                XCTFail("Expected blockedHost error, got \(error)")
                return
            }
        }
    }

    func testPrivateRFC1918_10Blocked() {
        let url = URL(string: "http://10.0.0.1/")!
        XCTAssertThrowsError(try URLFetchValidator.validate(url)) { error in
            guard let validationError = error as? URLFetchValidator.ValidationError,
                  case .blockedHost = validationError else {
                XCTFail("Expected blockedHost error for 10.x.x.x, got \(error)")
                return
            }
        }
    }

    func testPrivateRFC1918_172Blocked() {
        let url = URL(string: "http://172.16.0.1/")!
        XCTAssertThrowsError(try URLFetchValidator.validate(url)) { error in
            guard let validationError = error as? URLFetchValidator.ValidationError,
                  case .blockedHost = validationError else {
                XCTFail("Expected blockedHost error for 172.16.x.x, got \(error)")
                return
            }
        }
    }

    func testPrivateRFC1918_172EdgeBlocked() {
        // 172.31.x.x is still in range (172.16-31)
        let url = URL(string: "http://172.31.255.255/")!
        XCTAssertThrowsError(try URLFetchValidator.validate(url)) { error in
            guard let e = error as? URLFetchValidator.ValidationError, case .blockedHost = e else {
                XCTFail("Expected blockedHost for 172.31.x.x, got \(error)")
                return
            }
        }
    }

    func testPublic172NotBlocked() throws {
        // 172.32.x.x is outside the RFC 1918 private range
        let url = URL(string: "http://172.32.0.1/")!
        XCTAssertNoThrow(try URLFetchValidator.validate(url))
    }

    func testPrivateRFC1918_192168Blocked() {
        let url = URL(string: "http://192.168.1.100/")!
        XCTAssertThrowsError(try URLFetchValidator.validate(url)) { error in
            guard let validationError = error as? URLFetchValidator.ValidationError,
                  case .blockedHost = validationError else {
                XCTFail("Expected blockedHost error for 192.168.x.x, got \(error)")
                return
            }
        }
    }

    func testCloudMetadataAWSBlocked() {
        // AWS / GCP / Azure instance metadata endpoint
        let url = URL(string: "http://169.254.169.254/latest/meta-data/")!
        XCTAssertThrowsError(try URLFetchValidator.validate(url)) { error in
            guard let validationError = error as? URLFetchValidator.ValidationError,
                  case .blockedHost = validationError else {
                XCTFail("Expected blockedHost error for cloud metadata IP, got \(error)")
                return
            }
        }
    }

    func testZeroIPBlocked() {
        let url = URL(string: "http://0.0.0.0/")!
        XCTAssertThrowsError(try URLFetchValidator.validate(url)) { error in
            guard let validationError = error as? URLFetchValidator.ValidationError,
                  case .blockedHost = validationError else {
                XCTFail("Expected blockedHost error for 0.0.0.0, got \(error)")
                return
            }
        }
    }
}
