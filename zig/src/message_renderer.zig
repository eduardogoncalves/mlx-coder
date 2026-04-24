// zig/src/message_renderer.zig
// Renders messages similar to OpenCode UI patterns with thinking blocks,
// tool calls with collapsible sections, and tool results with status icons

const std = @import("std");
const messages = @import("messages.zig");

pub const MessageRenderer = struct {
    pub const COLORS = struct {
        const RESET = "\x1b[0m";
        const BOLD = "\x1b[1m";
        const DIM = "\x1b[2m";
        const GREEN = "\x1b[32m";
        const RED = "\x1b[31m";
        const CYAN = "\x1b[36m";
        const YELLOW = "\x1b[33m";
        const MAGENTA = "\x1b[35m";
        const WHITE = "\x1b[37m";
        const GRAY = "\x1b[38;5;60m";  // Dimmer gray for line decoration
    };
    
    const ESC = "\x1b[";
    
    /// Render a single message based on its type
    pub fn renderMessage(msg: *const messages.Message, width: u16) []const u8 {
        return switch (msg.msg_type) {
            .thinking => renderThinking(msg, width),
            .tool_call => renderToolCall(msg, width),
            .tool_result => renderToolResult(msg, width),
            .status => renderStatus(msg, width),
            .err => renderError(msg, width),
            .assistant => renderAssistant(msg, width),
            .user_input => renderUserInput(msg, width),
        };
    }
    
    /// Render a thinking block like OpenCode's animated thinking display
    fn renderThinking(msg: *const messages.Message, _: u16) []const u8 {
        _ = msg;
        // Simplified inline rendering
        const output = COLORS.DIM ++ COLORS.CYAN ++ "+ Thinking" ++ COLORS.RESET ++ "\n";
        return output;
    }
    
    /// Render a tool call with fancy borders matching OpenCode's BasicTool
    fn renderToolCall(msg: *const messages.Message, _: u16) []const u8 {
        const tool_name = msg.tool_name orelse "unknown";
        _ = tool_name;
        // Simplified inline rendering
        const output = "\n" ++ COLORS.GRAY ++ COLORS.BOLD ++ "╭" ++ COLORS.RESET ++ "\n" ++
                       COLORS.GRAY ++ "│" ++ COLORS.RESET ++ " " ++ COLORS.BOLD ++ COLORS.YELLOW ++ "🔧" ++ COLORS.RESET ++ "\n" ++
                       COLORS.GRAY ++ "╰" ++ COLORS.RESET ++ "\n";
        return output;
    }
    
    /// Render a tool result with status icon
    fn renderToolResult(msg: *const messages.Message, _: u16) []const u8 {
        const icon = if (msg.result_success) "✅" else "❌";
        _ = icon;
        const output = COLORS.GRAY ++ "│" ++ COLORS.RESET ++ " Result\n";
        return output;
    }
    
    /// Render a status message
    fn renderStatus(msg: *const messages.Message, _: u16) []const u8 {
        _ = msg;
        const output = COLORS.DIM ++ COLORS.MAGENTA ++ "▸ Status" ++ COLORS.RESET ++ "\n";
        return output;
    }
    
    /// Render an error message
    fn renderError(msg: *const messages.Message, _: u16) []const u8 {
        _ = msg;
        const output = COLORS.BOLD ++ COLORS.RED ++ "Error" ++ COLORS.RESET ++ "\n";
        return output;
    }
    
    /// Render assistant output
    fn renderAssistant(msg: *const messages.Message, _: u16) []const u8 {
        _ = msg;
        const output = COLORS.CYAN ++ "Assistant" ++ COLORS.RESET ++ "\n";
        return output;
    }
    
    /// Render user input
    fn renderUserInput(msg: *const messages.Message, _: u16) []const u8 {
        _ = msg;
        const output = COLORS.GREEN ++ COLORS.BOLD ++ ">" ++ COLORS.RESET ++ " Input\n";
        return output;
    }
};