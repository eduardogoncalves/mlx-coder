# Security Policy

mlx-coder is designed for local LLM workflows on macOS with a native, in-process MLX architecture. This document outlines the security measures implemented and how to report vulnerabilities.

## Security Architecture

### Principles

1. **Zero Trust for Tool Operations**: All filesystem and shell operations are validated against workspace boundaries
2. **Least Privilege**: Tool execution runs with whitelisted environment variables only
3. **Sandboxing**: Shell commands execute inside macOS Seatbelt sandbox (when enabled)
4. **Type Safety**: Parameters are validated at compile-time using Swift's type system
5. **Strict Parsing**: JSON inputs are parsed strictly without fallback token insertion

### Core Security Components

#### Path Validation (`PermissionEngine`)
- All paths are resolved relative to workspace root
- Symlinks are fully resolved to prevent TOCTOU (Time-of-Check-Time-of-Use) attacks
- Filesystem tools validate paths both before and after operations
- Parent directories are re-validated after creation to prevent race conditions

#### Environment Isolation (`BashTool`)
- Only whitelisted environment variables are inherited: `PATH`, `HOME`, `USER`, `LANG`, `LC_ALL`, `TERM`
- Dangerous variables are blocked: `LD_LIBRARY_PATH`, `DYLD_INSERT_LIBRARIES`, `IFS`, `PS4`
- This prevents library injection and shell escaping attacks

#### Command Injection Prevention
- Shell commands are quoted and escaped before sandbox wrapping
- Glob patterns use fnmatch(3) for proper matching semantics
- JSON-RPC inputs are parsed strictly (no fallback token insertion)

#### Error Handling
- Error messages are sanitized to avoid information disclosure
- System paths and implementation details are not exposed in user-facing output
- Internal errors are logged but not propagated to the user

## Vulnerability Disclosures

This project has implemented fixes for the following vulnerability categories.

### Critical Vulnerabilities (Fixed)

1. **Sandbox Command Injection (CWE-94)**
   - **Issue**: Unquoted command parameters in sandbox-exec invocation
   - **Risk**: Arbitrary code execution, escaping sandbox restrictions
   - **Fix**: Quote command parameter with proper escaping
   - **Status**: ✅ Fixed

2. **Symlink TOCTOU (CWE-367)**
   - **Issue**: Path validation didn't resolve symlinks, allowing race condition attacks
   - **Risk**: Reading/writing files outside workspace bounds
   - **Fix**: Use `resolvingSymlinksInPath()` to fully resolve all symbolic links
   - **Status**: ✅ Fixed

3. **Server-Side Request Forgery / SSRF (CWE-918)**
   - **Issue**: `WebFetchTool` accepted arbitrary URLs without validating the target host, allowing requests to loopback addresses, private network ranges, and cloud-provider metadata endpoints (e.g. `169.254.169.254`)
   - **Risk**: Exfiltration of instance metadata, access to internal services, port scanning of private networks
   - **Fix**: `URLFetchValidator` enforces HTTP/HTTPS-only schemes and rejects loopback (`127.x`, `::1`, `localhost`), link-local/metadata (`169.254.x.x`), and all RFC 1918 private ranges (`10.x`, `172.16-31.x`, `192.168.x`)
   - **Status**: ✅ Fixed

### High Vulnerabilities (Fixed)

4. **Unsafe Environment Variable Inheritance (CWE-15)**
   - **Issue**: Child processes inherited full parent environment
   - **Risk**: Library injection via `LD_LIBRARY_PATH`, shell escaping via `IFS`/`PS4`
   - **Fix**: Whitelist safe environment variables only (applied to both `BashTool` shell commands and MCP stdio processes)
   - **Status**: ✅ Fixed

5. **MCP Endpoint Scheme Injection (CWE-918)**
   - **Issue**: `MCPClient` accepted any URL scheme for HTTP transport endpoints, including `file://` and custom schemes
   - **Risk**: Local file exfiltration or exploitation of custom protocol handlers
   - **Fix**: `resolveTransport` validates that only `http://` and `https://` schemes are accepted; all other schemes throw `invalidEndpoint`
   - **Status**: ✅ Fixed

6. **Workspace Config Security Downgrade (CWE-284)**
   - **Issue**: A workspace-local `.mlx-coder-config.json` could override the user's global `defaultApprovalMode` to `yolo` (no-prompt) or disable `defaultSandbox`, silently reducing security without user awareness
   - **Risk**: Malicious or misconfigured workspace configs could disable security guardrails, enabling arbitrary command execution without user approval
   - **Fix**: `RuntimeConfigLoader.loadMerged` now applies a security-floor policy: approval mode always uses the *more restrictive* value between user and workspace configs; sandbox is kept enabled if the user's global config enables it
   - **Status**: ✅ Fixed

7. **Symlink Following in File Operations (CWE-59)**
   - **Issue**: Directory listing and writes followed symlinks without validation
   - **Risk**: Revealing system structure, overwriting out-of-workspace files
   - **Fix**: Validate symlinks at each step, skip items that fail validation
   - **Status**: ✅ Fixed

8. **Weak JSON Deserialization (CWE-20)**
   - **Issue**: JSON parser accepted malformed inputs via token-appending fallbacks
   - **Risk**: Injection of unexpected payloads, logic bypass
   - **Fix**: Enforce strict JSON-only parsing, remove fallback modes
   - **Status**: ✅ Fixed

### Medium Vulnerabilities (Fixed)

9. **Information Disclosure in Error Messages (CWE-209)**
   - **Issue**: Error messages exposed full filesystem paths and implementation details
   - **Risk**: Information gathering for targeted attacks
   - **Fix**: Generic error messages, internal logging only
   - **Status**: ✅ Fixed

10. **Unsafe Type Casting (CWE-179)**
    - **Issue**: Forced cast `as!` in code search deduplication
    - **Risk**: Potential crashes from type inconsistency
    - **Fix**: Safe cast with fallback to original results
    - **Status**: ✅ Fixed

11. **Glob Pattern Bypass (CWE-433)**
    - **Issue**: Simple regex substitution for glob matching
    - **Risk**: Bypass allow/deny rules with regex metacharacters
    - **Fix**: Use fnmatch(3) for proper POSIX glob semantics
    - **Status**: ✅ Fixed

12. **Regex Template Injection (CWE-94)**
    - **Issue**: Regex template substitution could leak capture groups
    - **Risk**: Information disclosure or unexpected behavior
    - **Fix**: Use direct string replacement instead of templates
    - **Status**: ✅ Fixed

13. **Missing Model Integrity Verification (CWE-353)**
    - **Issue**: No validation that model files haven't been tampered with
    - **Risk**: Running backdoored model weights
    - **Fix**: Document requirement for model hash verification
    - **Status**: 🟡 Documented limitation

## Known Limitations

### Apple Silicon Only
- MLX-Swift requires Apple Silicon (M1/M2+) and macOS 14+
- No Linux or Intel support currently

### Model Path Hardcoding
- Default model path is hardcoded: `~/models/Qwen/Qwen3.5-9B-4bit`
- Future versions should make this fully configurable
- Users should verify model file integrity before use

### Sandbox Functionality
- Seatbelt sandboxing works on macOS 10.5+
- Default sandbox profile allows network access for AI tooling flexibility; set `networkPolicy: .deny` on `SandboxEngine` to block outbound connections for offline workloads
- More restrictive profiles can be implemented if needed

## Responsible Disclosure

If you discover a security vulnerability in mlx-coder:

1. **Do not** open a public issue
2. Email security details to the maintainers with:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if applicable)
3. Allow 90 days for remediation before public disclosure
4. Credit will be given in security advisories

## Security Testing

The project includes security-focused unit tests:

```bash
swift test --filter ToolSystem
```

Tests cover:
- Path validation and symlink handling
- Command injection prevention
- JSON parsing strictness
- Error message sanitization

## Future Security Enhancements

- [ ] Model file integrity verification (SHA256 hashes)
- [ ] Support for user-configurable sandbox profiles
- [ ] Rate limiting on tool execution
- [ ] Formal security audit by third party
- [ ] CPU/memory resource limits for sandboxed shell commands via `setrlimit(2)` or launchd job policies
- [ ] SSRF protection for `WebSearchTool` (apply same `URLFetchValidator` logic)

## References

- [OWASP Top 10](https://owasp.org/Top10/)
- [CWE/SANS Top 25](https://cwe.mitre.org/top25/)
- [Apple Security Guide](https://developer.apple.com/library/archive/documentation/Security/Conceptual/SecureCodingGuide/)
- [MLX-Swift Documentation](https://github.com/ml-explore/mlx-swift)

## Version History

- **v0.1.0** (Current): Initial public release with security hardening and documented limitations

---

**Last Updated**: March 2026
