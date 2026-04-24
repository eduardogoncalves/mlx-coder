# Enhanced mlx-coder-tui (OpenCode-style)

This is an enhanced version of the mlx-coder TUI that incorporates design patterns and features from [OpenCode](https://github.com/anomalyco/opencode), the open-source AI coding agent.

## What's New

### 1. **Message Type System** (`zig/src/messages.zig`)
- Structured message types for different content: thinking blocks, tool calls, tool results, and status messages
- Message history management with bounded circular buffer (1024 messages max)
- Proper message lifecycle with allocator-aware cleanup

### 2. **Enhanced Message Rendering** (`zig/src/message_renderer.zig`)
Renders messages similar to OpenCode's UI with:
- **Thinking blocks**: Dim cyan text with `+ ` prefix for iterative thinking display
- **Tool calls**: Fancy bordered boxes with tool name, arguments, and icon (🔧)
- **Tool results**: Status indicators (✅/❌) with success/error colors
- **Status messages**: Color-coded with ▸ prefix and appropriate context
- **Error messages**: Bold red text for visibility

### 3. **Enhanced TUI State** (`zig/src/tui.zig`)
Extended the main TUI struct with:
- Message history tracking for conversation context
- Scroll offset for viewing message history
- Methods for adding different message types
- Scroll up/down capabilities for navigating history

## Architecture

```
┌─────────────────────────────────────────┐
│ Status Bar (model, tokens/s, mode)      │ ← drawStatusBar()
├─────────────────────────────────────────┤
│                                         │
│  Message History:                       │ ← renderMessageHistory()
│  • Thinking blocks with formatting      │
│  • Tool calls with boxes                │
│  • Tool results with status icons       │
│  • Status/error messages                │
│                                         │
├─────────────────────────────────────────┤
│ > User input (with spinner if gen)      │ ← drawInputLine()
└─────────────────────────────────────────┘
```

## Key Components

### Message Types
```zig
pub const MessageType = enum {
    user_input,      // User's chat input
    assistant,       // Assistant's response
    thinking,        // Thinking/reasoning block
    tool_call,       // Tool execution request
    tool_result,     // Tool result output
    status,          // Status updates
    err,             // Error messages
};
```

### Message Structures
- `ThinkingMessage`: Thinking blocks with optional dynamic status
- `ToolCallMessage`: Tool invocation with name and JSON arguments
- `ToolResultMessage`: Tool output with success/error status
- `StatusMessage`: Status updates and error notifications

### Color Scheme
Matches Swift UI StreamRenderer:
- **CYAN**: Assistant output, thinking blocks
- **GREEN**: User input, success indicators  
- **RED**: Errors, failed operations
- **YELLOW**: Tool names, attention-grabbing
- **MAGENTA**: Status messages
- **DIM**: Secondary info, line decorations

## Usage Examples

### Adding Messages to History
```zig
// Add a thinking block
try tui.addThinkingMessage("Analyzing the codebase structure...");

// Add a tool call
try tui.addToolCallMessage("file_read", "{\"path\": \"/src/main.zig\"}");

// Add a tool result
try tui.addToolResultMessage("file_read", true, "File contents here...");

// Add a status message
try tui.addStatusMessage("Model loaded successfully", false);
try tui.addStatusMessage("Permission denied", true);  // error
```

### Scrolling Through History
```zig
tui.scrollUp();    // Show older messages
tui.scrollDown();  // Show newer messages
```

## Rendering Pipeline

1. **Status Bar** - Shows model, tokens/sec, current mode
2. **Message History** - Renders all messages with appropriate formatting
3. **Input Line** - Shows user input or spinner (if generating)
4. **Approval Modal** - Tool approval request (if pending)

## Future Enhancements

- [ ] Animated transitions for thinking block status updates
- [ ] Collapsible tool result sections (like OpenCode's BasicTool)
- [ ] Better text wrapping for long messages
- [ ] Context usage display in footer
- [ ] Git branch and commit info display
- [ ] Tree-sitter syntax highlighting
- [ ] Message search/filtering
- [ ] Performance optimizations for large histories

## Thread Safety

- All rendering occurs on the main Zig thread
- Token streaming via TokenQueue remains thread-safe
- Message history is protected by allocator semantics

## Compatibility

- **Zig Version**: 0.16.0+
- **Platform**: macOS (using system frameworks)
- **Terminal**: 80+ column width recommended

## Integration Points

The enhanced TUI integrates with:
- `queue.zig`: Token streaming from Swift bridge
- `bridge.zig`: MLX statistics and callbacks
- `main.zig`: Entry point and initialization
- `spinner.zig`: Animation frames for generation state

This maintains backward compatibility with existing code while adding powerful new rendering capabilities inspired by OpenCode's modern TUI design.
