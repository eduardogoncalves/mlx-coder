// Sources/ModelEngine/ImageDataURLEncoder.swift
// Encodes local image files as base64 data: URLs for OpenAI-compatible
// vision APIs (OpenRouter, LM Studio, vLLM). The local MLX VLM path never
// needs this — it hands `file://` URLs straight to MLXLMCommon's processor.

import Foundation
import ImageIO
import CoreGraphics

public enum ImageDataURLEncoder {

    /// MIME types accepted by OpenAI-compatible vision APIs. HEIC/HEIF and
    /// TIFF (allowed for local MLX attachment) are not in this set — those
    /// are re-encoded to PNG rather than sent as-is.
    private static let mimeTypesByExtension: [String: String] = [
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
    ]

    /// Reads `url` and returns a `data:<mime>;base64,<data>` string suitable for
    /// an OpenAI-style `image_url` content part. Formats outside the
    /// OpenAI-accepted set (HEIC/HEIF/TIFF/BMP) are converted to PNG first.
    public static func dataURL(for url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        if let mime = mimeTypesByExtension[ext] {
            let data = try Data(contentsOf: url)
            return "data:\(mime);base64,\(data.base64EncodedString())"
        }

        // Unsupported wire format (heic, heif, tiff, tif, bmp) — re-encode to PNG.
        guard let pngData = try pngData(from: url) else {
            throw NSError(
                domain: "ImageDataURLEncoder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not decode image at \(url.path) for remote attachment."]
            )
        }
        return "data:image/png;base64,\(pngData.base64EncodedString())"
    }

    private static func pngData(from url: URL) throws -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
