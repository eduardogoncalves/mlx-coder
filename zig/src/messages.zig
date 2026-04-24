// zig/src/messages.zig
// Enhanced message types for improved TUI rendering similar to OpenCode
// Supports thinking blocks, tool calls, tool results, and status messages

const std = @import("std");
const ArrayList = std.ArrayList;

pub const MessageType = enum {
    user_input,
    assistant,
    thinking,
    tool_call,
    tool_result,
    status,
    err,
};

pub const ToolStatus = enum {
    pending,
    running,
    success,
    failed,
};

pub const Message = struct {
    msg_type: MessageType,
    content: []const u8,
    timestamp: i64,  // Unix timestamp in ms
    
    // For thinking messages
    thinking_status: ?[]const u8 = null,  // e.g., "Planning key generation..."
    
    // For tool call messages
    tool_name: ?[]const u8 = null,
    tool_args: ?[]const u8 = null,
    tool_status: ToolStatus = .pending,
    
    // For tool result messages
    result_success: bool = false,
    result_icon: ?u8 = null,  // ✅ or ❌
    truncation_marker: ?[]const u8 = null,
    
    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        if (self.thinking_status) |s| allocator.free(s);
        if (self.tool_name) |s| allocator.free(s);
        if (self.tool_args) |s| allocator.free(s);
        if (self.truncation_marker) |s| allocator.free(s);
    }
};

pub const MessageHistory = struct {
    allocator: std.mem.Allocator,
    messages: [1024]?Message = std.mem.zeroes([1024]?Message),
    count: usize = 0,
    
    pub fn init(allocator: std.mem.Allocator) MessageHistory {
        return .{
            .allocator = allocator,
            .count = 0,
        };
    }
    
    pub fn deinit(self: *MessageHistory) void {
        for (0..self.count) |i| {
            if (self.messages[i]) |*msg| {
                msg.deinit(self.allocator);
            }
        }
    }
    
    pub fn append(self: *MessageHistory, msg: Message) !void {
        // Keep history bounded
        if (self.count >= self.messages.len) {
            // Shift messages and discard oldest
            for (0..self.messages.len - 1) |i| {
                if (self.messages[i]) |*old_msg| {
                    old_msg.deinit(self.allocator);
                }
                self.messages[i] = self.messages[i + 1];
            }
            self.count = self.messages.len - 1;
        }
        self.messages[self.count] = msg;
        self.count += 1;
    }
    
    pub fn getCount(self: *const MessageHistory) usize {
        return self.count;
    }
    
    pub fn getMessage(self: *const MessageHistory, index: usize) ?*const Message {
        if (index < self.count and self.messages[index] != null) {
            return &(self.messages[index].?);
        }
        return null;
    }
};

pub const ThinkingMessage = struct {
    content: []const u8,
    status: ?[]const u8 = null,  // Dynamic status like "Planning..."
    
    pub fn create(allocator: std.mem.Allocator, content: []const u8) !Message {
        return Message{
            .msg_type = .thinking,
            .content = try allocator.dupe(u8, content),
            .timestamp = std.time.milliTimestamp(),
            .thinking_status = null,
        };
    }
};

pub const ToolCallMessage = struct {
    tool_name: []const u8,
    args_json: []const u8,
    
    pub fn create(allocator: std.mem.Allocator, name: []const u8, args: []const u8) !Message {
        return Message{
            .msg_type = .tool_call,
            .content = "",  // Minimal content, args in tool_args
            .timestamp = std.time.milliTimestamp(),
            .tool_name = try allocator.dupe(u8, name),
            .tool_args = try allocator.dupe(u8, args),
            .tool_status = .pending,
        };
    }
};

pub const ToolResultMessage = struct {
    tool_name: []const u8,
    success: bool,
    content: []const u8,
    
    pub fn create(allocator: std.mem.Allocator, name: []const u8, ok: bool, result: []const u8) !Message {
        return Message{
            .msg_type = .tool_result,
            .content = try allocator.dupe(u8, result),
            .timestamp = std.time.milliTimestamp(),
            .tool_name = try allocator.dupe(u8, name),
            .result_success = ok,
            .result_icon = if (ok) '✅' else '❌',
        };
    }
};

pub const StatusMessage = struct {
    content: []const u8,
    is_error: bool = false,
    
    pub fn create(allocator: std.mem.Allocator, text: []const u8, is_error: bool) !Message {
        return Message{
            .msg_type = if (is_error) .err else .status,
            .content = try allocator.dupe(u8, text),
            .timestamp = std.time.milliTimestamp(),
        };
    }
};
