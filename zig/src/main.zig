const std = @import("std");
const hid = @import("hid.zig");
const deck = @import("deck.zig");
const image = @import("image.zig");
const daemon = @import("daemon.zig");
const config = @import("config.zig");
const mqtt = @import("mqtt.zig");

fn usage() noreturn {
    std.debug.print(
        \\deckd — Stream Deck Plus daemon (dev CLI)
        \\
        \\usage:
        \\  deckd info                  firmware + serial
        \\  deckd dump [--device PATH]  hex-dump input reports (press keys, turn dials)
        \\  deckd brightness <0-100>    set panel brightness
        \\  deckd reset                 reset the device
        \\  deckd test-image            orientation test pattern on all keys + strip
        \\  deckd pub <topic> <payload> publish one MQTT message (broker from config; no deck needed)
        \\  deckd run [matrix-url]      daemon: keys/knobs drive the matrix (default http://localhost:8787)
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
    } else if (std.mem.eql(u8, cmd, "test-image")) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var dev = try openDeck(device_arg);
        defer dev.close();
        try deck.setBrightness(&dev, 70);

        // Orientation pattern: corner colors TL=red TR=green BL=yellow
        // BR=blue, white bar along the top edge, key-index stripes bottom.
        var key: u8 = 0;
        while (key < deck.key_count) : (key += 1) {
            var img = try image.Image.init(alloc, deck.key_px, deck.key_px);
            img.fill(24, 24, 24);
            const cs = 30; // corner size
            img.fillRect(0, 0, cs, cs, 255, 0, 0); // TL red
            img.fillRect(deck.key_px - cs, 0, cs, cs, 0, 255, 0); // TR green
            img.fillRect(0, deck.key_px - cs, cs, cs, 255, 255, 0); // BL yellow
            img.fillRect(deck.key_px - cs, deck.key_px - cs, cs, cs, 0, 0, 255); // BR blue
            img.fillRect(0, 0, deck.key_px, 6, 255, 255, 255); // top white bar
            var s: usize = 0;
            while (s <= key) : (s += 1) img.fillRect(30 + s * 12, 100, 8, 16, 255, 255, 255);
            var jpeg: std.ArrayList(u8) = .empty;
            try image.encodeJpeg(&img, 90, &jpeg, alloc);
            try deck.setKeyImage(&dev, key, jpeg.items);
            std.debug.print("key {d}: {d} bytes jpeg\n", .{ key, jpeg.items.len });
        }

        // Strip: left white bar, red→blue horizontal gradient.
        var strip = try image.Image.init(alloc, deck.strip_w, deck.strip_h);
        var x: usize = 0;
        while (x < deck.strip_w) : (x += 1) {
            const r: u8 = @intCast(255 * (deck.strip_w - x) / deck.strip_w);
            const b: u8 = @intCast(255 * x / deck.strip_w);
            strip.fillRect(x, 0, 1, deck.strip_h, r, 0, b);
        }
        strip.fillRect(0, 0, 16, deck.strip_h, 255, 255, 255);
        var jpeg: std.ArrayList(u8) = .empty;
        try image.encodeJpeg(&strip, 90, &jpeg, alloc);
        try deck.setStripImage(&dev, 0, 0, deck.strip_w, deck.strip_h, jpeg.items);
        std.debug.print("strip: {d} bytes jpeg\n", .{jpeg.items.len});
    } else if (std.mem.eql(u8, cmd, "pub")) {
        const topic = positional orelse usage();
        const payload = positional2 orelse usage();
        var cfg_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const cfg = config.load(cfg_arena.allocator());
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
        var dev = try openDeck(device_arg);
        defer dev.close();
        // Config lives for the whole process (parsed strings point into it).
        var cfg_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const cfg = try cfg_arena.allocator().create(config.Config);
        cfg.* = config.load(cfg_arena.allocator());
        if (positional) |url| cfg.matrix_url = url; // CLI beats config file
        // Single-threaded Io like soma-zig: all I/O blocks the caller.
        var io_threaded: std.Io.Threaded = .init_single_threaded;
        try daemon.run(io_threaded.io(), &dev, cfg);
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
