const std = @import("std");
const hid = @import("hid.zig");
const deck = @import("deck.zig");

fn usage() noreturn {
    std.debug.print(
        \\deckd — Stream Deck Plus daemon (dev CLI)
        \\
        \\usage:
        \\  deckd info                  firmware + serial
        \\  deckd dump [--device PATH]  hex-dump input reports (press keys, turn dials)
        \\  deckd brightness <0-100>    set panel brightness
        \\  deckd reset                 reset the device
        \\
    , .{});
    std.process.exit(2);
}

fn openDeck(device_arg: ?[]const u8) !hid.Device {
    var path_buf: [64]u8 = undefined;
    const path = device_arg orelse blk: {
        const found = try hid.findDevicePath(&path_buf);
        break :blk found orelse {
            std.debug.print("no Stream Deck Plus found (vid 0fd9 pid 0084)\n", .{});
            std.process.exit(1);
        };
    };
    std.debug.print("device: {s}\n", .{path});
    return hid.Device.open(path);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next(); // argv0
    const cmd = args.next() orelse usage();

    var device_arg: ?[]const u8 = null;
    var positional: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--device")) {
            device_arg = args.next() orelse usage();
        } else {
            positional = positional orelse arg;
        }
    }

    if (std.mem.eql(u8, cmd, "info")) {
        var dev = try openDeck(device_arg);
        defer dev.close();
        var buf: [deck.feature_len]u8 = undefined;
        const fw = try deck.firmwareVersion(&dev, &buf);
        std.debug.print("firmware: {s}\n", .{fw});
        const serial = try deck.serialNumber(&dev, &buf);
        std.debug.print("serial:   {s}\n", .{serial});
    } else if (std.mem.eql(u8, cmd, "brightness")) {
        const pct_str = positional orelse usage();
        const pct = try std.fmt.parseInt(u8, pct_str, 10);
        var dev = try openDeck(device_arg);
        defer dev.close();
        try deck.setBrightness(&dev, pct);
    } else if (std.mem.eql(u8, cmd, "reset")) {
        var dev = try openDeck(device_arg);
        defer dev.close();
        try deck.reset(&dev);
    } else if (std.mem.eql(u8, cmd, "dump")) {
        var dev = try openDeck(device_arg);
        defer dev.close();
        std.debug.print("dumping input reports — press keys, turn/press dials, tap the strip. ctrl-c to stop.\n", .{});
        var buf: [256]u8 = undefined;
        while (true) {
            const n = (try dev.pollReport(&buf, 10000)) orelse continue;
            const report = buf[0..n];
            std.debug.print("[{d:>3}] ", .{n});
            for (report[0..@min(n, 16)]) |b| std.debug.print("{x:0>2} ", .{b});
            if (deck.parseReport(report)) |parsed|
                std.debug.print(" → {any}", .{parsed});
            std.debug.print("\n", .{});
        }
    } else {
        usage();
    }
}
