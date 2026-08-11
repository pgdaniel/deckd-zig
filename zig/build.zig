const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    // Same workaround as soma-zig: on Linux, default to zig's bundled glibc
    // because the self-hosted linker can't handle newer system glibc crt1.o.
    const default_target: std.Target.Query = if (builtin.os.tag == .linux)
        .{ .abi = .gnu, .cpu_model = .native }
    else
        .{};
    const target = b.standardTargetOptions(.{ .default_target = default_target });
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    mod.addIncludePath(b.path("vendor"));
    // -fno-sanitize: stb's JPEG bit writer has known-benign shift UB that
    // zig's Debug-mode UBSan otherwise traps on.
    mod.addCSourceFile(.{
        .file = b.path("vendor/stb_image_write_impl.c"),
        .flags = &.{ "-O2", "-w", "-fno-sanitize=all" },
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/stb_truetype_impl.c"),
        .flags = &.{ "-O2", "-w", "-fno-sanitize=all" },
    });

    const exe = b.addExecutable(.{
        .name = "deckd",
        .root_module = mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run deckd");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
