# Integration Guide: Using Enhanced Message System

This guide shows how to use the new message type system in existing mlx-coder code.

## Quick Start

### 1. Import the new modules in your main loop

```zig
const messages = @import("messages.zig");
const message_renderer = @import("message_renderer.zig");
```

These are already imported in `tui.zig`.

### 2. Add Messages During Agent Loop

When the Swift agent loop streams thinking blocks:
```zig
try tui.addThinkingMessage("Planning architecture changes...");
```

When a tool is about to be called:
```zig
try tui.addToolCallMessage("write_file", "{\"path\": \"/src/app.zig\", ...}");
```

When a tool result comes back:
```zig
try tui.addToolResultMessage("write_file", true, "File written successfully");
```

### 3. Status Updates

For connection/loading events:
```zig
try tui.addStatusMessage("Model loaded successfully", false);
try tui.addStatusMessage("Failed to connect to MLX runtime", true);
```

## Message History Navigation

Users can scroll through the message history:

```zig
// In keyboard handler
if (key == up_arrow) {
    tui.scrollUp();
    try tui.repaint(session);
}
if (key == down_arrow) {
    tui.scrollDown();
    try tui.repaint(session);
}
```

## Integration with Swift Bridge

The message system works alongside existing Swift callbacks:

1. **Token streaming** - Continues to work via `drainQueue()`
2. **Tool approval** - Existing approval modal still displays
3. **Stats updates** - Model name, tokens/sec display continues

Example integration point in main loop:
```zig
// Existing code continues...
while (running) {
    // Update stats
    bridge.mlxclib_get_stats(session, &tui.last_stats);
    
    // NEW: Add thinking block if we have cognitive status
    if (agent_is_thinking) {
        try tui.addThinkingMessage("Analyzing your request...");
    }
    
    // Drain token stream
    _ = try tui.drainQueue();
    
    // Repaint screen with both old and new content
    try tui.repaint(session);
}
```

## Customizing Rendering

To customize how messages render, edit `message_renderer.zig`:

### Change Colors
```zig
pub const COLORS = struct {
    const RESET = "\x1b[0m";
    const BOLD = "\x1b[1m";
    // ... add custom colors
    const MY_CUSTOM = "\x1b[38;5;123m";  // 256-color
};
```

### Modify Tool Call Box
```zig
fn renderToolCall(msg: *const messages.Message, width: u16) []const u8 {
    // Customize box drawing, add icons, change format
    // ...
}
```

## Testing

Build and test:
```bash
cd zig
zig build

# The enhanced TUI is ready to use!
./zig-out/bin/mlx-coder-tui
```

## Performance Considerations

- **Message History**: Max 1024 messages (circular buffer)
- **Message Size**: Each message copies content during append
- **Render Performance**: Message rendering is O(N) where N = visible messages
- **Memory**: ~16KB response buffer + message history allocations

For large conversations, consider:
1. Limiting history depth
2. Lazy rendering (only visible messages)
3. Compressing old message content

## Debugging

To see message history status:
```zig
// In your debug output
std.debug.print("Message count: {d}\n", .{tui.message_history.getCount()});
std.debug.print("Response buffer: {d} bytes\n", .{tui.response_len});
```

## Migration from Old Code

The enhanced system is **backward compatible**. Existing code continues to work:

✅ `tui.drainQueue()` - Still works
✅ `tui.drawApprovalModal()` - Still works  
✅ `tui.appendOutput()` - Still works
✅ `tui.appendInputByte()` - Still works

New capabilities are **additive** - use them when ready:

✅ `tui.addThinkingMessage()` - New
✅ `tui.addToolCallMessage()` - New
✅ `tui.addToolResultMessage()` - New
✅ `tui.scrollUp()` / `scrollDown()` - New

## Next Steps

1. **Connect Swift callbacks**: Map thinking/tool events to new message types
2. **Test rendering**: Run and verify message display looks good
3. **Add keyboard shortcuts**: Scroll through history (Page Up/Down)
4. **Iterate on formatting**: Adjust colors and box styles to taste
