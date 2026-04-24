// zig/src/bridge.zig
// Zig bindings to the MLXCLib C ABI declared in Sources/MLXCLib/include/mlxclib.h.
//
// All extern declarations mirror the C typedefs/structs exactly so that the
// linker can resolve them against libMLXCLib.dylib at runtime.

const std = @import("std");

// ---------------------------------------------------------------------------
// Opaque session handle
// ---------------------------------------------------------------------------

pub const MLXCSession = ?*anyopaque;

// ---------------------------------------------------------------------------
// Callback signatures (must match mlxclib.h typedefs exactly)
// ---------------------------------------------------------------------------

pub const MLXCTokenCallback = *const fn (
    token:     ?[*]const u8,
    len:       usize,
    user_data: ?*anyopaque,
) callconv(.c) void;

pub const MLXCDoneCallback = *const fn (
    error_msg: ?[*:0]const u8,
    user_data: ?*anyopaque,
) callconv(.c) void;

pub const MLXCLoadCallback = *const fn (
    success:   bool,
    error_msg: ?[*:0]const u8,
    user_data: ?*anyopaque,
) callconv(.c) void;

pub const MLXCApprovalCallback = *const fn (
    tool_name: ?[*:0]const u8,
    args_json: ?[*:0]const u8,
    user_data: ?*anyopaque,
) callconv(.c) void;

// ---------------------------------------------------------------------------
// Observability snapshot (must match MLXCStats in mlxclib.h byte-for-byte)
// ---------------------------------------------------------------------------

pub const MLXCStats = extern struct {
    token_latency_ms: f64,    // offset  0
    tokens_per_sec:   f64,    // offset  8
    tokens_generated: u64,    // offset 16
    model_loaded:     i32,    // offset 24
    _pad:             i32,    // offset 28 — reserved
};

// ---------------------------------------------------------------------------
// Extern declarations for every symbol exported by libMLXCLib.dylib
// ---------------------------------------------------------------------------

pub extern "MLXCLib" fn mlxclib_session_create() MLXCSession;
pub extern "MLXCLib" fn mlxclib_session_destroy(session: MLXCSession) void;

pub extern "MLXCLib" fn mlxclib_load_model(
    session:    MLXCSession,
    model_path: ?[*:0]const u8,
    callback:   MLXCLoadCallback,
    user_data:  ?*anyopaque,
) void;

pub extern "MLXCLib" fn mlxclib_generate(
    session:   MLXCSession,
    prompt:    ?[*:0]const u8,
    token_cb:  ?MLXCTokenCallback,
    done_cb:   MLXCDoneCallback,
    user_data: ?*anyopaque,
) void;

pub extern "MLXCLib" fn mlxclib_cancel(session: MLXCSession) void;

pub extern "MLXCLib" fn mlxclib_set_approval_handler(
    session:   MLXCSession,
    callback:  ?MLXCApprovalCallback,
    user_data: ?*anyopaque,
) void;

pub extern "MLXCLib" fn mlxclib_approval_respond(
    session:    MLXCSession,
    approved:   bool,
    suggestion: ?[*:0]const u8,
) void;

pub extern "MLXCLib" fn mlxclib_get_stats(
    session:   MLXCSession,
    out_stats: *MLXCStats,
) void;
