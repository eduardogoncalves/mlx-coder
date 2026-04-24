// zig/build.zig
// Zig build script for the mlx-coder OpenTUI host binary.
//
// Prerequisites
//   • Swift Package Manager must have already built libMLXCLib.dylib:
//       cd <repo-root> && swift build -c release --product MLXCLib
//   • Pass the path to the directory containing libMLXCLib.dylib via -Dlib-dir=<path>.
//     Default: <repo-root>/.build/release  (works for standard SwiftPM layout).
//
// Usage
//   zig build                           # debug build, default lib-dir
//   zig build -Dlib-dir=/path/to/libs  # custom library search path
//   zig build -Doptimize=ReleaseFast   # optimised build
//
// Output
//   zig-out/bin/mlx-coder-tui

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -Dlib-dir option: directory containing libMLXCLib.dylib.
    const lib_dir = b.option(
        []const u8,
        "lib-dir",
        "Directory containing libMLXCLib.dylib (default: ../.build/release)",
    ) orelse "../.build/release";

    // ---------------------------------------------------------------------------
    // Main executable
    // ---------------------------------------------------------------------------

    const exe = b.addExecutable(.{
        .name   = "mlx-coder-tui",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link the Swift-built MLXCLib dynamic library.
    exe.addLibraryPath(.{ .cwd_relative = lib_dir });
    exe.linkSystemLibrary("MLXCLib");

    // Set rpath so the binary can find libMLXCLib.dylib at runtime.
    // We embed the absolute path used at build time AND the @executable_path
    // convention so the binary is portable if the dylib is co-located.
    exe.addRPath(.{ .cwd_relative = lib_dir });
    exe.addRPath(.{ .special = "@executable_path" });
    exe.addRPath(.{ .special = "@executable_path/../lib" });

    // System frameworks required by Swift/MLX on macOS.
    exe.linkFramework("Foundation");
    exe.linkFramework("Metal");
    exe.linkFramework("Accelerate");

    b.installArtifact(exe);

    // ---------------------------------------------------------------------------
    // Run step: `zig build run -- [model-path]`
    // ---------------------------------------------------------------------------

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |run_args| {
        run_cmd.addArgs(run_args);
    }

    const run_step = b.step("run", "Build and run mlx-coder-tui");
    run_step.dependOn(&run_cmd.step);

    // ---------------------------------------------------------------------------
    // Test step: `zig build test`
    // ---------------------------------------------------------------------------

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/queue.zig"),
        .target   = target,
        .optimize = optimize,
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests (queue, bridge)");
    test_step.dependOn(&run_tests.step);
}
