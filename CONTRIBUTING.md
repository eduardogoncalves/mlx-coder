# Contributing to mlx-coder

Thank you for your interest in contributing! mlx-coder focuses on local LLM execution on macOS using a native MLX architecture, with an emphasis on production-grade Swift development, system design, and security practices.

## Code of Conduct

Be respectful, inclusive, and constructive in all interactions.

## Getting Started

### Prerequisites

- **macOS 14+** (Sonoma or later)
- **Apple Silicon** (M1 or later)
- **Swift 5.12+** / Xcode 16+
- A local MLX model at `~/models/Qwen/Qwen3.5-9B-4bit` for testing

### Development Setup

```bash
# Clone the repository
git clone https://github.com/eduardogoncalves/mlx-coder.git
cd mlx-coder

# Build the project
swift build

# Run tests
swift test

# Build release binary
xcodebuild -scheme MLXCoder -configuration Release -destination 'platform=macOS' -derivedDataPath .build/xcode
```

## Development Guidelines

### Code Style

- **Naming**: Follow Swift naming conventions
  - Types: PascalCase (`UserSession`, `PermissionEngine`)
  - Functions/properties: camelCase (`processUserMessage`, `workspaceRoot`)
  - Constants: camelCase or UPPER_CASE depending on scope
  - Enum cases: lowerCase (`.success`, `.failed`)

- **Documentation**: All public APIs must have doc comments
  ```swift
  /// Brief description of what this does.
  ///
  /// Longer explanation with examples if complex.
  /// - Parameters:
  ///   - param1: What this parameter is for
  /// - Returns: What the function returns
  /// - Throws: What errors can be thrown
  public func myPublicFunction(_ param1: String) throws -> Result {
  ```

- **Access Control**: Use explicit access modifiers
  - Mark implementation details `private` or `fileprivate`
  - Expose only essential APIs as `public`
  - Use `nonisolated` on actor functions that don't need isolation

- **Error Handling**: Use explicit error types, not silent failures
  ```swift
  // ✅ Good
  public enum PermissionError: LocalizedError {
      case pathOutsideWorkspace(path: String, root: String)
  }
  
  // ❌ Avoid
  guard let result = try? operation() else { return nil }
  ```

### Architecture

The project is organized into focused modules:

```
Sources/
├── AgentCore/          # Main orchestration loop and conversation state
├── ModelEngine/        # Model loading, token generation, KV cache
├── ToolSystem/         # 30+ tools for filesystem, search, shell, etc.
│   ├── Protocol/       # Tool interface and registry
│   ├── Filesystem/     # File I/O with permission checks
│   ├── Shell/          # Bash execution and sandboxing
│   ├── Search/         # Code and web search
│   ├── LSP/            # Language server protocol integration
│   └── [other tools]
├── MemoryManagement/   # Memory constraints for edge devices
└── CLI/                # Terminal UI and input handling
```

**Key Principles**:
- **Separation of Concerns**: Each module has one responsibility
- **Dependency Injection**: Tools receive permissions, registry, etc. via constructor
- **Actor-based Concurrency**: Critical shared state protected by actors
- **Type Safety**: Prefer compile-time validation over runtime checks

### Security Practices

1. **Path Validation**: Always use `PermissionEngine.validatePath()` before file operations
   ```swift
   let safePath = try permissions.validatePath(userInput)
   // safePath is guaranteed to be within workspace root
   ```

2. **Environment Isolation**: When spawning processes, use whitelisted env vars
   ```swift
   let safeEnv = ["PATH", "HOME", "LANG"]  // Only these
   process.environment = safeEnv
   ```

3. **Error Sanitization**: Don't expose system paths in user-facing errors
   ```swift
   // ❌ Bad
   return .error("Failed: \(error.localizedDescription)")
   
   // ✅ Good
   return .error("Operation failed - check permissions")
   ```

4. **Type Checking**: Use `ToolParameters` for safe type casting
   ```swift
   public func execute(arguments: ToolParameters) async throws -> ToolResult {
       let query = try arguments.required("query", as: String.self)
       let limit = try arguments.optional("limit", as: Int.self, default: 10)
       // ...
   }
   ```

5. **No Silent Failures**: Log issues that should be visible
   ```swift
   // ❌ Avoid
   let result = try? operation()
   
   // ✅ Better
   do {
       let result = try operation()
   } catch {
       logger.warning("Operation failed: \(error)")
       return .error("Failed to complete operation")
   }
   ```

### Testing

- **Coverage Target**: 80%+ for critical paths (ToolSystem, PermissionEngine)
- **Test Location**: Place tests in `Tests/` with matching module structure
- **Security Tests**: All security fixes must include tests
  ```swift
  func testSymlinkEscape() async throws {
      // Verify that symlinks pointing outside workspace are caught
      let path = "/workspace/trap -> /etc"
      XCTAssertThrowsError(try permissions.validatePath(path))
  }
  ```

- **Run Tests**:
  ```bash
  # All tests
  swift test
  
  # Specific module
  swift test --filter ToolSystem
  
  # With coverage
  swift test --enable-code-coverage
  ```

### Commit Message Format

Follow conventional commits for clarity:

```
<type>(<scope>): <subject>

<body>

<footer>
```

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `chore`
Scopes: `ToolSystem`, `Security`, `LSP`, `ModelEngine`, etc.

Examples:
```
feat(ToolSystem): Add file integrity verification to WriteFileTool

- Compute SHA256 of written file
- Verify against expected hash
- Return hash in tool result for agent verification

Fixes #42
```

```
security(PermissionEngine): Fix symlink TOCTOU vulnerability

Resolve all symbolic links before validation to prevent race condition
where symlinks are created after path check but before operation.

Closes SECURITY-2024-001
```

## Submitting Changes

1. **Fork** the repository
2. **Create a branch**: `git checkout -b feature/your-feature`
3. **Make changes** following the guidelines above
4. **Test thoroughly**: `swift test` must pass
5. **Verify compilation**: `swift build` succeeds
6. **Commit** with meaningful messages
7. **Push** to your fork
8. **Open a Pull Request** with:
   - Clear description of changes
   - Link to related issues
   - Screenshots if UI changes
   - Test results if applicable

## Pull Request Checklist

- [ ] Code compiles without warnings/errors
- [ ] All tests pass (`swift test`)
- [ ] New public APIs have doc comments
- [ ] No hardcoded paths or credentials
- [ ] Security implications considered
- [ ] Follows code style guidelines
- [ ] Commit messages are clear and descriptive

## Documentation

- **README.md**: User-facing overview and quick start
- **SECURITY.md**: Security architecture and vulnerability disclosures
- **CHANGELOG.md**: Version history and breaking changes
- **Inline Comments**: Explain "why" not "what" - code shows what
- **Doc Comments**: All public APIs require doc comments

### Writing Good Doc Comments

```swift
/// Validates a filesystem path against workspace boundaries.
///
/// This function resolves all symbolic links and ensures the resulting
/// path starts with the workspace root. This prevents TOCTOU attacks where
/// symlinks could be manipulated to access files outside the workspace.
///
/// Example:
/// ```swift
/// let safe = try engine.validatePath("src/main.swift")
/// // safe will be absolute path like "/workspace/src/main.swift"
/// ```
///
/// - Parameter path: Relative or absolute path to validate
/// - Returns: Absolute path with symlinks resolved
/// - Throws: `PermissionError.pathOutsideWorkspace` if escape attempt detected
public func validatePath(_ path: String) throws -> String
```

## Performance Considerations

- **KV Cache Quantization**: Monitor context size; switch to 4-bit KV at 30k+ tokens
- **Tool Result Condensation**: Large outputs are automatically truncated
- **Memory Management**: Use `MemoryGuard` to stay within device limits
- **Concurrency**: Prefer actors over manual locking

## Release Process

1. Bump version in `Package.swift` and code
2. Update `CHANGELOG.md` with all changes
3. Create git tag: `git tag v0.1.0`
4. Create GitHub release with security notes
5. Update `SECURITY.md` if vulnerabilities were fixed

## Help Needed

**Areas where contributions are welcome**:
- [ ] Performance optimizations
- [ ] Expanded test coverage
- [ ] Documentation improvements
- [ ] New tool implementations
- [ ] Additional language support (Python, Node.js, Rust)

## Questions?

Open an issue with the `question` label. Maintainers will help!

---

Thank you for helping make mlx-coder a high-quality, production-grade project! 🙏
