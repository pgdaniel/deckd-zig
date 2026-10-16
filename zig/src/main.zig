const std = @import("std");
const hid = @import("hid.zig");
const deck = @import("deck.zig");
const image = @import("image.zig");
const daemon = @import("daemon.zig");
const config = @import("config.zig");
const mqtt = @import("mqtt.zig");

fn usage() noreturn {
    std.debug.print(
        \\deckd — Stream Deck daemon (dev CLI)
        \\
        \\usage:
        \\  deckd info                  firmware + serial
        \\  deckd dump [--device PATH]  hex-dump input reports (press keys, turn dials)
        \\  deckd brightness <0-100>    set panel brightness
        \\  deckd reset                 reset the device
        \\  deckd test-image            orientation test pattern on all keys (+ strip if present)
        \\  deckd pub <topic> <payload> publish one MQTT message (broker from config; no deck needed)
        \\  deckd run                   daemon: config-driven pages, everything over MQTT
        \\
    , .{});
    std.process.exit(2);
}

fn openDeck(device_arg: ?[]const u8) !struct { dev: hid.Device, model: deck.Model } {
    var path_buf: [64]u8 = undefined;
    const path, const model = if (device_arg) |p|
        .{ p, deck.Model.plus }
    else blk: {
        const found = try hid.findDevice(&path_buf);
        if (found) |info| {
            break :blk .{ info.path[0..info.path_len], info.model };
        }
        std.debug.print("no Stream Deck found (vid 0fd9, pid 0084 or 00b8)\n", .{});
        std.process.exit(1);
    };
    std.debug.print("device: {s} ({s})\n", .{ path, @tagName(model) });
    const dev = try hid.Device.open(path);
    return .{ .dev = dev, .model = model };
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next(); // argv0
    const cmd = args.next() orelse usage();

    var device_arg: ?[]const u8 = null;
    var positional: ?[]const u8 = null;
    var positional2: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--device")) {
            device_arg = args.next() orelse usage();
        } else if (positional == null) {
            positional = arg;
        } else {
            positional2 = positional2 orelse arg;
        }
    }

    if (std.mem.eql(u8, cmd, "info")) {
        var d = try openDeck(device_arg);
        defer d.dev.close();
        var buf: [32]u8 = undefined;
        const fw = try deck.firmwareVersion(d.model, &d.dev, &buf);
        std.debug.print("firmware: {s}\n", .{fw});
        const serial = try deck.serialNumber(d.model, &d.dev, &buf);
        std.debug.print("serial:   {s}\n", .{serial});
    } else if (std.mem.eql(u8, cmd, "brightness")) {
        const pct_str = positional orelse usage();
        const pct = try std.fmt.parseInt(u8, pct_str, 10);
        var d = try openDeck(device_arg);
        defer d.dev.close();
        try deck.setBrightness(d.model, &d.dev, pct);
    } else if (std.mem.eql(u8, cmd, "reset")) {
        var d = try openDeck(device_arg);
        defer d.dev.close();
        try deck.reset(d.model, &d.dev);
    } else if (std.mem.eql(u8, cmd, "test-image")) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var d = try openDeck(device_arg);
        defer d.dev.close();
        try deck.setBrightness(d.model, &d.dev, 70);

        const kpx = deck.keyPx(d.model);
        const kc = deck.keyCount(d.model);

        var key: u8 = 0;
        while (key < kc) : (key += 1) {
            var img = try image.Image.init(alloc, kpx, kpx);
            img.fill(24, 24, 24);
            const cs: usize = if (kpx >= 120) 30 else 20;
            img.fillRect(0, 0, cs, cs, 255, 0, 0); // TL red
            img.fillRect(kpx - cs, 0, cs, cs, 0, 255, 0); // TR green
            img.fillRect(0, kpx - cs, cs, cs, 255, 255, 0); // BL yellow
            img.fillRect(kpx - cs, kpx - cs, cs, cs, 0, 0, 255); // BR blue
            img.fillRect(0, 0, kpx, 6, 255, 255, 255); // top white bar
            var s: usize = 0;
            const bar_y: usize = if (kpx >= 120) 100 else 60;
            const bar_x0: usize = if (kpx >= 120) 30 else 20;
            const bar_step: usize = if (kpx >= 120) 12 else 8;
            while (s <= key) : (s += 1) img.fillRect(bar_x0 + s * bar_step, bar_y, 8, 16, 255, 255, 255);
            try deck.setKeyImage(d.model, &d.dev, key, &img);
            std.debug.print("key {d}: {d}x{d}\n", .{ key, kpx, kpx });
        }

        if (deck.hasStrip(d.model)) {
            const sw = deck.stripW(d.model);
            const sh = deck.stripH(d.model);
            var strip = try image.Image.init(alloc, sw, sh);
            var x: usize = 0;
            while (x < sw) : (x += 1) {
                const r: u8 = @intCast(255 * (sw - x) / sw);
                const b: u8 = @intCast(255 * x / sw);
                strip.fillRect(x, 0, 1, sh, r, 0, b);
            }
            strip.fillRect(0, 0, 16, sh, 255, 255, 255);
            var jpeg: std.ArrayList(u8) = .empty;
            try image.encodeJpeg(&strip, 90, &jpeg, alloc);
            try deck.setStripImage(&d.dev, 0, 0, sw, sh, jpeg.items);
            std.debug.print("strip: {d} bytes jpeg\n", .{jpeg.items.len});
        }
    } else if (std.mem.eql(u8, cmd, "pub")) {
        const topic = positional orelse usage();
        const payload = positional2 orelse usage();
        var cfg_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const cfg = config.load(cfg_arena.allocator(), .plus);
        if (cfg.mqtt_host.len == 0) {
            std.debug.print("mqtt_host not set in ~/.config/deckd/config.json\n", .{});
            std.process.exit(1);
        }
        var io_threaded: std.Io.Threaded = .init_single_threaded;
        const mq: mqtt.Client = .{ .io = io_threaded.io(), .host = cfg.mqtt_host, .port = cfg.mqtt_port, .username = cfg.mqtt_user, .password = cfg.mqtt_pass };
        mq.publish(topic, payload) catch |err| {
            std.debug.print("publish failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        std.debug.print("published {s} → {s}\n", .{ topic, payload });
    } else if (std.mem.eql(u8, cmd, "run")) {
        var d = try openDeck(device_arg);
        defer d.dev.close();
        var cfg_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const cfg = try cfg_arena.allocator().create(config.Config);
        cfg.* = config.load(cfg_arena.allocator(), d.model);
        var io_threaded: std.Io.Threaded = .init_single_threaded;
        try daemon.run(io_threaded.io(), &d.dev, d.model, cfg);
    } else if (std.mem.eql(u8, cmd, "dump")) {
        var d = try openDeck(device_arg);
        defer d.dev.close();
        std.debug.print("dumping input reports — press keys, turn/press dials, tap the strip. ctrl-c to stop.\n", .{});
        var buf: [256]u8 = undefined;
        while (true) {
            const n = (try d.dev.pollReport(&buf, 10000)) orelse continue;
            const report = buf[0..n];
            std.debug.print("[{d:>3}] ", .{n});
            for (report[0..@min(n, 16)]) |b| std.debug.print("{x:0>2} ", .{b});
            if (deck.parseReport(d.model, report)) |parsed|
                std.debug.print(" → {any}", .{parsed});
            std.debug.print("\n", .{});
        }
    } else {
        usage();
    }
}
