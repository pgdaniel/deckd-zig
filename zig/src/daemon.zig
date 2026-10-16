//! The deckd daemon: Stream Deck <-> MQTT, driven entirely by config.
//!
//! Everything the deck does is a topic. Pages (config.pages) swap what the
//! keys and the strip show; keys, dials and the touch strip publish; labels,
//! active borders and strip lines are templates over subscribed topics (see
//! store.zig / config.zig). Nothing here knows what is on the other end.
//!
//! Events published under `<prefix>` (default "deckd"), all QoS 0:
//!   <prefix>/status            "online" / "offline" (retained; offline is the last-will)
//!   <prefix>/page              current page name (retained)
//!   <prefix>/key/<n>           "press"                     (n is 0-based)
//!   <prefix>/dial/<n>/turn     signed click count
//!   <prefix>/dial/<n>/press    "press"
//!   <prefix>/strip/swipe       "left" | "right"
//!   <prefix>/strip/tap         "x,y"
//! Control topics subscribed:
//!   <prefix>/page/set          page name or 0-based index
//!   <prefix>/brightness/set    0-100
//!
//! On the Mini (6 keys, no dials, no strip) the last key is reserved as the
//! page button: it shows the current page name and stays bordered.
//!
//! Threading: the MQTT session runs on its own thread and only writes the
//! store / a few atomics; a ping thread keeps the connection alive. The
//! event loop polls the deck, applies requests, and redraws whatever
//! changed (per-key and strip signatures), so a dead broker can't stall it.
//!
//! Memory: transient work (images, JPEGs, expanded templates) uses a
//! per-cycle arena reset each loop iteration.
const std = @import("std");
const hid = @import("hid.zig");
const deck = @import("deck.zig");
const image = @import("image.zig");
const render = @import("render.zig");
const mqtt = @import("mqtt.zig");
const config = @import("config.zig");
const ttf = @import("ttf.zig");
const store_mod = @import("store.zig");

const Atomic = std.atomic.Value;

const Daemon = struct {
    dev: *hid.Device,
    model: deck.Model,
    io: std.Io,
    cfg: *const config.Config,
    store: *store_mod.Store,
    session: *mqtt.Session,
    font: ?ttf.Font = null,

    page: usize = 0,
    brightness: u8 = 80,
    dial_vals: [config.max_pages][deck.max_dials]i32 = undefined,

    // Written by the MQTT thread, consumed by the event loop.
    req_page: Atomic(i32) = .init(-1),
    req_brightness: Atomic(i32) = .init(-1),
    link_up: Atomic(bool) = .init(false),
    link_gen: Atomic(u32) = .init(0),

    // Page background image (see config.Page.background_topic). The MQTT
    // thread fills art_buf under art_mtx; the event loop decodes it into `wall`.
    art_topic: []const u8 = "",
    art_mtx: std.Io.Mutex = .init,
    art_buf: []u8 = &.{},
    art_len: usize = 0,
    art_gen: u32 = 0,
    art_applied: u32 = 0,
    wall: image.Image = undefined,
    wall_ok: bool = false,
    // Geometry of `wall`: one canvas under the whole device. Key (c, r) shows
    // the key-sized window centered in its slot (the gaps between the LCDs
    // are skipped, as if the bezel covered them); the strip shows the band
    // below the key rows.
    wall_slot_w: usize = 0,
    wall_slot_h: usize = 0,

    page_set_topic: []const u8 = "",
    bright_set_topic: []const u8 = "",

    key_sigs: [deck.max_keys]u64 = .{0} ** deck.max_keys,
    strip_sig: u64 = 0,
    prev_keys: [deck.max_keys]bool = .{false} ** deck.max_keys,
    prev_dials: [deck.max_dials]bool = .{false} ** deck.max_dials,

    fn pageCfg(self: *const Daemon) *const config.Page {
        return &self.cfg.pages[self.page];
    }

    fn dialCfg(self: *const Daemon, i: usize) config.Dial {
        return self.pageCfg().dials[i] orelse self.cfg.dials[i];
    }

    /// Index of the reserved page-cycle key (Mini only).
    fn pageKeyIndex(model: deck.Model) ?u8 {
        if (deck.dialCount(model) != 0) return null;
        return deck.keyCount(model) - 1;
    }

    // ---- publishing ------------------------------------------------------

    fn publishEvent(self: *Daemon, comptime fmt: []const u8, args: anytype, payload: []const u8, retain: bool) void {
        var tbuf: [160]u8 = undefined;
        const topic = std.fmt.bufPrint(&tbuf, "{s}/" ++ fmt, .{self.cfg.topic_prefix} ++ args) catch return;
        self.publish(topic, payload, retain);
    }

    fn publish(self: *Daemon, topic: []const u8, payload: []const u8, retain: bool) void {
        if (topic.len == 0) return;
        self.session.publish(topic, payload, retain) catch |err| {
            std.debug.print("mqtt: publish {s} failed: {s}\n", .{ topic, @errorName(err) });
        };
    }

    fn announcePage(self: *Daemon) void {
        self.publishEvent("page", .{}, self.pageCfg().name, true);
    }

    // ---- page / brightness ----------------------------------------------

    fn setPage(self: *Daemon, idx: usize) void {
        if (idx >= self.cfg.page_count or idx == self.page) return;
        self.page = idx;
        self.key_sigs = .{0} ** deck.max_keys;
        self.strip_sig = 0;
        std.debug.print("page → {s}\n", .{self.pageCfg().name});
        self.announcePage();
    }

    fn nextPage(self: *Daemon) void {
        self.setPage((self.page + 1) % self.cfg.page_count);
    }

    fn adjustBrightness(self: *Daemon, delta: i32) void {
        self.setBrightness(@as(i32, self.brightness) + delta);
    }

    fn setBrightness(self: *Daemon, v: i32) void {
        self.brightness = @intCast(std.math.clamp(v, 0, 100));
        deck.setBrightness(self.model, self.dev, self.brightness) catch {};
    }

    /// Apply what the MQTT thread asked for.
    fn applyRequests(self: *Daemon) void {
        const rp = self.req_page.swap(-1, .acq_rel);
        if (rp >= 0) self.setPage(@intCast(rp));
        const rb = self.req_brightness.swap(-1, .acq_rel);
        if (rb >= 0) self.setBrightness(rb);
    }

    // ---- MQTT callbacks (run on the session thread) ----------------------

    fn onMessage(ctx: *anyopaque, topic: []const u8, payload: []const u8) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, topic, self.page_set_topic)) {
            if (std.fmt.parseInt(u16, std.mem.trim(u8, payload, " "), 10)) |n| {
                self.req_page.store(n, .release);
            } else |_| for (self.cfg.pages[0..self.cfg.page_count], 0..) |p, i| {
                if (std.ascii.eqlIgnoreCase(p.name, payload)) self.req_page.store(@intCast(i), .release);
            }
        } else if (std.mem.eql(u8, topic, self.bright_set_topic)) {
            if (std.fmt.parseInt(i32, std.mem.trim(u8, payload, " "), 10)) |v| {
                self.req_brightness.store(v, .release);
            } else |_| {}
        } else if (self.art_topic.len > 0 and std.mem.eql(u8, topic, self.art_topic)) {
            self.setArt(payload);
        } else {
            _ = self.store.set(topic, payload);
        }
    }

    fn setArt(self: *Daemon, payload: []const u8) void {
        self.art_mtx.lockUncancelable(self.io);
        defer self.art_mtx.unlock(self.io);
        if (payload.len > self.art_buf.len) {
            std.debug.print("art: {d} byte image too big, ignoring\n", .{payload.len});
            self.art_len = 0;
        } else {
            @memcpy(self.art_buf[0..payload.len], payload);
            self.art_len = payload.len;
        }
        self.art_gen +%= 1;
    }

    /// Decode a newly arrived image into the key-grid-sized `wall`.
    fn refreshArt(self: *Daemon) void {
        if (self.art_topic.len == 0) return;
        self.art_mtx.lockUncancelable(self.io);
        defer self.art_mtx.unlock(self.io);
        if (self.art_gen == self.art_applied) return;
        self.art_applied = self.art_gen;
        self.wall_ok = false;
        if (self.art_len == 0) return;
        image.decodeCover(&self.wall, self.art_buf[0..self.art_len]) catch |err| {
            std.debug.print("art: decode failed ({s})\n", .{@errorName(err)});
            return;
        };
        self.wall_ok = true;
    }

    fn onState(ctx: *anyopaque, connected: bool) void {
        const self: *Daemon = @ptrCast(@alignCast(ctx));
        self.link_up.store(connected, .release);
        _ = self.link_gen.fetchAdd(1, .acq_rel);
        if (connected) {
            self.publishEvent("status", .{}, "online", true);
            self.announcePage();
        }
    }

    // ---- drawing ---------------------------------------------------------

    const KeyView = struct { label: []const u8, active: bool };

    fn keyView(self: *Daemon, arena: std.mem.Allocator, ka: *const config.Key) KeyView {
        var active = false;
        if (ka.active_topic.len > 0) {
            if (self.store.get(arena, ka.active_topic)) |v| {
                active = if (ka.active_value.len > 0)
                    std.mem.eql(u8, v, ka.active_value)
                else
                    std.ascii.eqlIgnoreCase(v, "on") or std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true");
            }
        }
        return .{ .label = self.store.expand(arena, ka.label, self.pageCfg().name), .active = active };
    }

    fn bgFor(self: *Daemon, page: *const config.Page) ?*const image.Image {
        if (self.wall_ok and page.background_topic.len > 0 and std.mem.eql(u8, page.background_topic, self.art_topic)) return &self.wall;
        return null;
    }

    fn syncDisplay(self: *Daemon, arena: std.mem.Allocator) !void {
        const kc = deck.keyCount(self.model);
        const content_kc = if (pageKeyIndex(self.model)) |_| kc - 1 else kc;
        const page = self.pageCfg();
        self.refreshArt();
        const bg = self.bgFor(page);
        for (page.keys[0..content_kc], 0..) |*ka, i| {
            const v = self.keyView(arena, ka);
            var h = std.hash.Wyhash.init(self.page + 1);
            h.update(v.label);
            h.update(if (v.active) "1" else "0");
            if (bg != null) h.update(std.mem.asBytes(&self.art_applied));
            const sig = h.final();
            if (sig == self.key_sigs[i]) continue;
            try self.drawKey(arena, @intCast(i), v.label, ka.icon, ka.r, ka.g, ka.b, v.active, bg);
            self.key_sigs[i] = sig;
        }
        if (pageKeyIndex(self.model)) |pk| {
            var h = std.hash.Wyhash.init(self.page + 1);
            h.update("pagekey");
            const sig = h.final();
            if (sig != self.key_sigs[pk]) {
                try self.drawKey(arena, pk, page.name, "", page.r, page.g, page.b, true, null);
                self.key_sigs[pk] = sig;
            }
        }
        if (deck.hasStrip(self.model)) try self.syncStrip(arena);
    }

    fn syncStrip(self: *Daemon, arena: std.mem.Allocator) !void {
        const page = self.pageCfg();
        var lines: [config.max_strip_lines][]const u8 = undefined;
        for (page.strip, 0..) |t, i| lines[i] = self.store.expand(arena, t, page.name);
        const up = self.link_up.load(.acquire);
        const unconfigured = self.cfg.mqtt_host.len == 0;

        var h = std.hash.Wyhash.init(self.page + 100);
        for (lines) |l| h.update(l);
        h.update(if (up) "1" else "0");
        const bg = self.bgFor(page);
        if (bg != null) h.update(std.mem.asBytes(&self.art_applied));
        const sig = h.final();
        if (sig == self.strip_sig) return;

        const sw = deck.stripW(self.model);
        const sh = deck.stripH(self.model);
        var img = try image.Image.init(arena, sw, sh);
        img.fill(8, 8, 12);
        if (bg) |wall| image.blitDim(&img, wall, 0, 2 * self.wall_slot_h, 40);
        if (unconfigured) {
            self.drawCenteredText(&img, "MQTT NOT CONFIGURED", 50, self.cfg.font_size_strip, 255, 60, 60);
        } else if (!up) {
            self.drawCenteredText(&img, "MQTT OFFLINE", 28, self.cfg.font_size_strip, 255, 60, 60);
            self.drawCenteredText(&img, self.cfg.mqtt_host[0..@min(self.cfg.mqtt_host.len, 40)], 60, 16, 140, 140, 160);
        } else {
            const ys = [config.max_strip_lines]usize{ 28, 60, 84 };
            const sizes = [config.max_strip_lines]u16{ self.cfg.font_size_strip, 16, 16 };
            const colors = [config.max_strip_lines][3]u8{ .{ page.r, page.g, page.b }, .{ 140, 140, 160 }, .{ 200, 200, 120 } };
            for (lines, 0..) |l, i| {
                if (l.len == 0) continue;
                self.drawCenteredText(&img, l[0..@min(l.len, 48)], ys[i], sizes[i], colors[i][0], colors[i][1], colors[i][2]);
            }
        }
        var jpeg: std.ArrayList(u8) = .empty;
        try image.encodeJpeg(&img, 90, &jpeg, arena);
        try deck.setStripImage(self.dev, 0, 0, sw, sh, jpeg.items);
        self.strip_sig = sig;
    }

    /// Draw one key's canvas: an icon file if configured (scaled to fit,
    /// alpha-blended, centered — falling back to the label if it fails to
    /// load), else the label text.
    fn drawKey(self: *Daemon, arena: std.mem.Allocator, key: u8, label: []const u8, icon: []const u8, r: u8, g: u8, b: u8, active: bool, bg: ?*const image.Image) !void {
        const kpx = deck.keyPx(self.model);
        var img = try image.Image.init(arena, kpx, kpx);
        img.fill(r / 6, g / 6, b / 6);
        if (bg) |wall| {
            const cols: usize = deck.keyCount(self.model) / 2;
            const sx = (key % cols) * self.wall_slot_w + (self.wall_slot_w - kpx) / 2;
            const sy = (key / cols) * self.wall_slot_h + (self.wall_slot_h - kpx) / 2;
            image.blitDim(&img, wall, sx, sy, 40);
        }
        if (icon.len > 0) {
            image.drawIconFit(&img, icon) catch |err| {
                std.debug.print("icon: {s} failed ({s}), falling back to label\n", .{ icon, @errorName(err) });
                self.drawCenteredText(&img, label, kpx / 2, self.cfg.font_size_key, r, g, b);
            };
        } else {
            self.drawCenteredText(&img, label, kpx / 2, self.cfg.font_size_key, r, g, b);
        }
        if (active) render.border(&img, 4, 255, 255, 255);
        try deck.setKeyImage(self.model, self.dev, key, &img);
    }

    fn drawCenteredText(self: *Daemon, img: *image.Image, text: []const u8, cy: usize, px: u16, r: u8, g: u8, b: u8) void {
        if (self.font) |*f| {
            f.drawCentered(img, text, img.w / 2, cy, px, r, g, b);
        } else {
            const scale: usize = if (px >= 28) 3 else if (px >= 12) 2 else 1;
            render.drawTextCentered(img, text, cy -| 4 * scale, scale, r, g, b);
        }
    }

    fn syncDisplayChecked(self: *Daemon, arena: std.mem.Allocator) error{DeviceGone}!void {
        self.syncDisplay(arena) catch |err| switch (err) {
            error.DeviceGone => return error.DeviceGone,
            else => {},
        };
    }

    // ---- input -----------------------------------------------------------

    fn onKeys(self: *Daemon, states: [deck.max_keys]bool) void {
        const kc = deck.keyCount(self.model);
        const page_key = pageKeyIndex(self.model);
        for (states[0..kc], 0..) |pressed, i| {
            if (!pressed or self.prev_keys[i]) continue;
            if (page_key != null and i == page_key.?) {
                self.nextPage();
                continue;
            }
            self.publishEvent("key/{d}", .{i}, "press", false);
            const ka = &self.pageCfg().keys[i];
            if (ka.topic.len == 0) continue;
            std.debug.print("key {d} → {s} {s}\n", .{ i, ka.topic, ka.payload });
            self.publish(ka.topic, ka.payload, ka.retain);
        }
        self.prev_keys = states;
    }

    fn runAction(self: *Daemon, action: config.Action, delta: i32) void {
        switch (action) {
            .none => {},
            .page => self.nextPage(),
            .brightness => self.adjustBrightness(delta),
        }
    }

    fn onDialDeltas(self: *Daemon, deltas: [deck.max_dials]i8) void {
        const dc = deck.dialCount(self.model);
        for (deltas[0..dc], 0..) |delta, i| {
            if (delta == 0) continue;
            var nbuf: [16]u8 = undefined;
            self.publishEvent("dial/{d}/turn", .{i}, std.fmt.bufPrint(&nbuf, "{d}", .{delta}) catch "", false);
            const d = self.dialCfg(i);
            const step = @as(i32, delta) * d.turn_step;
            if (d.turn_action != .none) {
                self.runAction(d.turn_action, step);
                continue;
            }
            if (d.turn_topic.len == 0) continue;
            var v = step;
            if (d.turn_mode == .value) {
                const slot = &self.dial_vals[self.page][i];
                slot.* = std.math.clamp(slot.* + step, d.turn_min, d.turn_max);
                v = slot.*;
            }
            self.publish(d.turn_topic, std.fmt.bufPrint(&nbuf, "{d}", .{v}) catch continue, false);
        }
    }

    fn onDialPresses(self: *Daemon, presses: [deck.max_dials]bool) void {
        const dc = deck.dialCount(self.model);
        for (presses[0..dc], 0..) |pressed, i| {
            if (!pressed or self.prev_dials[i]) continue;
            self.publishEvent("dial/{d}/press", .{i}, "press", false);
            const d = self.dialCfg(i);
            if (d.press_action != .none) {
                self.runAction(d.press_action, 0);
            } else if (d.press_topic.len > 0) {
                self.publish(d.press_topic, d.press_payload, false);
            }
        }
        self.prev_dials = presses;
    }

    fn onTouch(self: *Daemon, report: deck.Report) void {
        switch (report) {
            .touch_swipe => |s| {
                const dx = @as(i32, s.to.x) - @as(i32, s.from.x);
                if (@abs(dx) > 60) self.publishEvent("strip/swipe", .{}, if (dx > 0) "right" else "left", false);
            },
            .touch_tap => |p| {
                var buf: [24]u8 = undefined;
                self.publishEvent("strip/tap", .{}, std.fmt.bufPrint(&buf, "{d},{d}", .{ p.x, p.y }) catch "", false);
            },
            else => {},
        }
    }
};

pub fn run(io: std.Io, dev: *hid.Device, model: deck.Model, cfg: *const config.Config) !void {
    const gpa = std.heap.page_allocator;

    const store = try gpa.create(store_mod.Store);
    store.* = .{ .io = io };
    for (cfg.pages[0..cfg.page_count]) |*p| {
        for (p.keys) |k| {
            store.register(k.active_topic);
            store.registerTemplate(k.label);
        }
        for (p.strip) |t| store.registerTemplate(t);
    }

    var art_topic: []const u8 = "";
    for (cfg.pages[0..cfg.page_count]) |*p| {
        if (p.background_topic.len == 0) continue;
        if (art_topic.len == 0) {
            art_topic = p.background_topic;
        } else if (!std.mem.eql(u8, art_topic, p.background_topic)) {
            std.debug.print("config: only one background_topic is supported, ignoring {s}\n", .{p.background_topic});
        }
    }

    const session = try gpa.create(mqtt.Session);
    var d: Daemon = .{
        .dev = dev,
        .model = model,
        .io = io,
        .cfg = cfg,
        .store = store,
        .session = session,
        .brightness = cfg.brightness,
    };
    if (art_topic.len > 0) {
        d.art_topic = art_topic;
        d.art_buf = try gpa.alloc(u8, 192 * 1024);
        const kpx: usize = deck.keyPx(model);
        const cols: usize = deck.keyCount(model) / 2;
        if (deck.hasStrip(model)) {
            d.wall_slot_w = deck.stripW(model) / cols;
            d.wall_slot_h = kpx + 20;
        } else {
            d.wall_slot_w = kpx;
            d.wall_slot_h = kpx;
        }
        const strip_h: usize = if (deck.hasStrip(model)) deck.stripH(model) else 0;
        d.wall = try image.Image.init(gpa, cols * d.wall_slot_w, 2 * d.wall_slot_h + strip_h);
    }
    for (&d.dial_vals, 0..) |*row, pi| {
        for (row, 0..) |*v, di| v.* = (cfg.pages[pi].dials[di] orelse cfg.dials[di]).turn_start;
    }

    d.page_set_topic = try std.fmt.allocPrint(gpa, "{s}/page/set", .{cfg.topic_prefix});
    d.bright_set_topic = try std.fmt.allocPrint(gpa, "{s}/brightness/set", .{cfg.topic_prefix});
    const status_topic = try std.fmt.allocPrint(gpa, "{s}/status", .{cfg.topic_prefix});

    var subs: std.ArrayList([]const u8) = .empty;
    try subs.append(gpa, d.page_set_topic);
    try subs.append(gpa, d.bright_set_topic);
    try subs.appendSlice(gpa, store.topics[0..store.count]);
    if (art_topic.len > 0) try subs.append(gpa, art_topic);

    session.* = .{
        .io = io,
        .host = cfg.mqtt_host,
        .port = cfg.mqtt_port,
        .username = cfg.mqtt_user,
        .password = cfg.mqtt_pass,
        .client_id = "deckd",
        .will = .{ .topic = status_topic, .payload = "offline" },
        .subscriptions = subs.items,
        .ctx = &d,
        .on_message = Daemon.onMessage,
        .on_state = Daemon.onState,
    };

    if (cfg.font_path) |path| {
        d.font = ttf.Font.load(gpa, path) catch |err| blk: {
            std.debug.print("font: {s} failed ({s}), using built-in 8x8\n", .{ path, @errorName(err) });
            break :blk null;
        };
        if (d.font != null) std.debug.print("font: using {s}\n", .{path});
    }
    try deck.reset(model, dev);
    try deck.setBrightness(model, dev, d.brightness);

    const mq_thread = try std.Thread.spawn(.{}, mqtt.Session.run, .{session});
    mq_thread.detach();
    const ping_thread = try std.Thread.spawn(.{}, pingLoop, .{ io, session });
    ping_thread.detach();

    var cycle = std.heap.ArenaAllocator.init(gpa);
    defer cycle.deinit();

    while (true) {
        eventLoop(dev, model, &d, &cycle) catch |err| switch (err) {
            error.DeviceGone => {
                reconnect(io, dev, model, &d) catch |e| switch (e) {
                    error.DeviceGone => continue,
                    else => return e,
                };
            },
            else => return err,
        };
    }
}

fn pingLoop(io: std.Io, session: *mqtt.Session) void {
    while (true) {
        std.Io.sleep(io, .fromMilliseconds(20_000), .awake) catch {};
        session.ping();
    }
}

fn eventLoop(dev: *hid.Device, model: deck.Model, d: *Daemon, cycle: *std.heap.ArenaAllocator) !void {
    const arena = cycle.allocator();
    _ = cycle.reset(.retain_capacity);
    try d.syncDisplay(arena);
    std.debug.print("daemon running ({s}, broker: {s}:{d}, {d} pages)\n", .{
        @tagName(model), d.cfg.mqtt_host, d.cfg.mqtt_port, d.cfg.page_count,
    });

    var buf: [256]u8 = undefined;
    while (true) {
        defer _ = cycle.reset(.retain_capacity);
        if (try dev.pollReport(&buf, 250)) |len| {
            if (deck.parseReport(model, buf[0..len])) |report| {
                switch (report) {
                    .keys => |states| d.onKeys(states),
                    .dial_deltas => |deltas| d.onDialDeltas(deltas),
                    .dial_presses => |presses| d.onDialPresses(presses),
                    .touch_swipe, .touch_tap => if (deck.hasStrip(model)) d.onTouch(report),
                    else => {},
                }
            }
        }
        d.applyRequests();
        // Cheap when nothing changed: per-key/strip signatures gate the USB writes.
        try d.syncDisplayChecked(arena);
    }
}

fn reconnect(io: std.Io, dev: *hid.Device, model: deck.Model, d: *Daemon) !void {
    std.debug.print("deck unplugged — waiting for it to reappear\n", .{});
    dev.close();
    var path_buf: [64]u8 = undefined;
    while (true) {
        std.Io.sleep(io, .fromMilliseconds(500), .awake) catch {};
        const found = hid.findDevice(&path_buf) catch continue;
        const info = found orelse continue;
        if (info.model != model) continue;
        dev.* = hid.Device.open(info.path[0..info.path_len]) catch continue;
        std.debug.print("deck reconnected on {s}\n", .{info.path[0..info.path_len]});
        break;
    }
    d.key_sigs = .{0} ** deck.max_keys;
    d.strip_sig = 0;
    d.prev_keys = .{false} ** deck.max_keys;
    d.prev_dials = .{false} ** deck.max_dials;
    try deck.setBrightness(model, dev, d.brightness);
}
