// Sources/CodeModeWorker/main.swift
// "Code Mode" worker: runs one model-generated JavaScript program in
// JavaScriptCore and proxies every tool call the program makes back to the
// parent MLXCoder process over a newline-delimited JSON protocol on stdio.
//
// This process has NO filesystem/network/tool access of its own — every
// effect the script wants to have goes through the `tools.*` bridge below,
// which round-trips a request to the parent and blocks for its response.
// The parent enforces the real permission/approval/audit pipeline on each
// sub-call; this process only runs the interpreter.
//
// Wire protocol (see CodeModeSandboxProcess.swift for the parent side):
//   stdin,  line 1 (handshake): {"code": "...", "tools": [{"name","description","parameters"}...], "maxCalls": N}
//   stdout, per sub-call:       {"type":"call","id":"...","tool":"...","arguments":{...}}
//   stdin,  per sub-call reply: {"type":"result","id":"...","content":"...","isError":bool}
//   stdout, final message:      {"type":"done","valueJSON":"...","logs":[...],"invalidOutput":bool,"error":{"message":"..."}?}
//
// This process never reports its own timeout — a script that hangs is killed
// by the parent (process-tree kill), which is how the timeout is enforced.

import Foundation
import JavaScriptCore

// MARK: - Unbuffered line I/O

/// Reads newline-delimited lines from a file handle without relying on C
/// stdio buffering (which can deadlock a request/response protocol over a
/// pipe if a write sits in a stdio buffer instead of actually reaching the
/// other end).
final class LineReader {
    private let handle: FileHandle
    private var buffer = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func nextLine() -> String? {
        while true {
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<newlineIndex]
                buffer.removeSubrange(...newlineIndex)
                return String(data: lineData, encoding: .utf8)
            }
            // `.availableData` (not `readData(ofLength:)`) — on a pipe, the
            // latter blocks trying to fill the full requested length instead
            // of returning as soon as any bytes arrive (see BashTool.swift's
            // readability handler, which hits the same Foundation quirk).
            let chunk = handle.availableData
            if chunk.isEmpty {
                if buffer.isEmpty { return nil }
                let remainder = buffer
                buffer.removeAll()
                return String(data: remainder, encoding: .utf8)
            }
            buffer.append(chunk)
        }
    }
}

func writeLine(_ object: [String: Any], to handle: FileHandle) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    var line = data
    line.append(0x0A)
    handle.write(line)
}

func fail(_ message: String) -> Never {
    writeLine(["type": "done", "valueJSON": "null", "logs": [String](), "invalidOutput": false, "error": ["message": message]], to: FileHandle.standardOutput)
    exit(1)
}

// MARK: - Handshake

let stdin = LineReader(handle: FileHandle.standardInput)
let stdout = FileHandle.standardOutput

guard let handshakeLine = stdin.nextLine(),
      let handshakeData = handshakeLine.data(using: .utf8),
      let handshake = try? JSONSerialization.jsonObject(with: handshakeData) as? [String: Any]
else {
    fail("code mode worker: missing or invalid handshake")
}

guard let code = handshake["code"] as? String else {
    fail("code mode worker: handshake missing 'code'")
}
let toolSchemas = (handshake["tools"] as? [[String: Any]]) ?? []
let maxCalls = (handshake["maxCalls"] as? Int) ?? 200

// MARK: - JavaScriptCore context

guard let context = JSContext() else {
    fail("code mode worker: failed to create JSContext")
}

var uncaughtException: String?
context.exceptionHandler = { _, exception in
    uncaughtException = exception?.toString() ?? "unknown JavaScript exception"
}

var callCount = 0

// One native, SYNCHRONOUS callable per exposed tool. Each call blocks this
// single-threaded worker until the parent answers — safe because the worker
// never does anything else concurrently, and it means the script never needs
// real JS Promises to "await" a tool call (an `await` on a plain returned
// value just yields it immediately).
let toolsObject = JSValue(newObjectIn: context)
for schema in toolSchemas {
    guard let toolName = schema["name"] as? String else { continue }

    let binding: @convention(block) (JSValue) -> JSValue = { argsValue in
        callCount += 1
        if callCount > maxCalls {
            context.exception = JSValue(newErrorFromMessage: "execute_code: exceeded the maximum of \(maxCalls) tool calls in a single script run", in: context)
            return JSValue(undefinedIn: context)
        }

        let arguments = (argsValue.isUndefined || argsValue.isNull) ? [String: Any]() : (argsValue.toDictionary() as? [String: Any] ?? [:])
        let callID = UUID().uuidString
        writeLine(["type": "call", "id": callID, "tool": toolName, "arguments": arguments], to: stdout)

        guard let replyLine = stdin.nextLine(),
              let replyData = replyLine.data(using: .utf8),
              let reply = try? JSONSerialization.jsonObject(with: replyData) as? [String: Any]
        else {
            context.exception = JSValue(newErrorFromMessage: "execute_code: lost connection to the parent process while calling '\(toolName)'", in: context)
            return JSValue(undefinedIn: context)
        }

        let content = (reply["content"] as? String) ?? ""
        let isError = (reply["isError"] as? Bool) ?? false
        if isError {
            context.exception = JSValue(newErrorFromMessage: content, in: context)
            return JSValue(undefinedIn: context)
        }
        return JSValue(object: content, in: context)
    }
    toolsObject?.setObject(binding, forKeyedSubscript: toolName as NSString)
}
context.setObject(toolsObject, forKeyedSubscript: "tools" as NSString)

// `console.log`/`warn`/`error` capture instead of touching real stdout
// (stdout is the RPC channel). Kept as plain JS so formatting (String(...)
// on each argument) matches ordinary console semantics without extra
// native bridging.
var capturedLogs: [String] = []
let pushLog: @convention(block) (JSValue) -> Void = { value in
    capturedLogs.append(value.toString() ?? "")
}
context.setObject(pushLog, forKeyedSubscript: "__pushLog" as NSString)
context.evaluateScript("""
    var console = {
        log: function() { __pushLog(Array.prototype.slice.call(arguments).map(String).join(' ')); },
        warn: function() { __pushLog('[warn] ' + Array.prototype.slice.call(arguments).map(String).join(' ')); },
        error: function() { __pushLog('[error] ' + Array.prototype.slice.call(arguments).map(String).join(' ')); },
    };
    """)

// MARK: - Run the script

// The script runs as the body of an async function (top-level `await` and
// `return` are available). Its resolved/rejected value is captured into
// plain top-level globals (not a nested closure) by a `.then`/`.catch` pair,
// so a second `evaluateScript` call afterwards can poll them — Promise
// reactions are ALWAYS deferred to the microtask queue per spec (even for an
// already-settled promise), and `JSContext.evaluateScript` returning does
// NOT drain that queue on its own here, so the settled value cannot be read
// synchronously off the immediate return value of the first `evaluateScript`
// call. Every native tool call in this worker is itself synchronous, so the
// async function's promise settles essentially immediately; the poll loop
// below just gives JSC's microtask queue a chance to actually run.
let wrapped = """
    var __done = false, __valueJSON = "null", __invalidOutput = false, __errorMessage = null;
    (async function() {
    \(code)
    })().then(function(v) {
        __done = true;
        try { __valueJSON = JSON.stringify(v === undefined ? null : v); if (__valueJSON === undefined) { __invalidOutput = true; __valueJSON = "null"; } }
        catch (e) { __invalidOutput = true; }
    }, function(e) {
        __done = true;
        __errorMessage = (e && e.message) ? String(e.message) : String(e);
    });
    """

context.evaluateScript(wrapped)

// Fail fast on a syntax/parse error in the wrapper (most commonly: the
// model wrote code in the wrong language, e.g. Python instead of
// JavaScript). When `wrapped` fails to parse, NONE of its `var __done = ...`
// declarations ever ran, so polling for them below would only ever produce
// a second, more confusing error ("Can't find variable: __done") on every
// iteration until the poll budget is exhausted — report the real syntax
// error immediately instead.
if let uncaughtException {
    writeLine(["type": "done", "valueJSON": "null", "logs": capturedLogs, "invalidOutput": false, "error": ["message": uncaughtException]], to: stdout)
    exit(0)
}

// Poll for completion, pumping the run loop each iteration so JSC's
// microtask queue (which on Apple platforms is dispatched via libdispatch,
// not drained inline by `evaluateScript`) gets a chance to run the
// `.then`/`.catch` reactions above. A script whose synchronous body never
// returns (e.g. an infinite loop) never reaches here in the first place —
// `evaluateScript` itself blocks forever on it, and the parent process
// enforces the real timeout by killing this whole process tree. This loop
// only covers the brief, normal gap between "script returned/threw" and
// "its promise reaction actually ran".
var resultDict: [String: Any]?
for _ in 0..<20_000 {
    if let dict = context.evaluateScript("({done: __done, valueJSON: __valueJSON, invalidOutput: __invalidOutput, errorMessage: __errorMessage})")?.toDictionary() as? [String: Any],
       (dict["done"] as? Bool) == true {
        resultDict = dict
        break
    }
    if uncaughtException != nil { break }
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
}

if let uncaughtException {
    writeLine(["type": "done", "valueJSON": "null", "logs": capturedLogs, "invalidOutput": false, "error": ["message": uncaughtException]], to: stdout)
    exit(0)
}

guard let resultDict else {
    // The promise reaction never ran even after the poll budget — treat as
    // a hang rather than fabricate a success (the parent's own timeout will
    // also have fired around the same time in practice).
    writeLine(["type": "done", "valueJSON": "null", "logs": capturedLogs, "invalidOutput": false, "error": ["message": "execute_code: script did not settle in time"]], to: stdout)
    exit(0)
}

if let errorMessage = resultDict["errorMessage"] as? String {
    writeLine(["type": "done", "valueJSON": "null", "logs": capturedLogs, "invalidOutput": false, "error": ["message": errorMessage]], to: stdout)
} else {
    let invalidOutput = (resultDict["invalidOutput"] as? Bool) ?? false
    let valueJSON = (resultDict["valueJSON"] as? String) ?? "null"
    writeLine(["type": "done", "valueJSON": valueJSON, "logs": capturedLogs, "invalidOutput": invalidOutput], to: stdout)
}
exit(0)
