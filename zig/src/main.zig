// zig/src/main.zig
// mlx-coder OpenTUI host — single-process, zero-IPC Zig front-end.
//
// Architecture
//   • This binary is the main process entry point.
//   • libMLXCLib.dylib (Swift) is loaded at link time via rpath.
//   • Swift runs inference on background threads; tokens are pushed into a
//     thread-safe TokenQueue and consumed by the Zig render/input loop.
//
// Event loop
//   stdin is put into raw mode so single keystrokes can be read without
//   pressing Enter.  The loop polls stdin (non-blocking) and the token queue
//   at ~60 fps using a short nanosleep between iterations.

const std    = @import("std");
const bridge = @import("bridge.zig");
const queue  = @import("queue.zig");
const tui    = @import("tui.zig");

// ---------------------------------------------------------------------------
// Shared state (process-global, accessed from C callbacks and the main loop)
// ---------------------------------------------------------------------------

/// Global Io instance for synchronization operations
pub var g_io: std.Io = undefined;
pub var g_io_initialized = false;

/// Singleton token queue — bytes arrive from the Swift token callback.
var g_queue: queue.TokenQueue = .{};

/// Global generation-done flag — set by the Swift done callback.
var g_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Load-complete flag plus error storage.
var g_load_done:  std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var g_load_ok:    std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var g_load_error: [512]u8 = std.mem.zeroes([512]u8);

// ---------------------------------------------------------------------------
// C callbacks (called from Swift's background threads)
// ---------------------------------------------------------------------------

/// Swift calls this once per decoded token fragment.
export fn onToken(
    token:     ?[*]const u8,
    len:       usize,
    _user_data: ?*anyopaque,
) callconv(.c) void {
    _ = _user_data;
    if (token) |t| {
        g_queue.push(t[0..len]);
    }
}

/// Swift calls this once when generation is complete (or fails/cancels).
export fn onDone(
    error_msg:  ?[*:0]const u8,
    _user_data: ?*anyopaque,
) callconv(.c) void {
    _ = error_msg; // TODO: surface errors through the TUI status bar
    _ = _user_data;
    g_queue.markDone();
    g_done.store(true, .release);
}

/// Swift calls this when it wants model-load completion acknowledged.
export fn onLoad(
    success:    bool,
    error_msg:  ?[*:0]const u8,
    _user_data: ?*anyopaque,
) callconv(.c) void {
    _ = _user_data;
    if (!success) {
        if (error_msg) |msg| {
            const s = std.mem.sliceTo(msg, 0);
            const n = @min(s.len, g_load_error.len - 1);
            @memcpy(g_load_error[0..n], s[0..n]);
            g_load_error[n] = 0;
        }
    }
    g_load_ok.store(success, .release);
    g_load_done.store(true, .release);
}

/// Swift calls this when it needs interactive approval for a tool call.
export fn onApproval(
    tool_name:  ?[*:0]const u8,
    args_json:  ?[*:0]const u8,
    user_data:  ?*anyopaque,
) callconv(.c) void {
    if (user_data == null) return;
    const ui: *tui.TUI = @ptrCast(@alignCast(user_data));
    if (tool_name) |t| {
        ui.approval.set(t, args_json);
    }
}

// ---------------------------------------------------------------------------
// Terminal raw mode
// ---------------------------------------------------------------------------

const Termios = std.posix.termios;

fn enterRawMode(saved: *Termios) !void {
    saved.* = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
    var raw = saved.*;
    // Disable canonical mode, echo, and signals.
    raw.lflag.ICANON = false;
    raw.lflag.ECHO   = false;
    raw.lflag.ISIG   = false;
    // Non-blocking single-byte reads: V.MIN=0, V.TIME=0 means return
    // immediately with whatever bytes are available (0 or 1).
    // The event loop controls frame timing via nanosleep; a per-read
    // timeout would add unnecessary latency floor.
    raw.cc[@intFromEnum(std.posix.V.MIN)]  = 0;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw);
}

fn leaveRawMode(saved: *const Termios) void {
    std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, saved.*) catch {};
}

fn sleepNs(nanoseconds: u64) void {
    var ts: std.posix.timespec = .{
        .sec = @intCast(@divFloor(nanoseconds, std.time.ns_per_s)),
        .nsec = @intCast(@mod(nanoseconds, std.time.ns_per_s)),
    };
    _ = std.posix.system.nanosleep(&ts, &ts);
}

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

const Args = struct {
    model_path: [:0]const u8,
};

fn parseArgs(proc_args: std.process.Args, arena: std.mem.Allocator) !Args {
    const argv = try proc_args.toSlice(arena);
    if (argv.len < 2) {
        std.debug.print(
            \\Usage: mlx-coder-tui <model-path>
            \\
            \\  model-path  Path to a local model directory (e.g. ~/models/Qwen/Qwen3-4B-4bit)
            \\              or a Hugging Face Hub ID (e.g. Qwen/Qwen3-4B-4bit).
            \\
        , .{});
        return error.MissingModelPath;
    }
    return Args{ .model_path = argv[1] };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    g_io = init.io;
    g_io_initialized = true;
    defer g_io_initialized = false;

    const arena = init.arena;
    const allocator = arena.allocator();

    const args = try parseArgs(init.minimal.args, allocator);

    // --- Create MLXCLib session -------------------------------------------
    const session = bridge.mlxclib_session_create() orelse {
        std.debug.print("mlxclib_session_create() returned NULL\n", .{});
        return error.SessionCreateFailed;
    };
    defer bridge.mlxclib_session_destroy(session);

    // --- Initialise TUI ------------------------------------------------------
    var ui = tui.TUI.init(allocator, &g_queue);
    defer ui.deinit();

    ui.setModelName(args.model_path);

    try ui.enter();
    defer ui.leave() catch {};

    // Set the approval callback so Swift can ask for tool approval.
    bridge.mlxclib_set_approval_handler(session, onApproval, &ui);

    // --- Kick off model loading ----------------------------------------------
    const model_path_z = try allocator.dupeZ(u8, args.model_path);
    defer allocator.free(model_path_z);

    bridge.mlxclib_load_model(session, model_path_z.ptr, onLoad, null);

    // Status message while loading
    var msg_buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&msg_buf, "\r{s}Loading model: {s}…{s}\n", .{
        "\x1b[33m", args.model_path, "\x1b[0m",
    });
    try std.Io.File.writeStreamingAll(std.Io.File.stdout(), g_io, msg);

    // Wait for model to load (poll; render loop hasn't started yet).
    while (!g_load_done.load(.acquire)) {
        sleepNs(50 * std.time.ns_per_ms);
    }

    if (!g_load_ok.load(.acquire)) {
        try ui.leave();
        const errMsg = std.mem.sliceTo(&g_load_error, 0);
        std.debug.print("Model load failed: {s}\n", .{errMsg});
        return error.ModelLoadFailed;
    }

    // Repaint status bar now that the model is ready.
    try ui.repaint(session);

    // --- Enter raw mode and start event loop --------------------------------
    var saved_termios: Termios = undefined;
    try enterRawMode(&saved_termios);
    defer leaveRawMode(&saved_termios);

    const frame_ns: u64 = 16 * std.time.ns_per_ms; // ~60 fps

    var running = true;
    while (running) {
        const frame_start = g_io.vtable.now(g_io.userdata, .real).nanoseconds;

        // -- Process keyboard input -----------------------------------------
        var byte: [1]u8 = undefined;
        const n = std.posix.read(std.posix.STDIN_FILENO, &byte) catch 0;
        if (n == 1) {
            switch (byte[0]) {
                // Ctrl-C / Ctrl-D → quit
                3, 4 => {
                    if (ui.generating) {
                        bridge.mlxclib_cancel(session);
                    } else {
                        running = false;
                    }
                },
                // Enter → submit prompt
                '\r', '\n' => {
                    if (ui.approval.pending and !ui.approval.answered) {
                        // Default: allow
                        ui.approval.answered = true;
                        ui.approval.approved = true;
                        bridge.mlxclib_approval_respond(session, true, null);
                    } else if (!ui.generating) {
                        const prompt = ui.takeInput();
                        if (prompt.len > 0) {
                            ui.generating = true;
                            g_done.store(false, .release);
                            g_queue.reset();
                            try submitPrompt(allocator, session, prompt);
                        }
                    }
                },
                // Backspace
                127, 8 => {
                    if (ui.approval.pending and !ui.approval.answered) {
                        // do nothing during modal
                    } else {
                        ui.backspaceInput();
                    }
                },
                // ESC → cancel generation or deny approval
                0x1b => {
                    if (ui.approval.pending and !ui.approval.answered) {
                        ui.approval.answered = true;
                        ui.approval.approved = false;
                        bridge.mlxclib_approval_respond(session, false, null);
                    } else if (ui.generating) {
                        bridge.mlxclib_cancel(session);
                    }
                },
                // 'y' / 'n' / 's' in approval modal
                'y' => {
                    if (ui.approval.pending and !ui.approval.answered) {
                        ui.approval.answered = true;
                        ui.approval.approved = true;
                        bridge.mlxclib_approval_respond(session, true, null);
                    } else {
                        ui.appendInputByte(byte[0]);
                    }
                },
                'n' => {
                    if (ui.approval.pending and !ui.approval.answered) {
                        ui.approval.answered = true;
                        ui.approval.approved = false;
                        bridge.mlxclib_approval_respond(session, false, null);
                    } else {
                        ui.appendInputByte(byte[0]);
                    }
                },
                's' => {
                    if (ui.approval.pending and !ui.approval.answered) {
                        // Session-allow (same as allow for now)
                        ui.approval.answered = true;
                        ui.approval.approved = true;
                        bridge.mlxclib_approval_respond(session, true, null);
                    } else {
                        ui.appendInputByte(byte[0]);
                    }
                },
                // Printable ASCII (excluding n=110, s=115, y=121)
                32...109 => ui.appendInputByte(byte[0]),
                111...114 => ui.appendInputByte(byte[0]),
                116...120 => ui.appendInputByte(byte[0]),
                122...126 => ui.appendInputByte(byte[0]),
                else => {},
            }
        }

        // -- Drain token queue -----------------------------------------------
        _ = try ui.drainQueue();

        // -- Check if generation finished ------------------------------------
        if (ui.generating and g_done.load(.acquire)) {
            ui.generating = false;
            ui.approval.pending  = false;
            ui.approval.answered = false;
            // Emit newline after response
            try std.Io.File.writeStreamingAll(std.Io.File.stdout(), g_io, "\n");
        }

        // -- Periodic repaint ------------------------------------------------
        try ui.repaint(session);

        // -- Frame-rate cap --------------------------------------------------
        const frame_end = g_io.vtable.now(g_io.userdata, .real).nanoseconds;
        const elapsed = @as(u64, @intCast(frame_end - frame_start));
        if (elapsed < frame_ns) {
            sleepNs(frame_ns - elapsed);
        }
    }
}

// ---------------------------------------------------------------------------
// Submit a user prompt
// ---------------------------------------------------------------------------

fn submitPrompt(
    allocator: std.mem.Allocator,
    session:   bridge.MLXCSession,
    prompt:    []const u8,
) !void {
    var msg_buf: [512]u8 = undefined;
    const msg = try std.fmt.bufPrint(&msg_buf, "\n{s}You:{s} {s}\n{s}Assistant:{s} ", .{
        "\x1b[1;32m", "\x1b[0m", prompt,
        "\x1b[1;36m", "\x1b[0m",
    });
    try std.Io.File.writeStreamingAll(std.Io.File.stdout(), g_io, msg);

    const prompt_z = try allocator.dupeZ(u8, prompt);
    defer allocator.free(prompt_z);

    bridge.mlxclib_generate(session, prompt_z.ptr, onToken, onDone, null);
}
