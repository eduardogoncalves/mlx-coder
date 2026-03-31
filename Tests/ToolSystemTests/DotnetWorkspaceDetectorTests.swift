import XCTest
@testable import MLXCoder

final class DotnetWorkspaceDetectorTests: XCTestCase {

    func testDetectsCsprojWithinDepth() async throws {
        let root = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let csproj = root.appendingPathComponent("App.csproj")
        FileManager.default.createFile(atPath: csproj.path, contents: Data("<Project />".utf8))

        let detector = DotnetWorkspaceDetector()
        let isDotnet = await detector.isDotnetWorkspace(root.path)

        XCTAssertTrue(isDotnet)
    }

    func testIgnoresFilesBeyondDepthLimit() async throws {
        let root = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let deepDir = root
            .appendingPathComponent("a")
            .appendingPathComponent("b")
            .appendingPathComponent("c")
            .appendingPathComponent("d")
        try FileManager.default.createDirectory(at: deepDir, withIntermediateDirectories: true)
        let csproj = deepDir.appendingPathComponent("TooDeep.csproj")
        FileManager.default.createFile(atPath: csproj.path, contents: Data("<Project />".utf8))

        let detector = DotnetWorkspaceDetector()
        let isDotnet = await detector.isDotnetWorkspace(root.path)

        XCTAssertFalse(isDotnet)
    }

    func testCachesResultUntilCleared() async throws {
        let root = try makeTempWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let detector = DotnetWorkspaceDetector()
        let initial = await detector.isDotnetWorkspace(root.path)
        XCTAssertFalse(initial)

        let csproj = root.appendingPathComponent("NowExists.csproj")
        FileManager.default.createFile(atPath: csproj.path, contents: Data("<Project />".utf8))

        // Should still return cached false.
        let cached = await detector.isDotnetWorkspace(root.path)
        XCTAssertFalse(cached)

        await detector.clearCache(for: root.path)
        let afterClear = await detector.isDotnetWorkspace(root.path)
        XCTAssertTrue(afterClear)
    }

    private func makeTempWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-agent-dotnet-detector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
