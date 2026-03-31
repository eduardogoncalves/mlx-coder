#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, *)
@Generable
public struct ToolCallRequest: Sendable {
    public var name: String
    public var arguments: String
}

@available(macOS 26.0, *)
public func testSchemaExport() {
    let mirror = Mirror(reflecting: ToolCallRequest.self)
        print("Mirror children:", mirror.children)
        dump(ToolCallRequest.self)
        // Also let's try to instantiate it (it has an init from GeneratedContent)
}
#endif
