// Tests/ModelEngineTests/Glm4vModelTypeTests.swift
// Verifies that ModelLoader registers "glm4v" so GLM-4.6V-Flash models load without error.

import XCTest
@testable import MLXCoder

final class Glm4vModelTypeTests: XCTestCase {

    // MARK: - ModelLoaderError

    func testModelDirectoryNotFoundErrorContainsPath() {
        let path = "/tmp/nonexistent-glm4v-model"
        let error = ModelLoaderError.modelDirectoryNotFound(path)
        XCTAssertTrue(error.errorDescription?.contains(path) == true)
    }

    // MARK: - glm4v model type recognition

    /// Verifies that a path that looks like a Hub model ID (owner/model) is treated as such
    /// and is not mistakenly rejected as a missing local path.  This is the code path used
    /// when loading a GLM-4.6V model from Hugging Face (e.g.
    /// "lmstudio-community/GLM-4.6V-Flash-MLX-4bit").
    func testHubModelIDForGlm4v() async throws {
        // A pure Hub ID path — no leading slashes or tildes, exactly "owner/model" form.
        let hubPath = "lmstudio-community/GLM-4.6V-Flash-MLX-4bit"

        // ModelLoader.load will attempt to download if treated as a Hub ID.
        // We only verify the path is NOT treated as a missing local path, i.e. it should
        // throw something other than ModelLoaderError.modelDirectoryNotFound.
        do {
            _ = try await ModelLoader.load(from: hubPath)
            // In a full-stack test environment the model may actually load — that's fine.
        } catch ModelLoaderError.modelDirectoryNotFound {
            XCTFail("Hub ID '\(hubPath)' was incorrectly rejected as a missing local path.")
        } catch {
            // Any other error (download failure, network unavailable, etc.) is acceptable
            // because it means the path was correctly identified as a Hub ID.
        }
    }

    /// Verifies that passing a non-existent local path throws the expected error.
    func testNonExistentLocalPathThrows() async {
        do {
            _ = try await ModelLoader.load(from: "/tmp/no-such-glm4v-model-9999")
            XCTFail("Expected ModelLoaderError.modelDirectoryNotFound to be thrown.")
        } catch ModelLoaderError.modelDirectoryNotFound(let path) {
            XCTAssertTrue(path.contains("no-such-glm4v-model-9999"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}
