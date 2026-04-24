// zig/src/tui.zig
// Terminal UI for mlx-coder running on top of raw ANSI/VT100 escape codes.
//
// Layout (80+ column terminal assumed)
// ┌─────────────────────────────────────────────────┐
// │  [model: <name>]  [tokens/s: N.N]   mlx-coder  │  ← status bar (row 1)
// │                                                 │
// │  <conversation history scrolls here>            │  ← output area
// │                                                 │
// │  > user input line                              │  ← input line (last - 1)
// └─────────────────────────────────────────────────┘
//
// Thread-safety
//   All rendering happens on the main Zig thread.  Swift callbacks push bytes
//   into a TokenQueue; the render loop drains it at ~60 fps via drainQueue().

const std    = @import("std");
const queue  = @import("queue.zig");
const bridge = @import("bridge.zig");
const main   = @import("main.zig");
const spinner = @import("spinner.zig");
const messages = @import("messages.zig");
const message_renderer = @import("message_renderer.zig");

// ANSI escape helpers
const ESC  = "\x1b[";
const HIDE_CURSOR    = "\x1b[?25l";
const SHOW_CURSOR    = "\x1b[?25h";
const RESET          = "\x1b[0m";
const BOLD           = "\x1b[1m";
const DIM            = "\x1b[2m";
const GREEN          = "\x1b[32m";
const CYAN           = "\x1b[36m";
const YELLOW         = "\x1b[33m";
const BLUE           = "\x1b[34m";
const MAGENTA        = "\x1b[35m";
const CLEAR_SCREEN   = "\x1b[2J\x1b[H";
const CLEAR_LINE     = "\x1b[2K";
const SAVE_CURSOR    = "\x1b[s";
const RESTORE_CURSOR = "\x1b[u";
const ALT_ON         = "\x1b[?1049h"; // switch to alternate screen buffer
const ALT_OFF        = "\x1b[?1049l";

// ---------------------------------------------------------------------------
// Approval modal state
// ---------------------------------------------------------------------------

pub const ApprovalRequest = struct {
    tool_name: [256]u8 = std.mem.zeroes([256]u8),
    args_json: [1024]u8 = std.mem.zeroes([1024]u8),
    pending:   bool     = false,
    answered:  bool     = false,
    approved:  bool     = false,

    pub fn set(self: *ApprovalRequest, tool: [*:0]const u8, args: ?[*:0]const u8) void {
        _ = std.fmt.bufPrint(&self.tool_name, "{s}", .{tool}) catch {};
        if (args) |a| {
            _ = std.fmt.bufPrint(&self.args_json, "{s}", .{a}) catch {};
        } else {
            self.args_json[0] = 0;
        }
        self.pending  = true;
        self.answered = false;
        self.approved = false;
    }

    pub fn toolSlice(self: *const ApprovalRequest) []const u8 {
        return std.mem.sliceTo(&self.tool_name, 0);
    }

    pub fn argsSlice(self: *const ApprovalRequest) []const u8 {
        return std.mem.sliceTo(&self.args_json, 0);
    }
};

// ---------------------------------------------------------------------------
// TUI state
// ---------------------------------------------------------------------------

pub const TUI = struct {
    allocator:   std.mem.Allocator,
    io:          std.Io,

    // Terminal dimensions
    term_rows:   u16 = 24,
    term_cols:   u16 = 80,

    // Token streaming
    token_queue: *queue.TokenQueue,
    response_buf: [16384]u8 = undefined,  // accumulates the current assistant response
    response_len: usize = 0,

    // Message history for enhanced OpenCode-like rendering
    message_history: messages.MessageHistory,
    
    // Input
    input_buf:   [4096]u8 = undefined,
    input_len:   usize    = 0,

    // Approval
    approval: ApprovalRequest = .{},

    // State flags
    generating:  bool = false,
    model_name:  [256]u8 = std.mem.zeroes([256]u8),

    // Animation frame counter for spinner
    frame_count: usize = 0,

    // Stats cache (refreshed before each status-bar repaint)
    last_stats:  bridge.MLXCStats = std.mem.zeroes(bridge.MLXCStats),
    
    // Layout tracking for multi-pane display
    scroll_offset: usize = 0,  // Current scroll position in message history
    max_visible_messages: usize = 100,  // Max messages to render on screen

    // ---------------------------------------------------------------------------

    pub fn init(allocator: std.mem.Allocator, tq: *queue.TokenQueue) TUI {
        return .{
            .allocator    = allocator,
            .io           = main.g_io,
            .token_queue  = tq,
            .message_history = messages.MessageHistory.init(allocator),
        };
    }

    pub fn deinit(self: *TUI) void {
        self.message_history.deinit();
    }

    fn printFmt(self: *TUI, comptime fmt: []const u8, args: anytype) !void {
        var buf: [4096]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, fmt, args);
        try std.Io.File.writeStreamingAll(std.Io.File.stdout(), self.io, text);
    }

    fn writeAll(self: *TUI, text: []const u8) !void {
        try std.Io.File.writeStreamingAll(std.Io.File.stdout(), self.io, text);
    }

    // -----------------------------------------------------------------------
    // Setup / teardown
    // -----------------------------------------------------------------------

    pub fn enter(self: *TUI) !void {
        self.queryTermSize();
        try std.Io.File.writeStreamingAll(std.Io.File.stdout(), self.io, ALT_ON);
        try std.Io.File.writeStreamingAll(std.Io.File.stdout(), self.io, CLEAR_SCREEN);
        try std.Io.File.writeStreamingAll(std.Io.File.stdout(), self.io, HIDE_CURSOR);
        try self.drawStatusBar();
        try self.drawInputLine();
        try std.Io.File.writeStreamingAll(std.Io.File.stdout(), self.io, SHOW_CURSOR);
    }

    pub fn leave(self: *TUI) !void {
        try std.Io.File.writeStreamingAll(std.Io.File.stdout(), self.io, ALT_OFF);
        try std.Io.File.writeStreamingAll(std.Io.File.stdout(), self.io, SHOW_CURSOR);
        try std.Io.File.writeStreamingAll(std.Io.File.stdout(), self.io, RESET);
    }

    // -----------------------------------------------------------------------
    // Terminal size
    // -----------------------------------------------------------------------

    fn queryTermSize(self: *TUI) void {
        var ws: std.posix.winsize = undefined;
        // TIOCGWINSZ ioctl number is macOS/BSD-specific (0x40087468).
        // This entire TUI module targets macOS only, matching the MLX requirement.
        const TIOCGWINSZ: u32 = 0x40087468;
        const rc = std.posix.system.ioctl(
            std.posix.STDOUT_FILENO,
            TIOCGWINSZ,
            @intFromPtr(&ws),
        );
        if (rc == 0) {
            self.term_rows = ws.row;
            self.term_cols = ws.col;
        }
    }

    // -----------------------------------------------------------------------
    // Status bar (row 1)
    // -----------------------------------------------------------------------

    fn drawStatusBar(self: *TUI) !void {
        // Move to top-left, clear line
        try self.printFmt("{s}1;1H{s}", .{ ESC, CLEAR_LINE });

        const modelLabel = std.mem.sliceTo(&self.model_name, 0);
        const speed = self.last_stats.tokens_per_sec;
        const loaded = self.last_stats.model_loaded != 0;

        if (loaded) {
            // Format: ╭─ mlx-coder ─ model: <name> ─ 12.3 tok/s
            try self.printFmt(
                BOLD ++ "╭─ " ++ CYAN ++ "mlx-coder" ++ RESET ++ BOLD ++ " ─ " ++ RESET ++
                "model: {s}" ++
                DIM ++ "  ({d:.1} tok/s)" ++ RESET,
                .{ modelLabel, speed }
            );
        } else {
            // Format: ╭─ mlx-coder ─ loading model…
            try self.printFmt(
                BOLD ++ "╭─ " ++ CYAN ++ "mlx-coder" ++ RESET ++ BOLD ++ " ─ " ++ RESET ++
                DIM ++ "loading model…" ++ RESET,
                .{}
            );
        }
    }

    // -----------------------------------------------------------------------
    // Output area: append a new line of text
    // -----------------------------------------------------------------------

    pub fn appendOutput(self: *TUI, text: []const u8, comptime color: []const u8) !void {
        // Move to row 2, scroll area start; append at current cursor position.
        try self.printFmt("{s}{s}{s}", .{ color, text, RESET });
    }

    // -----------------------------------------------------------------------
    // Input line (second-to-last row)
    // -----------------------------------------------------------------------

    fn drawInputLine(self: *TUI) !void {
        const row = self.term_rows;
        try self.printFmt("{s}{d};1H{s}", .{ ESC, row, CLEAR_LINE });

        if (self.generating) {
            // Show animated spinner with cyan color
            const frame = spinner.getFrame(self.frame_count);
            try self.printFmt("{s}  {s}  {s}", .{ CYAN, frame, RESET });
        } else {
            try self.writeAll(GREEN ++ "> " ++ RESET);
        }
        try self.writeAll(self.input_buf[0..self.input_len]);
    }

    // -----------------------------------------------------------------------
    // Approval modal
    // -----------------------------------------------------------------------

    pub fn drawApprovalModal(self: *TUI) !void {
        const midRow = self.term_rows / 2 - 2;
        const midCol: u16 = @intCast(@max(1, @divTrunc(@as(i32, self.term_cols) - 60, 2)));

        // Box top
        try self.printFmt("{s}{d};{d}H", .{ ESC, midRow, midCol });
        try self.writeAll(BOLD ++ YELLOW);
        try self.writeAll("┌──────────────────────────────────────────────────────────┐");
        try self.printFmt("{s}{d};{d}H", .{ ESC, midRow + 1, midCol });
        try self.printFmt("│  Tool approval required: {s:<32}  │",
            .{ self.approval.toolSlice() });
        try self.printFmt("{s}{d};{d}H", .{ ESC, midRow + 2, midCol });
        try self.writeAll("│                                                            │");
        try self.printFmt("{s}{d};{d}H", .{ ESC, midRow + 3, midCol });
        try self.printFmt("│  Args: {s:<52}  │",
            .{ self.approval.argsSlice()[0..@min(self.approval.argsSlice().len, 52)] });
        try self.printFmt("{s}{d};{d}H", .{ ESC, midRow + 4, midCol });
        try self.writeAll("│                                                            │");
        try self.printFmt("{s}{d};{d}H", .{ ESC, midRow + 5, midCol });
        try self.writeAll("│  [y] Allow once   [n] Deny   [s] Session-allow            │");
        try self.printFmt("{s}{d};{d}H", .{ ESC, midRow + 6, midCol });
        try self.writeAll("└──────────────────────────────────────────────────────────┘" ++ RESET);
    }

    // -----------------------------------------------------------------------
    // Token draining — called each frame by the render loop
    // -----------------------------------------------------------------------

    /// Drain all available bytes from the token queue and render them.
    /// Returns true if there is still more data pending.
    pub fn drainQueue(self: *TUI) !bool {
        var tmp: [256]u8 = undefined;
        var any = false;
        while (true) {
            const n = self.token_queue.pop(&tmp);
            if (n == 0) break;
            any = true;
            // Append to response buffer if space available
            if (self.response_len + n <= self.response_buf.len) {
                @memcpy(self.response_buf[self.response_len..self.response_len + n], tmp[0..n]);
                self.response_len += n;
            }
            try self.appendOutput(tmp[0..n], "");
        }
        return any;
    }

    // -----------------------------------------------------------------------
    // Full-frame repaint
    // -----------------------------------------------------------------------

    pub fn repaint(self: *TUI, session: bridge.MLXCSession) !void {
        // Refresh stats
        bridge.mlxclib_get_stats(session, &self.last_stats);

        try self.writeAll(CLEAR_SCREEN);
        try self.drawStatusBar();
        
        // Draw response output area (rows 2-N)
        try self.printFmt("{s}2;1H", .{ ESC });
        if (self.response_len > 0) {
            try self.writeAll(CYAN);
            try self.writeAll(self.response_buf[0..self.response_len]);
            try self.writeAll(RESET);
        }
        
        if (self.approval.pending and !self.approval.answered) {
            try self.drawApprovalModal();
        }
        try self.drawInputLine();
    }

    // -----------------------------------------------------------------------
    // Input helpers
    // -----------------------------------------------------------------------

    pub fn appendInputByte(self: *TUI, b: u8) void {
        if (self.input_len < self.input_buf.len - 1) {
            self.input_buf[self.input_len] = b;
            self.input_len += 1;
        }
    }

    pub fn backspaceInput(self: *TUI) void {
        if (self.input_len > 0) self.input_len -= 1;
    }

    pub fn takeInput(self: *TUI) []const u8 {
        const s = self.input_buf[0..self.input_len];
        self.input_len = 0;
        return s;
    }

    pub fn setModelName(self: *TUI, name: []const u8) void {
        const n = @min(name.len, self.model_name.len - 1);
        @memcpy(self.model_name[0..n], name[0..n]);
        self.model_name[n] = 0;
    }
    
    // -----------------------------------------------------------------------
    // Enhanced message handling for OpenCode-like rendering
    // -----------------------------------------------------------------------
    
    /// Add a thinking message to history
    pub fn addThinkingMessage(self: *TUI, content: []const u8) !void {
        const msg = try messages.ThinkingMessage.create(self.allocator, content);
        try self.message_history.append(msg);
    }
    
    /// Add a tool call message to history
    pub fn addToolCallMessage(self: *TUI, tool_name: []const u8, args_json: []const u8) !void {
        const msg = try messages.ToolCallMessage.create(self.allocator, tool_name, args_json);
        try self.message_history.append(msg);
    }
    
    /// Add a tool result message to history
    pub fn addToolResultMessage(self: *TUI, tool_name: []const u8, success: bool, result: []const u8) !void {
        const msg = try messages.ToolResultMessage.create(self.allocator, tool_name, success, result);
        try self.message_history.append(msg);
    }
    
    /// Add a status message to history
    pub fn addStatusMessage(self: *TUI, text: []const u8, is_error: bool) !void {
        const msg = try messages.StatusMessage.create(self.allocator, text, is_error);
        try self.message_history.append(msg);
    }
    
    /// Render the message history in the content pane
    fn renderMessageHistory(self: *TUI) !void {
        const msg_count = self.message_history.getCount();
        if (msg_count == 0) return;
        
        // Position cursor at content start (row 2, after status bar)
        try self.printFmt("{s}2;1H", .{ ESC });
        
        const start_idx = if (self.scroll_offset > msg_count)
            0
        else
            msg_count - self.scroll_offset;
        
        var idx = start_idx;
        var row: u16 = 2;
        const max_rows = self.term_rows - 3;  // Leave room for status and input
        
        while (idx < msg_count and row < max_rows) {
            if (self.message_history.getMessage(idx)) |msg| {
                // Render message (simplified - in real implementation would handle wrapping)
                const rendered = message_renderer.MessageRenderer.renderMessage(msg, self.term_cols);
                try self.writeAll(rendered);
                row += @intCast(std.mem.count(u8, rendered, "\n"));
            }
            idx += 1;
        }
    }
    
    /// Scroll message history up
    pub fn scrollUp(self: *TUI) void {
        if (self.scroll_offset < 50) {
            self.scroll_offset += 1;
        }
    }
    
    /// Scroll message history down
    pub fn scrollDown(self: *TUI) void {
        if (self.scroll_offset > 0) {
            self.scroll_offset -= 1;
        }
    }
};
