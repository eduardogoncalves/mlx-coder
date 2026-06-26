import Foundation
import MLX
import MLXLMCommon

enum Qwen35MTPDraftOverride {
    private static let mtpModelType = "qwen3_5_mtp"
    private static let compatModelType = "qwen3_5_text"

    static func prepareIfNeeded(
        draftModelPath: String,
        mainModelPath: String,
        mainModelContainer: ModelContainer,
        renderer: StreamRenderer
    ) async throws -> String {
        let draftURL = resolvedModelDirectoryURL(for: draftModelPath)
        let configURL = draftURL.appendingPathComponent("config.json")
        guard let configData = try? Data(contentsOf: configURL),
              let rawConfig = try JSONSerialization.jsonObject(with: configData) as? [String: Any],
              (rawConfig["model_type"] as? String) == mtpModelType else {
            return draftModelPath
        }

        renderer.printStatus("Applying qwen3_5_mtp compatibility override...")

        let textConfig = (rawConfig["text_config"] as? [String: Any]) ?? [:]
        let mtpLayers = max(1, textConfig["mtp_num_hidden_layers"] as? Int ?? 1)

        var compatTextConfig = textConfig
        compatTextConfig["model_type"] = compatModelType
        compatTextConfig["num_hidden_layers"] = mtpLayers
        compatTextConfig["full_attention_interval"] = 1
        compatTextConfig["tie_word_embeddings"] = true

        var compatConfig: [String: Any] = [
            "model_type": compatModelType,
            "text_config": compatTextConfig,
            "tie_word_embeddings": true,
            "block_size": max(2, mtpLayers + 2),
        ]
        if let quantization = rawConfig["quantization"] {
            compatConfig["quantization"] = quantization
            compatConfig["quantization_config"] = quantization
        } else if let quantizationConfig = rawConfig["quantization_config"] {
            compatConfig["quantization"] = quantizationConfig
            compatConfig["quantization_config"] = quantizationConfig
        }

        let outputURL = try makeOutputDirectory(mainModelPath: mainModelPath, draftModelPath: draftModelPath)
        let draftWeightsURL = draftURL.appendingPathComponent("model.safetensors")

        try await mainModelContainer.perform { (context: ModelContext) async throws -> Void in
            let flattened = context.model.parameters().flattened()
            let flattenedMap = Dictionary(uniqueKeysWithValues: flattened.map { ($0.0, $0.1) })
            guard let embedWeight = flattenedMap["language_model.model.embed_tokens.weight"]
                ?? flattened.first(where: { $0.0.hasSuffix(".embed_tokens.weight") })?.1 else {
                throw NSError(
                    domain: "Qwen35MTPDraftOverride",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Main model embedding weights not found."]
                )
            }

            let (draftWeights, draftMetadata) = try loadArraysAndMetadata(url: draftWeightsURL)
            var converted = [String: MLXArray]()
            converted["model.embed_tokens.weight"] = embedWeight
            for (key, value) in draftWeights {
                if key.hasPrefix("layers.") || key == "norm.weight" {
                    converted["model.\(key)"] = value
                }
            }

            guard converted["model.norm.weight"] != nil else {
                throw NSError(
                    domain: "Qwen35MTPDraftOverride",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid qwen3_5_mtp draft: missing norm.weight."]
                )
            }

            try save(
                arrays: converted,
                metadata: filteredMetadata(draftMetadata),
                url: outputURL.appendingPathComponent("model.safetensors")
            )
        }

        let configOutData = try JSONSerialization.data(withJSONObject: compatConfig, options: [.prettyPrinted, .sortedKeys])
        try configOutData.write(to: outputURL.appendingPathComponent("config.json"), options: .atomic)

        copyTokenizerArtifacts(from: draftURL, to: outputURL)
        renderer.printStatus("qwen3_5_mtp override ready: using compatibility draft model.")
        return outputURL.path
    }

    private static func resolvedModelDirectoryURL(for path: String) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) {
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }

        let parts = path.split(separator: "/")
        if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
            let local = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent(String(parts[0]), isDirectory: true)
                .appendingPathComponent(String(parts[1]), isDirectory: true)
            if FileManager.default.fileExists(atPath: local.path) {
                return local
            }
        }

        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    private static func makeOutputDirectory(mainModelPath: String, draftModelPath: String) throws -> URL {
        let key = "\(mainModelPath)|\(draftModelPath)"
        let digest = stableDigestHex(for: key)
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mlx-coder-draft-overrides", isDirectory: true)
            .appendingPathComponent(digest, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func stableDigestHex(for text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func filteredMetadata(_ metadata: [String: String]) -> [String: String] {
        if metadata.isEmpty { return ["format": "mlx"] }
        var out = metadata
        out["format"] = "mlx"
        return out
    }

    private static func copyTokenizerArtifacts(from source: URL, to destination: URL) {
        let names = [
            "tokenizer.json",
            "tokenizer_config.json",
            "vocab.json",
            "merges.txt",
            "special_tokens_map.json",
            "chat_template.jinja",
        ]
        for name in names {
            let from = source.appendingPathComponent(name)
            let to = destination.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            try? FileManager.default.removeItem(at: to)
            try? FileManager.default.copyItem(at: from, to: to)
        }
    }
}
