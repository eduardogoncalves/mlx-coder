// Tests/MemoryTests/SurfaceDetectorTests.swift
// Tests for surface and branch detection.

import XCTest
@testable import MLXCoder

final class SurfaceDetectorTests: XCTestCase {
    
    func testDetectTestsSurface() {
        let surface = SurfaceDetector.detectSurface(
            workspacePath: "/project/Tests/MyTests.swift",
            recentFiles: [
                "/project/Tests/FooTests.swift",
                "/project/Tests/BarTests.swift"
            ]
        )
        XCTAssertEqual(surface, "tests")
    }
    
    func testDetectServerSurface() {
        let surface = SurfaceDetector.detectSurface(
            workspacePath: "/project/Sources/Server/API.swift",
            recentFiles: [
                "/project/Sources/Server/Router.swift",
                "/project/Sources/Server/Handler.swift"
            ]
        )
        XCTAssertEqual(surface, "server")
    }
    
    func testDetectIOSSurface() {
        let surface = SurfaceDetector.detectSurface(
            workspacePath: "/project/Sources/iOS/ViewController.swift",
            recentFiles: [
                "/project/Sources/iOS/AppDelegate.swift"
            ]
        )
        XCTAssertEqual(surface, "ios")
    }
    
    func testDetectDocsSurface() {
        let surface = SurfaceDetector.detectSurface(
            workspacePath: "/project/docs/README.md",
            recentFiles: [
                "/project/docs/INSTALL.md",
                "/project/docs/API.md"
            ]
        )
        XCTAssertEqual(surface, "docs")
    }
    
    func testDetectScriptsSurface() {
        let surface = SurfaceDetector.detectSurface(
            workspacePath: "/project/scripts/build.sh",
            recentFiles: [
                "/project/scripts/deploy.sh"
            ]
        )
        XCTAssertEqual(surface, "scripts")
    }
    
    func testNoSurfaceDetected() {
        let surface = SurfaceDetector.detectSurface(
            workspacePath: "/project/Sources/Utils.swift",
            recentFiles: []
        )
        XCTAssertNil(surface)
    }
    
    func testMultipleSurfacesUsesHighestScore() {
        // More test files than server files
        let surface = SurfaceDetector.detectSurface(
            workspacePath: "/project",
            recentFiles: [
                "/project/Tests/Foo.test.swift",
                "/project/Tests/Bar.test.swift",
                "/project/Tests/Baz.test.swift",
                "/project/Sources/Server/API.swift"
            ]
        )
        XCTAssertEqual(surface, "tests")
    }
}
