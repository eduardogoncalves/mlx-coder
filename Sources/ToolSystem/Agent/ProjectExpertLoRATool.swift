// Sources/ToolSystem/Agent/ProjectExpertLoRATool.swift
// Learn about the user's project by training a LoRA

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import MLXOptimizers

public struct ProjectExpertLoRATool: Tool {
    public let name = "project_expert_lora"
    public let description = "Learn the user's current project files and continuously fine-tune the loaded model via LoRA in-process."
    public let parameters = JSONSchema(
        type: "object",
        properties: [
            "iterations": PropertySchema(type: "integer", description: "Number of training iterations (default 100)"),
            "loraLayers": PropertySchema(type: "integer", description: "Number of layers to apply LoRA (default 4)"),
            "batchSize": PropertySchema(type: "integer", description: "Batch size (default 1)"),
            "learningRate": PropertySchema(type: "number", description: "Learning rate (default 0.00001)")
        ]
    )

    private let modelContainer: ModelContainer
    private let workspaceRoot: String
    private let modelPath: String

    public init(modelContainer: ModelContainer, workspaceRoot: String, modelPath: String) {
        self.modelContainer = modelContainer
        self.workspaceRoot = workspaceRoot
        self.modelPath = modelPath
    }

    public func execute(arguments: [String: Any]) async throws -> ToolResult {
        let iterations = arguments["iterations"] as? Int ?? 100
        let loraLayers = arguments["loraLayers"] as? Int ?? 4
        let batchSize = arguments["batchSize"] as? Int ?? 1
        let learningRate = arguments["learningRate"] as? Float ?? 1e-5

        let adapterURL = URL(filePath: workspaceRoot)
            .appendingPathComponent(".mlx-coder")
            .appendingPathComponent("project-expert")
            .appendingPathComponent("adapters.safetensors")

        let datasetDir = URL(filePath: workspaceRoot)
            .appendingPathComponent(".mlx-coder")
            .appendingPathComponent("project-expert-dataset")

        try FileManager.default.createDirectory(at: adapterURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: datasetDir, withIntermediateDirectories: true)

        let fileURLs = scanFiles(in: URL(filePath: workspaceRoot))
        var dataset = [String]()
        
        for url in fileURLs {
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                // Prepend filename to provide context
                let relativePath = url.path().replacingOccurrences(of: workspaceRoot + "/", with: "")
                dataset.append("File: \(relativePath)\n\n\(content)")
            }
        }

        if dataset.isEmpty {
            return .error("No valid text files found in the project to train on.")
        }

        // Extremely simple valid set just reusing some of train for test runs
        let validSet = Array(dataset.prefix(max(1, dataset.count / 10)))

        // Save Dataset to disk
        let trainFileURL = datasetDir.appendingPathComponent("train.jsonl")
        let validFileURL = datasetDir.appendingPathComponent("valid.jsonl")

        try saveJSONL(dataset: dataset, to: trainFileURL)
        try saveJSONL(dataset: validSet, to: validFileURL)

        var p = LoRATrain.Parameters()
        p.batchSize = batchSize
        p.iterations = iterations
        p.stepsPerReport = max(1, iterations / 5)
        p.stepsPerEval = 0 // Skip eval to save memory
        p.saveEvery = max(1, iterations / 2)
        p.adapterURL = adapterURL

        var msg = "Saved dataset to \(datasetDir.path())\n"
        
        // Unload the current loaded model from memory before training
        print("[LoRA] Unloading existing LLM from memory to make room for training...")
        // Clearing instances effectively drops references
        MLX.Memory.clearCache()

        // We must load a new fresh model context specifically for training to avoid memory fragmentation
        let configuration = ModelConfiguration(directory: URL(filePath: NSString(string: modelPath).expandingTildeInPath))
        let trainContainer = try await LLMModelFactory.shared.loadContainer(hub: .init(), configuration: configuration)
        
        let progressMessage = try await trainContainer.perform { [dataset, validSet, p, learningRate, adapterURL, loraLayers] context -> String in
            var msg = ""
            let modelAdapter: ModelAdapter
            if FileManager.default.fileExists(atPath: adapterURL.path()) {
                modelAdapter = try LoRAContainer.from(directory: adapterURL)
                try context.model.load(adapter: modelAdapter)
                msg += "Loaded existing adapters from \(adapterURL.path()).\n"
            } else {
                modelAdapter = try LoRAContainer.from(
                    model: context.model, 
                    configuration: LoRAConfiguration(numLayers: loraLayers)
                )
                msg += "Created new adapters with \(loraLayers) layers.\n"
            }
            
            let optimizer = Adam(learningRate: learningRate)
            
            try LoRATrain.train(
                model: context.model, 
                train: dataset, 
                validate: validSet, 
                optimizer: optimizer,
                tokenizer: context.tokenizer,
                parameters: p
            ) { progress in
                // Keep standard out reporting but doesn't capture to ToolResult to avoid clutter
                print("[LoRA] \(progress)")
                return .more
            }
            
            try LoRATrain.saveLoRAWeights(model: context.model, url: adapterURL)
            return msg
        }
        
        msg += progressMessage
        
        // The trainContainer will deinit exiting this scope, freeing memory.
        print("[LoRA] Training complete. Freeing memory...")
        MLX.Memory.clearCache()
        
        // Attempt to reload adapter eagerly into the main container
        if FileManager.default.fileExists(atPath: adapterURL.path()) {
            print("[LoRA] Loading fresh weights back into active Agent LLM...")
            try await modelContainer.perform { context in
                let newAdapter = try LoRAContainer.from(directory: adapterURL)
                try context.model.load(adapter: newAdapter)
            }
        }

        return .success(msg + "Successfully trained LoRA adapter on \(dataset.count) files for \(iterations) iterations.\nAdapters saved at \(adapterURL.path())")
    }
    
    private func saveJSONL(dataset: [String], to url: URL) throws {
        let content = dataset.map {
            // Very simple JSONL encoding for text
            let escaped = $0.replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: "\n", with: "\\n")
                            .replacingOccurrences(of: "\r", with: "\\r")
                            .replacingOccurrences(of: "\"", with: "\\\"")
            return "{\"text\": \"\(escaped)\"}"
        }.joined(separator: "\n")
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // Quick scanner to find source files
    private func scanFiles(in directory: URL) -> [URL] {
        var files = [URL]()
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        guard let enumerator = enumerator else { return [] }
        
        let validExtensions = ["swift", "md", "txt", "json", "py", "c", "cpp", "h", "hpp", "js", "ts", "html", "css"]
        
        for case let fileURL as URL in enumerator {
            // Exclude .build, build/, .git (hidden files are skipped but just in case)
            if fileURL.path().contains(".build") || fileURL.path().contains("/build/") {
                continue
            }
            if validExtensions.contains(fileURL.pathExtension.lowercased()) {
                files.append(fileURL)
            }
        }
        return files
    }
}
