// Sources/MLXCoder/ModelSelectionHelpers.swift
// Model discovery, download prompts, path validation, and loading utilities.

import Foundation
import MLXLMCommon

let recommendedHubModels = [
    "mlx-community/Qwen3.5-9B-MLX-4bit",
    "NexVeridian/OmniCoder-9B-4bit",
]

func localModelExists(_ path: String) -> Bool {
    let expanded = NSString(string: path).expandingTildeInPath
    return FileManager.default.fileExists(atPath: expanded)
}

func looksLikeHubModelID(_ value: String) -> Bool {
    if value.hasPrefix("/") || value.hasPrefix("~") || value.hasPrefix(".") {
        return false
    }
    let parts = value.split(separator: "/")
    return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
}

func parseUserModelIdentifier(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix(".") {
        return nil
    }

    let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2 else {
        return nil
    }

    let owner = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
    let model = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !owner.isEmpty, !model.isEmpty else {
        return nil
    }

    return "\(owner)/\(model)"
}

func listHomeModelsAsRepoIDs() -> [String] {
    let fileManager = FileManager.default
    let modelsRoot = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("models", isDirectory: true)

    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: modelsRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        return []
    }

    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isHiddenKey]

    guard let ownerDirs = try? fileManager.contentsOfDirectory(
        at: modelsRoot,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
        return []
    }

    var models: [String] = []
    let sortedOwners = ownerDirs.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

    for ownerURL in sortedOwners {
        guard let ownerValues = try? ownerURL.resourceValues(forKeys: keys),
              ownerValues.isDirectory == true,
              ownerValues.isHidden != true else {
            continue
        }

        guard let modelDirs = try? fileManager.contentsOfDirectory(
            at: ownerURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            continue
        }

        let sortedModels = modelDirs.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for modelURL in sortedModels {
            guard let modelValues = try? modelURL.resourceValues(forKeys: keys),
                  modelValues.isDirectory == true,
                  modelValues.isHidden != true else {
                continue
            }

            models.append("\(ownerURL.lastPathComponent)/\(modelURL.lastPathComponent)")
        }
    }

    return models
}

func promptForRecommendedModelDownload() -> String? {
    print("\nNo local MLX model found. Download one now?")
    print("  1) \(recommendedHubModels[0])")
    print("  2) \(recommendedHubModels[1])")
    print("  0) Skip download and use Apple Foundation fallback")
    print("Choose [1/2/0]: ", terminator: "")

    guard let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else {
        return nil
    }

    switch input {
    case "1": return recommendedHubModels[0]
    case "2": return recommendedHubModels[1]
    default: return nil
    }
}

func loadModelWithCancellation(
    from path: String,
    memoryLimit: Int?,
    cacheLimit: Int?,
    renderer: StreamRenderer
) async throws -> ModelContainer {
    let loadTask = Task {
        try await ModelLoader.load(
            from: path,
            memoryLimit: memoryLimit,
            cacheLimit: cacheLimit
        )
    }

    await CancelController.shared.setTask(loadTask)

    do {
        let container = try await loadTask.value
        await CancelController.shared.setTask(nil)
        return container
    } catch {
        await CancelController.shared.setTask(nil)
        if error is CancellationError {
            renderer.printError("Model loading cancelled by user.")
        }
        throw error
    }
}
