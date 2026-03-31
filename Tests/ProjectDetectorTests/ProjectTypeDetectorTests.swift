import XCTest
@testable import NativeAgent

final class ProjectTypeDetectorTests: XCTestCase {
    var detector: ProjectTypeDetector!
    var tempDir: String!
    
    override func setUp() async throws {
        detector = ProjectTypeDetector()
        tempDir = NSTemporaryDirectory() + "mlx-coder-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }
    
    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: tempDir)
    }
    
    func testDetectsDotnetProject() async {
        // Create .sln marker
        let slnFile = (tempDir as NSString).appendingPathComponent("test.sln")
        FileManager.default.createFile(atPath: slnFile, contents: nil)
        
        let result = await detector.detect(workspace: tempDir)
        
        XCTAssertTrue(result.isDetected)
        XCTAssertEqual(result.projectInfo?.type, .dotnet)
        XCTAssertEqual(result.projectInfo?.buildTool, "dotnet")
    }
    
    func testDetectsNodejsProject() async {
        // Create package.json
        let packageJson = (tempDir as NSString).appendingPathComponent("package.json")
        let content = """
        {
          "name": "test-app",
          "version": "1.0.0",
          "scripts": {
            "build": "tsc"
          }
        }
        """
        FileManager.default.createFile(atPath: packageJson, contents: content.data(using: .utf8))
        
        let result = await detector.detect(workspace: tempDir)
        
        XCTAssertTrue(result.isDetected)
        XCTAssertEqual(result.projectInfo?.type, .nodejs)
        XCTAssertEqual(result.projectInfo?.packageManager, .npm)
        XCTAssertTrue(result.projectInfo?.hasBuildScript ?? false)
    }
    
    func testDetectsGoProject() async {
        // Create go.mod
        let goMod = (tempDir as NSString).appendingPathComponent("go.mod")
        FileManager.default.createFile(atPath: goMod, contents: nil)
        
        let result = await detector.detect(workspace: tempDir)
        
        XCTAssertTrue(result.isDetected)
        XCTAssertEqual(result.projectInfo?.type, .go)
        XCTAssertEqual(result.projectInfo?.packageManager, .gomod)
    }
    
    func testDetectsRustProject() async {
        // Create Cargo.toml
        let cargoToml = (tempDir as NSString).appendingPathComponent("Cargo.toml")
        FileManager.default.createFile(atPath: cargoToml, contents: nil)
        
        let result = await detector.detect(workspace: tempDir)
        
        XCTAssertTrue(result.isDetected)
        XCTAssertEqual(result.projectInfo?.type, .rust)
        XCTAssertEqual(result.projectInfo?.packageManager, .cargo)
    }
    
    func testDetectsPythonProject() async {
        // Create pyproject.toml
        let pyProject = (tempDir as NSString).appendingPathComponent("pyproject.toml")
        FileManager.default.createFile(atPath: pyProject, contents: nil)
        
        let result = await detector.detect(workspace: tempDir)
        
        XCTAssertTrue(result.isDetected)
        XCTAssertEqual(result.projectInfo?.type, .python)
    }
    
    func testDetectsYarnPackageManager() async {
        // Create package.json + yarn.lock
        let packageJson = (tempDir as NSString).appendingPathComponent("package.json")
        let yarnLock = (tempDir as NSString).appendingPathComponent("yarn.lock")
        
        FileManager.default.createFile(atPath: packageJson, contents: "{}".data(using: .utf8))
        FileManager.default.createFile(atPath: yarnLock, contents: nil)
        
        let result = await detector.detect(workspace: tempDir)
        
        XCTAssertEqual(result.projectInfo?.packageManager, .yarn)
    }
    
    func testDetectsPnpmPackageManager() async {
        // Create package.json + pnpm-lock.yaml
        let packageJson = (tempDir as NSString).appendingPathComponent("package.json")
        let pnpmLock = (tempDir as NSString).appendingPathComponent("pnpm-lock.yaml")
        
        FileManager.default.createFile(atPath: packageJson, contents: "{}".data(using: .utf8))
        FileManager.default.createFile(atPath: pnpmLock, contents: nil)
        
        let result = await detector.detect(workspace: tempDir)
        
        XCTAssertEqual(result.projectInfo?.packageManager, .pnpm)
    }
    
    func testDetectsUnknownProject() async {
        // Empty directory
        let result = await detector.detect(workspace: tempDir)
        
        XCTAssertFalse(result.isDetected)
        XCTAssertNil(result.projectInfo)
    }
    
    func testCaching() async {
        // Create .sln marker
        let slnFile = (tempDir as NSString).appendingPathComponent("test.sln")
        FileManager.default.createFile(atPath: slnFile, contents: nil)
        
        // First detection
        let result1 = await detector.detect(workspace: tempDir)
        XCTAssertTrue(result1.isDetected)
        
        // Delete the .sln file
        try? FileManager.default.removeItem(atPath: slnFile)
        
        // Second detection should still be cached
        let result2 = await detector.detect(workspace: tempDir)
        XCTAssertTrue(result2.isDetected)
        
        // Clear cache and try again
        await detector.clearCache()
        let result3 = await detector.detect(workspace: tempDir)
        XCTAssertFalse(result3.isDetected)
    }
    
    func testInvalidWorkspacePath() async {
        let invalidPath = "/nonexistent/path/that/does/not/exist"
        let result = await detector.detect(workspace: invalidPath)
        
        XCTAssertFalse(result.isDetected)
        XCTAssertNotNil(result.error)
    }
}
