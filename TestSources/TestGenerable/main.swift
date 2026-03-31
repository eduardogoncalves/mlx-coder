import Foundation
import FoundationModels

@available(macOS 26.0, *)
@Generable
public struct ToolCallRequest: Sendable {
    public var name: String
    public var arguments: String
}

@available(macOS 26.0, *)
@main
struct App {
    static func main() throws {
        let schema = ToolCallRequest.generationSchema
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(schema)
        if let jsonString = String(data: data, encoding: .utf8) {
            print("JSON Schema Output:")
            print(jsonString)
        }
    }
}
