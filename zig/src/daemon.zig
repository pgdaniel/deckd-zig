//! The deckd daemon: Stream Deck Plus → matrix control API + soma player IPC.
//!
//! Pages (knob 4 push cycles them) swap what the 8 keys and the strip show:
//!   MATRIX — keys direct-select matrix screens (white border = active),
//!            strip shows screen name / auto-advance / soma now-playing.
//!   SOMA   — keys are SomaFM channel presets + VIZ + STOP (border = playing),
//!            strip shows channel / track / volume.
//!
//! Knobs (fixed roles on all pages):
//!   knob 1 rotate: soma volume        push: mute toggle
//!   knob 2 rotate: soma channel surf  push: play/stop toggle
//!   knob 3 rotate: matrix screen jog  push: auto-advance toggle
//!   knob 4 rotate: deck LCD brightness  push: switch page
//! Strip left/right swipe jogs matrix screens too.
//!
//! Memory: transient work (images, JPEGs, HTTP bodies, JSON) uses a per-cycle
//! arena reset each loop iteration; state that survives an iteration lives in
//! the fixed buffers below.
const std = @import("std");
const hid = @import("hid.zig");
const deck = @import("deck.zig");
const image = @import("image.zig");
const render = @import("render.zig");
const matrix = @import("matrix.zig");
const soma = @import("soma.zig");
const ws = @import("ws.zig");
const config = @import("config.zig");
const ttf = @import("ttf.zig");

const Page = enum { matrix, soma, mirror };

const max_screens = 16;
const name_len = 64;
const track_len = 128;

const Daemon = struct {
    dev: *hid.Device,
    mx: matrix.Client,
    sm: soma.Client,
    feed: *ws.FrameFeed,
    cfg: *const config.Config,
    font: ?ttf.Font = null,

    page: Page = .matrix,
    mirror_drawn_counter: u64 = 0,
    last_mirror_ms: i64 = 0,

    // matrix state
    current_buf: [name_len]u8 = undefined,
    current_len: usize = 0,
    // Jog list: all screens in panel order (the deck can reach disabled
    // screens too — "enabled" only governs the auto-advance rotation).
    screen_buf: [max_screens][name_len]u8 = undefined,
    screen_lens: [max_screens]usize = .{0} ** max_screens,
    screen_count: usize = 0,
    auto_advance: bool = false,
    mx_online: bool = false,

    // soma state
    sm_online: bool = false,
    sm_playing: bool = false,
    sm_volume: u8 = 0,
    sm_channel_buf: [name_len]u8 = undefined,
    sm_channel_len: usize = 0,
    sm_id_buf: [name_len]u8 = undefined,
    sm_id_len: usize = 0,
    sm_track_buf: [track_len]u8 = undefined,
    sm_track_len: usize = 0,

    // what's currently on the deck (redraw when the signature changes)
    keys_sig: u64 = 0,
    strip_sig: u64 = 0,

    brightness: u8 = 80,
    prev_keys: [deck.key_count]bool = .{false} ** deck.key_count,
    prev_dials: [deck.dial_count]bool = .{false} ** deck.dial_count,

    fn currentScreen(self: *const Daemon) []const u8 {
        return self.current_buf[0..self.current_len];
    }

    fn somaChannel(self: *const Daemon) []const u8 {
        return self.sm_channel_buf[0..self.sm_channel_len];
    }

    fn somaId(self: *const Daemon) []const u8 {
        return self.sm_id_buf[0..self.sm_id_len];
    }

    fn somaTrack(self: *const Daemon) []const u8 {
        return self.sm_track_buf[0..self.sm_track_len];
    }

    fn copyInto(buf: []u8, len: *usize, s: []const u8) void {
        const n = @min(s.len, buf.len);
        @memcpy(buf[0..n], s[0..n]);
        len.* = n;
    }

    // ----------------------------------------------------------
    // State polling
    // ----------------------------------------------------------
    fn pollMatrix(self: *Daemon, arena: std.mem.Allocator) void {
        const cfg = self.mx.getConfig(arena) catch {
            self.mx_online = false;
            return;
        };
        self.mx_online = true;
        copyInto(&self.current_buf, &self.current_len, cfg.current);
        self.auto_advance = cfg.auto_advance;
        const names = cfg.allNames(arena) catch &.{};
        self.screen_count = @min(names.len, max_screens);
        for (names[0..self.screen_count], 0..) |name, i| {
            copyInto(&self.screen_buf[i], &self.screen_lens[i], name);
        }
    }

    fn pollSoma(self: *Daemon, arena: std.mem.Allocator) void {
        const st = self.sm.status(arena) catch {
            self.sm_online = false;
            self.sm_playing = false;
            return;
        };
        self.sm_online = true;
        self.sm_playing = st.playing or st.connecting;
        self.sm_volume = st.volume;
        copyInto(&self.sm_channel_buf, &self.sm_channel_len, st.channel);
        copyInto(&self.sm_id_buf, &self.sm_id_len, st.channel_id);
        copyInto(&self.sm_track_buf, &self.sm_track_len, st.track);
    }

    fn somaCmd(self: *Daemon, arena: std.mem.Allocator, cmd: []const u8) void {
        _ = self.sm.command(arena, cmd) catch {
            self.sm_online = false;
            self.sm_playing = false;
            return;
        };
        // The command is applied on soma's next frame (~40ms); give it a
        // moment, then refresh so the strip reflects the change at once.
        std.Io.sleep(self.sm.io, .fromMilliseconds(60), .awake) catch {};
        self.pollSoma(arena);
    }

    // ----------------------------------------------------------
    // Drawing
    // ----------------------------------------------------------
    fn activeKeyName(self: *const Daemon) []const u8 {
        return switch (self.page) {
            .matrix, .mirror => if (self.mx_online) self.currentScreen() else "",
            .soma => if (self.sm_online and self.sm_playing) self.somaId() else "",
        };
    }

    fn drawKeys(self: *Daemon, arena: std.mem.Allocator) !void {
        switch (self.page) {
            .matrix, .mirror => for (self.cfg.matrix_keys, 0..) |ka, i| {
                try self.drawKey(arena, @intCast(i), ka.label, ka.r, ka.g, ka.b, std.mem.eql(u8, ka.screen, self.activeKeyName()));
            },
            .soma => for (self.cfg.soma_keys, 0..) |ka, i| {
                try self.drawKey(arena, @intCast(i), ka.label, ka.r, ka.g, ka.b, std.mem.eql(u8, ka.id, self.activeKeyName()));
            },
        }
    }

    fn drawKey(self: *Daemon, arena: std.mem.Allocator, key: u8, label: []const u8, r: u8, g: u8, b: u8, active: bool) !void {
        var img = try image.Image.init(arena, deck.key_px, deck.key_px);
        img.fill(r / 6, g / 6, b / 6);
        self.drawCenteredText(&img, label, deck.key_px / 2, self.cfg.font_size_key, r, g, b);
        if (active) render.border(&img, 4, 255, 255, 255);
        var jpeg: std.ArrayList(u8) = .empty;
        try image.encodeJpeg(&img, 90, &jpeg, arena);
        try deck.setKeyImage(self.dev, key, jpeg.items);
    }

    /// Text centered at (img.w/2, cy): TTF when configured, else the 8x8
    /// bitmap font at a scale matched to the requested px size.
    fn drawCenteredText(self: *Daemon, img: *image.Image, text: []const u8, cy: usize, px: u16, r: u8, g: u8, b: u8) void {
        if (self.font) |*f| {
            f.drawCentered(img, text, img.w / 2, cy, px, r, g, b);
        } else {
            const scale: usize = if (px >= 28) 3 else if (px >= 12) 2 else 1;
            render.drawTextCentered(img, text, cy -| 4 * scale, scale, r, g, b);
        }
    }

    fn drawStrip(self: *Daemon, arena: std.mem.Allocator) !void {
        var img = try image.Image.init(arena, deck.strip_w, deck.strip_h);
        img.fill(8, 8, 12);
        switch (self.page) {
            .matrix => {
                if (!self.mx_online) {
                    self.drawCenteredText(&img, "MATRIX OFFLINE", 50, self.cfg.font_size_strip, 255, 60, 60);
                } else {
                    self.drawCenteredText(&img, self.currentScreen(), 28, self.cfg.font_size_strip, 255, 120, 200);
                    self.drawCenteredText(&img, if (self.auto_advance) "AUTO ON" else "AUTO OFF", 60, 16, 120, 120, 140);
                    if (self.sm_playing) {
                        var line: [name_len + track_len + 4]u8 = undefined;
                        const s = std.fmt.bufPrint(&line, "{s} - {s}", .{ self.somaChannel(), self.somaTrack() }) catch "";
                        self.drawCenteredText(&img, s[0..@min(s.len, 48)], 84, 16, 90, 200, 200);
                    }
                }
            },
            .soma => {
                if (!self.sm_online) {
                    self.drawCenteredText(&img, "SOMA OFFLINE", 50, self.cfg.font_size_strip, 255, 60, 60);
                } else {
                    self.drawCenteredText(&img, if (self.sm_playing) self.somaChannel() else "SOMA (stopped)", 28, self.cfg.font_size_strip, 120, 240, 140);
                    self.drawCenteredText(&img, self.somaTrack()[0..@min(self.somaTrack().len, 48)], 60, 16, 140, 140, 160);
                    var vol_buf: [16]u8 = undefined;
                    const vol = std.fmt.bufPrint(&vol_buf, "VOL {d}%", .{self.sm_volume}) catch "";
                    self.drawCenteredText(&img, vol, 84, 16, 200, 200, 120);
                }
            },
            .mirror => {
                var fbuf: [ws.max_w * ws.max_h * 3]u8 = undefined;
                var fw: usize = 0;
                var fh: usize = 0;
                if (self.feed.latest(&fbuf, &fw, &fh)) {
                    // Largest integer scale that fits the strip, centered.
                    const scale = @max(1, @min(deck.strip_w / fw, deck.strip_h / fh));
                    const ox = (deck.strip_w - fw * scale) / 2;
                    const oy = (deck.strip_h - fh * scale) / 2;
                    for (0..fh) |y| {
                        for (0..fw) |x| {
                            const si = (y * fw + x) * 3;
                            img.fillRect(ox + x * scale, oy + y * scale, scale, scale, fbuf[si], fbuf[si + 1], fbuf[si + 2]);
                        }
                    }
                } else {
                    render.drawTextCentered(&img, "NO SIGNAL", 38, 3, 255, 60, 60);
                }
            },
        }
        var jpeg: std.ArrayList(u8) = .empty;
        try image.encodeJpeg(&img, 90, &jpeg, arena);
        try deck.setStripImage(self.dev, 0, 0, deck.strip_w, deck.strip_h, jpeg.items);
    }

    fn keysSignature(self: *const Daemon) u64 {
        var h = std.hash.Wyhash.init(1);
        // Mirror page shows the same keys as the matrix page.
        h.update(if (self.page == .soma) "soma" else "matrix");
        h.update(self.activeKeyName());
        return h.final();
    }

    fn stripSignature(self: *const Daemon) u64 {
        var h = std.hash.Wyhash.init(2);
        h.update(@tagName(self.page));
        h.update(if (self.mx_online) "y" else "n");
        h.update(self.currentScreen());
        h.update(if (self.auto_advance) "y" else "n");
        h.update(if (self.sm_online) "y" else "n");
        h.update(if (self.sm_playing) "y" else "n");
        h.update(self.somaChannel());
        h.update(self.somaTrack());
        h.update(&.{self.sm_volume});
        return h.final();
    }

    fn syncDisplay(self: *Daemon, arena: std.mem.Allocator) !void {
        const ks = self.keysSignature();
        const ss = self.stripSignature();
        if (ks != self.keys_sig) {
            try self.drawKeys(arena);
            self.keys_sig = ks;
        }
        if (ss != self.strip_sig) {
            try self.drawStrip(arena);
            self.strip_sig = ss;
        }
    }

    /// Like syncDisplay, but a dead device propagates so the event loop
    /// can hand off to the reconnect logic instead of spinning on a
    /// corpse fd.
    fn syncDisplayChecked(self: *Daemon, arena: std.mem.Allocator) error{DeviceGone}!void {
        self.syncDisplay(arena) catch |err| switch (err) {
            error.DeviceGone => return error.DeviceGone,
            else => {},
        };
    }

    // ----------------------------------------------------------
    // Actions
    // ----------------------------------------------------------
    fn jogMatrix(self: *Daemon, arena: std.mem.Allocator, dir: i8) void {
        if (!self.mx_online or self.screen_count == 0) return;
        var pos: usize = 0;
        var i: usize = 0;
        while (i < self.screen_count) : (i += 1) {
            if (std.mem.eql(u8, self.screen_buf[i][0..self.screen_lens[i]], self.currentScreen())) pos = i;
        }
        const n = self.screen_count;
        const next = if (dir >= 0) (pos + 1) % n else (pos + n - 1) % n;
        const name = self.screen_buf[next][0..self.screen_lens[next]];
        self.mx.showScreen(arena, name) catch {
            self.mx_online = false;
            return;
        };
        copyInto(&self.current_buf, &self.current_len, name);
    }

    fn onKeys(self: *Daemon, arena: std.mem.Allocator, states: [deck.key_count]bool) void {
        for (states, 0..) |pressed, i| {
            if (!pressed or self.prev_keys[i]) continue;
            switch (self.page) {
                .matrix, .mirror => {
                    const ka = self.cfg.matrix_keys[i];
                    std.debug.print("key {d} → matrix {s}\n", .{ i, ka.screen });
                    self.mx.showScreen(arena, ka.screen) catch {
                        self.mx_online = false;
                        continue;
                    };
                    copyInto(&self.current_buf, &self.current_len, ka.screen);
                },
                .soma => {
                    const ka = self.cfg.soma_keys[i];
                    std.debug.print("key {d} → soma {s}\n", .{ i, ka.id });
                    if (std.mem.eql(u8, ka.id, "viz")) {
                        self.somaCmd(arena, "viz next");
                    } else if (std.mem.eql(u8, ka.id, "stop")) {
                        self.somaCmd(arena, "stop");
                    } else {
                        var cmd: [80]u8 = undefined;
                        const c = std.fmt.bufPrint(&cmd, "play {s}", .{ka.id}) catch continue;
                        self.somaCmd(arena, c);
                    }
                },
            }
        }
        self.prev_keys = states;
    }

    fn onDialDeltas(self: *Daemon, arena: std.mem.Allocator, deltas: [deck.dial_count]i8) void {
        for (deltas, 0..) |delta, i| {
            if (delta == 0) continue;
            switch (i) {
                0 => self.somaCmd(arena, if (delta > 0) "vol +5" else "vol -5"),
                1 => self.somaCmd(arena, if (delta > 0) "surf-next" else "surf-prev"),
                2 => self.jogMatrix(arena, if (delta > 0) 1 else -1),
                3 => {
                    const step: i16 = @as(i16, delta) * 5;
                    const next = std.math.clamp(@as(i16, self.brightness) + step, 0, 100);
                    self.brightness = @intCast(next);
                    deck.setBrightness(self.dev, self.brightness) catch {};
                },
                else => unreachable,
            }
        }
    }

    fn onDialPresses(self: *Daemon, arena: std.mem.Allocator, presses: [deck.dial_count]bool) void {
        for (presses, 0..) |pressed, i| {
            if (!pressed or self.prev_dials[i]) continue;
            switch (i) {
                0 => self.somaCmd(arena, "mute"),
                1 => self.somaCmd(arena, "toggle"),
                2 => {
                    if (!self.mx_online) break;
                    self.mx.setAutoAdvance(arena, !self.auto_advance) catch {
                        self.mx_online = false;
                        break;
                    };
                    self.auto_advance = !self.auto_advance;
                },
                3 => {
                    self.page = switch (self.page) {
                        .matrix => .soma,
                        .soma => .mirror,
                        .mirror => .matrix,
                    };
                    std.debug.print("page → {s}\n", .{@tagName(self.page)});
                },
                else => unreachable,
            }
        }
        self.prev_dials = presses;
    }
};

pub fn run(io: std.Io, dev: *hid.Device, cfg: *const config.Config) !void {
    const base_url = cfg.matrix_url;
    // The HTTP client keeps a connection pool — its allocator must NOT be
    // the cycle arena (that memory is freed every iteration).
    var http = std.http.Client{ .allocator = std.heap.page_allocator, .io = io };
    defer http.deinit();

    // Live matrix framebuffer feed (same host as the control API, port 8888).
    const feed = try std.heap.page_allocator.create(ws.FrameFeed);
    feed.* = ws.FrameFeed.init(io, base_url);
    const feed_thread = try std.Thread.spawn(.{}, ws.FrameFeed.run, .{feed});
    feed_thread.detach();

    var d: Daemon = .{
        .dev = dev,
        .mx = .{ .http = &http, .base = base_url },
        .sm = soma.Client.init(io),
        .feed = feed,
        .cfg = cfg,
        .brightness = cfg.brightness,
    };
    if (cfg.font_path) |path| {
        d.font = ttf.Font.load(std.heap.page_allocator, path) catch |err| blk: {
            std.debug.print("font: {s} failed ({s}), using built-in 8x8\n", .{ path, @errorName(err) });
            break :blk null;
        };
        if (d.font != null) std.debug.print("font: using {s}\n", .{path});
    }
    try deck.setBrightness(dev, d.brightness);

    var cycle = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer cycle.deinit();

    // Survive the cable being pulled: eventLoop exits with DeviceGone, we
    // wait for the deck to reappear, then pick up where we left off.
    while (true) {
        eventLoop(io, dev, &d, &cycle) catch |err| switch (err) {
            error.DeviceGone => {
                reconnect(io, dev, &d) catch |e| switch (e) {
                    error.DeviceGone => continue, // yanked again mid-reconnect
                    else => return e,
                };
            },
            else => return err,
        };
    }
}

fn eventLoop(io: std.Io, dev: *hid.Device, d: *Daemon, cycle: *std.heap.ArenaAllocator) !void {
    const arena = cycle.allocator();

    _ = cycle.reset(.retain_capacity);
    d.pollMatrix(arena);
    d.pollSoma(arena);
    try d.syncDisplay(arena);
    std.debug.print("daemon running (matrix: {s} current: {s} | soma: {s} playing: {})\n", .{
        d.mx.base, d.currentScreen(), if (d.sm_online) "online" else "offline", d.sm_playing,
    });

    var buf: [256]u8 = undefined;
    var last_poll = std.Io.Clock.awake.now(io).toMilliseconds();
    while (true) {
        defer _ = cycle.reset(.retain_capacity);
        if (try dev.pollReport(&buf, 250)) |len| {
            if (deck.parseReport(buf[0..len])) |report| {
                switch (report) {
                    .keys => |states| d.onKeys(arena, states),
                    .dial_deltas => |deltas| d.onDialDeltas(arena, deltas),
                    .dial_presses => |presses| d.onDialPresses(arena, presses),
                    .touch_swipe => |s| {
                        const dx = @as(i32, s.to.x) - @as(i32, s.from.x);
                        if (@abs(dx) > 60) d.jogMatrix(arena, if (dx > 0) 1 else -1);
                    },
                    else => {},
                }
                try d.syncDisplayChecked(arena);
            }
        }
        const now = std.Io.Clock.awake.now(io).toMilliseconds();
        // Mirror page: follow the framebuffer stream, throttled to ~4 fps
        // (the strip upload is a full JPEG each time; don't hammer USB).
        if (d.page == .mirror and now - d.last_mirror_ms >= 250) {
            const c = d.feed.frameCounter();
            if (c != d.mirror_drawn_counter) {
                d.mirror_drawn_counter = c;
                d.last_mirror_ms = now;
                d.drawStrip(arena) catch |err| switch (err) {
                    error.DeviceGone => return error.DeviceGone,
                    else => {},
                };
                d.strip_sig = d.stripSignature();
            }
        }
        if (now - last_poll > 2000) {
            last_poll = now;
            d.pollMatrix(arena);
            d.pollSoma(arena);
            try d.syncDisplayChecked(arena);
        }
    }
}

/// Cable was pulled: drop the corpse fd and wait for the deck to reappear
/// (it comes back on a fresh hidraw node), then re-apply settings and
/// force a full repaint.
fn reconnect(io: std.Io, dev: *hid.Device, d: *Daemon) !void {
    std.debug.print("deck unplugged — waiting for it to reappear\n", .{});
    dev.close();
    var path_buf: [64]u8 = undefined;
    while (true) {
        std.Io.sleep(io, .fromMilliseconds(500), .awake) catch {};
        const found = hid.findDevicePath(&path_buf) catch continue;
        const path = found orelse continue;
        dev.* = hid.Device.open(path) catch continue;
        std.debug.print("deck reconnected on {s}\n", .{path});
        break;
    }
    // An unplug mid-upload can leave keys half-written on the panel, and
    // input snapshots from the old session are stale: reset both so the
    // next sync repaints everything and key diffs start clean.
    d.keys_sig = 0;
    d.strip_sig = 0;
    d.prev_keys = .{false} ** deck.key_count;
    d.prev_dials = .{false} ** deck.dial_count;
    try deck.setBrightness(dev, d.brightness);
}
