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
    mod.addCSourceFile(.{
        .file = b.path("vendor/stb_image_impl.c"),
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

    // deckd-config: a separate GTK4 GUI for editing config.json, entirely
    // decoupled from the daemon (no shared module — they agree only on the
    // on-disk JSON schema). Optional: deckd itself is meant to run headless
    // on servers with no GTK installed (see the udev rules' own comment on
    // that), so a missing gtk4 pkg-config file just skips this — it must
    // never break `zig build` for the daemon.
    //
    // Opt-in (-Dconfig-gui) for now: it still edits the pre-MQTT schema
    // (matrix_keys/soma_keys/mqtt_keys), which the daemon no longer reads.
    const want_gui = b.option(bool, "config-gui", "Build deckd-config (GTK4; still on the old config schema)") orelse false;
    if (want_gui) {
        if (builtin.os.tag == .linux and pkgConfigHas(b, "gtk4")) {
            buildConfigGui(b, target, optimize);
        } else if (builtin.os.tag == .linux) {
            std.debug.print("note: gtk4 not found (pkg-config) — skipping deckd-config GUI\n", .{});
        }
    }
}

/// b.run() itself aborts the whole build on a nonzero exit, which is no
/// good for a check that's allowed to fail — so the failure is folded into
/// a shell one-liner that always exits 0, and the answer read back out of
/// its stdout instead.
fn pkgConfigHas(b: *std.Build, name: []const u8) bool {
    const argv = &.{ "sh", "-c", b.fmt("pkg-config --exists '{s}' && echo yes || echo no", .{name}) };
    const out = b.run(argv);
    return std.mem.startsWith(u8, out, "yes");
}

fn buildConfigGui(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    // zig's translate-c can't parse a plain `#include <gtk/gtk.h>` as
    // shipped by a real desktop GTK4 install — see tools/gen_gtk_header.sh
    // for exactly why and what this works around. Flattened fresh on every
    // build (not vendored) so it always matches whatever GTK is installed.
    const gtk_header = b.pathJoin(&.{ b.cache_root.path orelse ".zig-cache", "gtk_flat.h" });
    _ = b.run(&.{ "sh", b.pathFromRoot("tools/gen_gtk_header.sh"), gtk_header });

    const gui_mod = b.createModule(.{
        .root_source_file = b.path("src/config_gui.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    gui_mod.addIncludePath(.{ .cwd_relative = std.fs.path.dirname(gtk_header).? });
    // Same glibc workaround as above means the target's default library
    // search path doesn't include the system's — pkg-config's own -l list
    // (via linkSystemLibrary below) assumes it does.
    gui_mod.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    gui_mod.linkSystemLibrary("gtk4", .{});

    const gui_exe = b.addExecutable(.{
        .name = "deckd-config",
        .root_module = gui_mod,
    });
    b.installArtifact(gui_exe);

    const gui_run_cmd = b.addRunArtifact(gui_exe);
    gui_run_cmd.step.dependOn(b.getInstallStep());
    const gui_run_step = b.step("run-config", "Run deckd-config (GUI config editor)");
    gui_run_step.dependOn(&gui_run_cmd.step);
}
