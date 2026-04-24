// zig/src/spinner.zig
// Animated spinner frames for TUI "generating..." indicator
// Inspired by Knight Rider LED scanner effect

const std = @import("std");

/// Animation frames for generating indicator
/// Uses block characters for a smooth scanning effect
pub const spinner_frames = [_][]const u8{
    "⬛·····",
    "·⬛····",
    "··⬛···",
    "···⬛··",
    "····⬛·",
    "·····⬛",
    "····⬛·",
    "···⬛··",
    "··⬛···",
    "·⬛····",
};

pub const num_frames = spinner_frames.len;

/// Get spinner frame for a given frame index
pub fn getFrame(frame_index: usize) []const u8 {
    return spinner_frames[frame_index % num_frames];
}

/// Smooth gradient frames (alternative style)
pub const gradient_frames = [_][]const u8{
    "◐······",
    "·◓·····",
    "··◑····",
    "···◒···",
    "····◐··",
    "·····◓·",
    "······◑",
    "·····◒·",
    "····◐··",
    "···◒···",
    "··◑····",
    "·◓·····",
};

pub const gradient_num_frames = gradient_frames.len;

pub fn getGradientFrame(frame_index: usize) []const u8 {
    return gradient_frames[frame_index % gradient_num_frames];
}

/// Pulsing indicator frames
pub const pulse_frames = [_][]const u8{
    "●",
    "◐",
    "◑",
    "◒",
    "○",
    "◐",
    "◑",
    "◒",
};

pub const pulse_num_frames = pulse_frames.len;

pub fn getPulseFrame(frame_index: usize) []const u8 {
    return pulse_frames[frame_index % pulse_num_frames];
}
