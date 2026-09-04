//! The deckd daemon: Stream Deck → matrix control API + soma player IPC
//! + MQTT broker.
//!
//! On the Plus (8 keys + strip + 4 dials):
//!   Pages (knob 4 push cycles them) swap what the 8 keys and the strip show:
//!     MATRIX — keys direct-select matrix screens (white border = active),
//!              strip shows screen name / auto-advance / soma now-playing.
//!     SOMA   — keys are SomaFM channel presets + VIZ + STOP (border = playing),
//!              strip shows channel / track / volume.
//!     MQTT   — keys publish their configured topic/payload to the broker,
//!              strip shows the broker and the last thing published.
//!     MIRROR — strip shows live matrix framebuffer; keys behave like MATRIX.
//!   Knobs (fixed roles on all pages):
//!     knob 1 rotate: soma volume        push: mute toggle
//!     knob 2 rotate: soma channel surf  push: play/stop toggle
//!     knob 3 rotate: matrix screen jog  push: auto-advance toggle
//!     knob 4 rotate: deck LCD brightness  push: switch page
//!   Strip left/right swipe jogs matrix screens too.
//!
//! On the Mini (6 keys, no strip, no dials):
//!   No knobs, so the last key is reserved as the page button: tap it to
//!   cycle MATRIX → SOMA → MQTT → MATRIX (no MIRROR page — that only drives
//!   the strip, which the Mini doesn't have). Its image always shows the
//!   current page name and stays bordered so it reads as "the button that
//!   does something else". The other 5 keys behave like the Plus's
//!   per-page keys (screen-select / SomaFM preset / MQTT publish).
//!
//! Threading: a poller thread refreshes matrix/soma state every 2 s and
//! swaps it in wholesale (see PollState); the event loop never blocks on
//! the network for state, so an unreachable matrix can't stall key/knob
//! handling. Commands (key presses, knob turns) still go out
//! synchronously — fast when the target is up, and skipped entirely when
//! the latest snapshot already says it's offline. MQTT key presses just
//! enqueue the publish; a publisher thread does the broker I/O, so a
//! dead broker can't stall the deck either.
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
const mqtt = @import("mqtt.zig");
const ws = @import("ws.zig");
const config = @import("config.zig");
const ttf = @import("ttf.zig");

const Page = enum { matrix, soma, mirror, mqtt };

const max_screens = 16;
const name_len = 64;
const track_len = 128;

const PollState = struct {
    mx_online: bool = false,
    auto_advance: bool = false,
    current_buf: [name_len]u8 = undefined,
    current_len: usize = 0,
    screen_buf: [max_screens][name_len]u8 = undefined,
    screen_lens: [max_screens]usize = .{0} ** max_screens,
    screen_count: usize = 0,

    sm_online: bool = false,
    sm_playing: bool = false,
    sm_volume: u8 = 0,
    sm_channel_buf: [name_len]u8 = undefined,
    sm_channel_len: usize = 0,
    sm_id_buf: [name_len]u8 = undefined,
    sm_id_len: usize = 0,
    sm_track_buf: [track_len]u8 = undefined,
    sm_track_len: usize = 0,

    mq_online: bool = true,
    last_pub_buf: [128]u8 = undefined,
    last_pub_len: usize = 0,

    fn currentScreen(self: *const PollState) []const u8 {
        return self.current_buf[0..self.current_len];
    }

    fn somaChannel(self: *const PollState) []const u8 {
        return self.sm_channel_buf[0..self.sm_channel_len];
    }

    fn somaId(self: *const PollState) []const u8 {
        return self.sm_id_buf[0..self.sm_id_len];
    }

    fn somaTrack(self: *const PollState) []const u8 {
        return self.sm_track_buf[0..self.sm_track_len];
    }

    fn lastPub(self: *const PollState) []const u8 {
        return self.last_pub_buf[0..self.last_pub_len];
    }
};

const PubItem = struct {
    topic_buf: [128]u8 = undefined,
    topic_len: usize = 0,
    payload_buf: [256]u8 = undefined,
    payload_len: usize = 0,

    fn topic(self: *const PubItem) []const u8 {
        return self.topic_buf[0..self.topic_len];
    }

    fn payload(self: *const PubItem) []const u8 {
        return self.payload_buf[0..self.payload_len];
    }
};

const Daemon = struct {
    dev: *hid.Device,
    model: deck.Model,
    io: std.Io,
    mx: matrix.Client,
    sm: soma.Client,
    mq: mqtt.Client,
    feed: *ws.FrameFeed,
    cfg: *const config.Config,
    font: ?ttf.Font = null,

    page: Page = .matrix,
    mirror_drawn_counter: u64 = 0,
    last_mirror_ms: i64 = 0,

    state: PollState = .{},
    state_mtx: std.Io.Mutex = .init,
    state_gen: u64 = 0,
    cmd_gen: u64 = 0,

    pub_queue: [16]PubItem = undefined,
    pub_head: usize = 0,
    pub_tail: usize = 0,
    pub_dropped: u64 = 0,

    keys_sig: u64 = 0,
    strip_sig: u64 = 0,

    brightness: u8 = 80,
    mqtt_intensity: u8 = 50,
    prev_keys: [deck.max_keys]bool = .{false} ** deck.max_keys,
    prev_dials: [deck.max_dials]bool = .{false} ** deck.max_dials,

    fn snapshot(self: *Daemon) PollState {
        self.state_mtx.lockUncancelable(self.io);
        defer self.state_mtx.unlock(self.io);
        return self.state;
    }

    fn generation(self: *Daemon) u64 {
        self.state_mtx.lockUncancelable(self.io);
        defer self.state_mtx.unlock(self.io);
        return self.state_gen;
    }

    fn swapState(self: *Daemon, next_in: PollState, gen_at_start: u64) void {
        self.state_mtx.lockUncancelable(self.io);
        defer self.state_mtx.unlock(self.io);
        if (self.cmd_gen != gen_at_start) return;
        var next = next_in;
        next.mq_online = self.state.mq_online;
        next.last_pub_buf = self.state.last_pub_buf;
        next.last_pub_len = self.state.last_pub_len;
        self.state = next;
        self.state_gen +%= 1;
    }

    fn noteScreenSet(self: *Daemon, name: []const u8) void {
        self.state_mtx.lockUncancelable(self.io);
        defer self.state_mtx.unlock(self.io);
        copyInto(&self.state.current_buf, &self.state.current_len, name);
        self.cmd_gen +%= 1;
        self.state_gen +%= 1;
    }

    fn noteAutoAdvanceSet(self: *Daemon, on: bool) void {
        self.state_mtx.lockUncancelable(self.io);
        defer self.state_mtx.unlock(self.io);
        self.state.auto_advance = on;
        self.cmd_gen +%= 1;
        self.state_gen +%= 1;
    }

    fn noteSomaStatus(self: *Daemon, st: ?soma.Status) void {
        self.state_mtx.lockUncancelable(self.io);
        defer self.state_mtx.unlock(self.io);
        if (st) |s| {
            self.state.sm_online = true;
            self.state.sm_playing = s.playing or s.connecting;
            self.state.sm_volume = s.volume;
            copyInto(&self.state.sm_channel_buf, &self.state.sm_channel_len, s.channel);
            copyInto(&self.state.sm_id_buf, &self.state.sm_id_len, s.channel_id);
            copyInto(&self.state.sm_track_buf, &self.state.sm_track_len, s.track);
        } else {
            self.state.sm_online = false;
            self.state.sm_playing = false;
        }
        self.cmd_gen +%= 1;
        self.state_gen +%= 1;
    }

    fn enqueuePublish(self: *Daemon, topic: []const u8, payload: []const u8) void {
        if (topic.len == 0 or topic.len > 128 or payload.len > 256) {
            std.debug.print("mqtt: topic/payload too long, dropped\n", .{});
            return;
        }
        self.state_mtx.lockUncancelable(self.io);
        defer self.state_mtx.unlock(self.io);
        const next = (self.pub_head + 1) % self.pub_queue.len;
        if (next == self.pub_tail) {
            self.pub_dropped +%= 1;
            std.debug.print("mqtt: publish queue full, dropped ({d} total)\n", .{self.pub_dropped});
            return;
        }
        var item = &self.pub_queue[self.pub_head];
        @memcpy(item.topic_buf[0..topic.len], topic);
        item.topic_len = topic.len;
        @memcpy(item.payload_buf[0..payload.len], payload);
        item.payload_len = payload.len;
        self.pub_head = next;
    }

    fn dequeuePublish(self: *Daemon) ?PubItem {
        self.state_mtx.lockUncancelable(self.io);
        defer self.state_mtx.unlock(self.io);
        if (self.pub_tail == self.pub_head) return null;
        const item = self.pub_queue[self.pub_tail];
        self.pub_tail = (self.pub_tail + 1) % self.pub_queue.len;
        return item;
    }

    fn notePublished(self: *Daemon, ok: bool, line: []const u8) void {
        self.state_mtx.lockUncancelable(self.io);
        defer self.state_mtx.unlock(self.io);
        self.state.mq_online = ok;
        if (ok) copyInto(&self.state.last_pub_buf, &self.state.last_pub_len, line);
        self.state_gen +%= 1;
    }

    fn copyInto(buf: []u8, len: *usize, s: []const u8) void {
        const n = @min(s.len, buf.len);
        @memcpy(buf[0..n], s[0..n]);
        len.* = n;
    }

    fn somaCmd(self: *Daemon, arena: std.mem.Allocator, cmd: []const u8) void {
        _ = self.sm.command(arena, cmd) catch {
            self.noteSomaStatus(null);
            return;
        };
        std.Io.sleep(self.sm.io, .fromMilliseconds(60), .awake) catch {};
        const st = self.sm.status(arena) catch {
            self.noteSomaStatus(null);
            return;
        };
        self.noteSomaStatus(st);
    }

    fn activeKeyName(self: *const Daemon, snap: *const PollState) []const u8 {
        return switch (self.page) {
            .matrix, .mirror => if (snap.mx_online) snap.currentScreen() else "",
            .soma => if (snap.sm_online and snap.sm_playing) snap.somaId() else "",
            .mqtt => "",
        };
    }

    /// Index of the reserved page-cycle key, on devices with no dials to
    /// drive page switching otherwise (the Mini). Null on devices that
    /// switch pages via a knob push instead (the Plus), where all keys are
    /// content keys.
    fn pageKeyIndex(model: deck.Model) ?u8 {
        if (deck.dialCount(model) != 0) return null;
        return deck.keyCount(model) - 1;
    }

    fn drawKeys(self: *Daemon, arena: std.mem.Allocator, snap: *const PollState) !void {
        const kc = deck.keyCount(self.model);
        const content_kc = if (pageKeyIndex(self.model)) |_| kc - 1 else kc;
        switch (self.page) {
            .matrix, .mirror => for (self.cfg.matrix_keys[0..content_kc], 0..) |ka, i| {
                try self.drawKey(arena, @intCast(i), ka.label, ka.icon, ka.r, ka.g, ka.b, std.mem.eql(u8, ka.screen, self.activeKeyName(snap)));
            },
            .soma => for (self.cfg.soma_keys[0..content_kc], 0..) |ka, i| {
                try self.drawKey(arena, @intCast(i), ka.label, ka.icon, ka.r, ka.g, ka.b, std.mem.eql(u8, ka.id, self.activeKeyName(snap)));
            },
            .mqtt => for (self.cfg.mqtt_keys[0..content_kc], 0..) |ka, i| {
                try self.drawKey(arena, @intCast(i), ka.label, ka.icon, ka.r, ka.g, ka.b, false);
            },
        }
        if (pageKeyIndex(self.model)) |pk| try self.drawPageKey(arena, pk);
    }

    /// The reserved page button: always shows the current page's name, and
    /// stays bordered (like an "active" content key) so it's visually
    /// distinct from the content keys around it.
    fn drawPageKey(self: *Daemon, arena: std.mem.Allocator, key: u8) !void {
        const label: []const u8 = switch (self.page) {
            .matrix, .mirror => "MATRIX",
            .soma => "SOMA",
            .mqtt => "MQTT",
        };
        const rgb: [3]u8 = switch (self.page) {
            .matrix, .mirror => .{ 0, 220, 255 },
            .soma => .{ 120, 220, 120 },
            .mqtt => .{ 240, 180, 60 },
        };
        try self.drawKey(arena, key, label, "", rgb[0], rgb[1], rgb[2], true);
    }

    /// Draw one key's canvas: an icon file if configured (scaled to fit,
    /// alpha-blended, centered — falling back to the label if it fails to
    /// load), else the label text.
    fn drawKey(self: *Daemon, arena: std.mem.Allocator, key: u8, label: []const u8, icon: []const u8, r: u8, g: u8, b: u8, active: bool) !void {
        const kpx = deck.keyPx(self.model);
        var img = try image.Image.init(arena, kpx, kpx);
        img.fill(r / 6, g / 6, b / 6);
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

    fn drawStrip(self: *Daemon, arena: std.mem.Allocator, snap: *const PollState) !void {
        if (!deck.hasStrip(self.model)) return;
        const sw = deck.stripW(self.model);
        const sh = deck.stripH(self.model);
        var img = try image.Image.init(arena, sw, sh);
        img.fill(8, 8, 12);
        switch (self.page) {
            .matrix => {
                if (!snap.mx_online) {
                    self.drawCenteredText(&img, "MATRIX OFFLINE", 50, self.cfg.font_size_strip, 255, 60, 60);
                } else {
                    self.drawCenteredText(&img, snap.currentScreen(), 28, self.cfg.font_size_strip, 255, 120, 200);
                    self.drawCenteredText(&img, if (snap.auto_advance) "AUTO ON" else "AUTO OFF", 60, 16, 120, 120, 140);
                    if (snap.sm_playing) {
                        var line: [name_len + track_len + 4]u8 = undefined;
                        const s = std.fmt.bufPrint(&line, "{s} - {s}", .{ snap.somaChannel(), snap.somaTrack() }) catch "";
                        self.drawCenteredText(&img, s[0..@min(s.len, 48)], 84, 16, 90, 200, 200);
                    }
                }
            },
            .soma => {
                if (!snap.sm_online) {
                    self.drawCenteredText(&img, "SOMA OFFLINE", 50, self.cfg.font_size_strip, 255, 60, 60);
                } else {
                    self.drawCenteredText(&img, if (snap.sm_playing) snap.somaChannel() else "SOMA (stopped)", 28, self.cfg.font_size_strip, 120, 240, 140);
                    self.drawCenteredText(&img, snap.somaTrack()[0..@min(snap.somaTrack().len, 48)], 60, 16, 140, 140, 160);
                    var vol_buf: [16]u8 = undefined;
                    const vol = std.fmt.bufPrint(&vol_buf, "VOL {d}%", .{snap.sm_volume}) catch "";
                    self.drawCenteredText(&img, vol, 84, 16, 200, 200, 120);
                }
            },
            .mirror => {
                var fbuf: [ws.max_w * ws.max_h * 3]u8 = undefined;
                var fw: usize = 0;
                var fh: usize = 0;
                if (self.feed.latest(&fbuf, &fw, &fh)) {
                    const scale = @max(1, @min(sw / fw, sh / fh));
                    const ox = (sw - fw * scale) / 2;
                    const oy = (sh - fh * scale) / 2;
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
            .mqtt => {
                if (self.cfg.mqtt_host.len == 0) {
                    self.drawCenteredText(&img, "MQTT NOT CONFIGURED", 50, self.cfg.font_size_strip, 255, 60, 60);
                } else if (!snap.mq_online) {
                    self.drawCenteredText(&img, "MQTT OFFLINE", 28, self.cfg.font_size_strip, 255, 60, 60);
                    self.drawCenteredText(&img, self.cfg.mqtt_host[0..@min(self.cfg.mqtt_host.len, 40)], 60, 16, 140, 140, 160);
                } else {
                    self.drawCenteredText(&img, "MQTT", 28, self.cfg.font_size_strip, 240, 180, 60);
                    self.drawCenteredText(&img, self.cfg.mqtt_host[0..@min(self.cfg.mqtt_host.len, 40)], 60, 16, 140, 140, 160);
                    if (self.cfg.mqtt_intensity_topic.len > 0) {
                        var intensity_buf: [16]u8 = undefined;
                        const intensity_text = std.fmt.bufPrint(&intensity_buf, "Intensity: {d}%", .{self.mqtt_intensity}) catch "Intensity: --";
                        self.drawCenteredText(&img, intensity_text, 84, 16, 200, 160, 60);
                    } else {
                        self.drawCenteredText(&img, snap.lastPub()[0..@min(snap.lastPub().len, 48)], 84, 16, 200, 160, 60);
                    }
                }
            },
        }
        var jpeg: std.ArrayList(u8) = .empty;
        try image.encodeJpeg(&img, 90, &jpeg, arena);
        try deck.setStripImage(self.dev, 0, 0, sw, sh, jpeg.items);
    }

    fn keysSignature(self: *const Daemon, snap: *const PollState) u64 {
        var h = std.hash.Wyhash.init(1);
        h.update(if (self.page == .soma) "soma" else if (self.page == .mqtt) "mqtt" else "matrix");
        h.update(self.activeKeyName(snap));
        return h.final();
    }

    fn stripSignature(self: *const Daemon, snap: *const PollState) u64 {
        var h = std.hash.Wyhash.init(2);
        h.update(@tagName(self.page));
        h.update(if (snap.mx_online) "y" else "n");
        h.update(snap.currentScreen());
        h.update(if (snap.auto_advance) "y" else "n");
        h.update(if (snap.sm_online) "y" else "n");
        h.update(if (snap.sm_playing) "y" else "n");
        h.update(snap.somaChannel());
        h.update(snap.somaTrack());
        h.update(&.{snap.sm_volume});
        h.update(if (snap.mq_online) "y" else "n");
        h.update(snap.lastPub());
        h.update(&.{self.mqtt_intensity});
        return h.final();
    }

    fn syncDisplay(self: *Daemon, arena: std.mem.Allocator, snap: *const PollState) !void {
        const ks = self.keysSignature(snap);
        if (ks != self.keys_sig) {
            try self.drawKeys(arena, snap);
            self.keys_sig = ks;
        }
        if (deck.hasStrip(self.model)) {
            const ss = self.stripSignature(snap);
            if (ss != self.strip_sig) {
                try self.drawStrip(arena, snap);
                self.strip_sig = ss;
            }
        }
    }

    fn syncDisplayChecked(self: *Daemon, arena: std.mem.Allocator, snap: *const PollState) error{DeviceGone}!void {
        self.syncDisplay(arena, snap) catch |err| switch (err) {
            error.DeviceGone => return error.DeviceGone,
            else => {},
        };
    }

    fn jogMatrix(self: *Daemon, arena: std.mem.Allocator, snap: *const PollState, dir: i8) void {
        if (!snap.mx_online or snap.screen_count == 0) return;
        var pos: usize = 0;
        var i: usize = 0;
        while (i < snap.screen_count) : (i += 1) {
            if (std.mem.eql(u8, snap.screen_buf[i][0..snap.screen_lens[i]], snap.currentScreen())) pos = i;
        }
        const n = snap.screen_count;
        const next = if (dir >= 0) (pos + 1) % n else (pos + n - 1) % n;
        const name = snap.screen_buf[next][0..snap.screen_lens[next]];
        self.mx.showScreen(arena, name) catch return;
        self.noteScreenSet(name);
    }

    fn onKeys(self: *Daemon, arena: std.mem.Allocator, snap: *const PollState, states: [deck.max_keys]bool) void {
        const kc = deck.keyCount(self.model);
        const page_key = pageKeyIndex(self.model);
        for (states[0..kc], 0..) |pressed, i| {
            if (!pressed or self.prev_keys[i]) continue;
            if (page_key != null and i == page_key.?) {
                self.page = switch (self.page) {
                    .matrix, .mirror => .soma,
                    .soma => .mqtt,
                    .mqtt => .matrix,
                };
                std.debug.print("page → {s}\n", .{@tagName(self.page)});
                continue;
            }
            switch (self.page) {
                .matrix, .mirror => {
                    const ka = self.cfg.matrix_keys[i];
                    if (!snap.mx_online) continue;
                    std.debug.print("key {d} → matrix {s}\n", .{ i, ka.screen });
                    self.mx.showScreen(arena, ka.screen) catch continue;
                    self.noteScreenSet(ka.screen);
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
                .mqtt => {
                    const ka = self.cfg.mqtt_keys[i];
                    if (ka.topic.len == 0) continue;
                    std.debug.print("key {d} → mqtt {s} {s}\n", .{ i, ka.topic, ka.payload });
                    self.enqueuePublish(ka.topic, ka.payload);
                },
            }
        }
        self.prev_keys = states;
    }

    fn onDialDeltas(self: *Daemon, arena: std.mem.Allocator, snap: *const PollState, deltas: [deck.max_dials]i8) void {
        const dc = deck.dialCount(self.model);
        for (deltas[0..dc], 0..) |delta, i| {
            if (delta == 0) continue;
            switch (i) {
                0 => self.somaCmd(arena, if (delta > 0) "vol +5" else "vol -5"),
                1 => self.somaCmd(arena, if (delta > 0) "surf-next" else "surf-prev"),
                2 => self.jogMatrix(arena, snap, if (delta > 0) 1 else -1),
                3 => {
                    if (self.page == .mqtt and self.cfg.mqtt_intensity_topic.len > 0) {
                        const step: i16 = @as(i16, delta) * 5;
                        const next = std.math.clamp(@as(i16, self.mqtt_intensity) + step, @as(i16, self.cfg.mqtt_intensity_min), @as(i16, self.cfg.mqtt_intensity_max));
                        self.mqtt_intensity = @intCast(next);
                        var buf: [8]u8 = undefined;
                        const payload = std.fmt.bufPrint(&buf, "{d}", .{self.mqtt_intensity}) catch continue;
                        self.enqueuePublish(self.cfg.mqtt_intensity_topic, payload);
                    } else {
                        const step: i16 = @as(i16, delta) * 5;
                        const next = std.math.clamp(@as(i16, self.brightness) + step, 0, 100);
                        self.brightness = @intCast(next);
                        deck.setBrightness(self.model, self.dev, self.brightness) catch {};
                    }
                },
                else => unreachable,
            }
        }
    }

    fn onDialPresses(self: *Daemon, arena: std.mem.Allocator, snap: *const PollState, presses: [deck.max_dials]bool) void {
        const dc = deck.dialCount(self.model);
        for (presses[0..dc], 0..) |pressed, i| {
            if (!pressed or self.prev_dials[i]) continue;
            switch (i) {
                0 => self.somaCmd(arena, "mute"),
                1 => self.somaCmd(arena, "toggle"),
                2 => {
                    if (!snap.mx_online) break;
                    self.mx.setAutoAdvance(arena, !snap.auto_advance) catch break;
                    self.noteAutoAdvanceSet(!snap.auto_advance);
                },
                3 => {
                    self.page = switch (self.page) {
                        .matrix => .soma,
                        .soma => .mirror,
                        .mirror => .mqtt,
                        .mqtt => .matrix,
                    };
                    std.debug.print("page → {s}\n", .{@tagName(self.page)});
                },
                else => unreachable,
            }
        }
        self.prev_dials = presses;
    }
};

pub fn run(io: std.Io, dev: *hid.Device, model: deck.Model, cfg: *const config.Config) !void {
    const base_url = cfg.matrix_url;
    var http = std.http.Client{ .allocator = std.heap.page_allocator, .io = io };
    defer http.deinit();

    const feed = try std.heap.page_allocator.create(ws.FrameFeed);
    feed.* = ws.FrameFeed.init(io, base_url);
    const feed_thread = try std.Thread.spawn(.{}, ws.FrameFeed.run, .{feed});
    feed_thread.detach();

    var d: Daemon = .{
        .dev = dev,
        .model = model,
        .io = io,
        .mx = .{ .http = &http, .base = base_url },
        .sm = soma.Client.init(io),
        .mq = .{ .io = io, .host = cfg.mqtt_host, .port = cfg.mqtt_port, .username = cfg.mqtt_user, .password = cfg.mqtt_pass },
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
    try deck.reset(model, dev);
    try deck.setBrightness(model, dev, d.brightness);

    const poll_thread = try std.Thread.spawn(.{}, pollLoop, .{ io, &d });
    poll_thread.detach();

    const pub_thread = try std.Thread.spawn(.{}, pubLoop, .{ io, &d });
    pub_thread.detach();

    var cycle = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer cycle.deinit();

    while (true) {
        eventLoop(io, dev, model, &d, &cycle) catch |err| switch (err) {
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

fn eventLoop(io: std.Io, dev: *hid.Device, model: deck.Model, d: *Daemon, cycle: *std.heap.ArenaAllocator) !void {
    const arena = cycle.allocator();

    _ = cycle.reset(.retain_capacity);
    {
        var waited_ms: usize = 0;
        while (d.generation() == 0 and waited_ms < 1000) : (waited_ms += 10) {
            std.Io.sleep(io, .fromMilliseconds(10), .awake) catch break;
        }
        const snap = d.snapshot();
        try d.syncDisplay(arena, &snap);
        std.debug.print("daemon running ({s}, matrix: {s} current: {s} | soma: {s} playing: {})\n", .{
            @tagName(model), d.mx.base, snap.currentScreen(), if (snap.sm_online) "online" else "offline", snap.sm_playing,
        });
    }

    var buf: [256]u8 = undefined;
    var seen_gen: u64 = d.generation();
    while (true) {
        defer _ = cycle.reset(.retain_capacity);
        if (try dev.pollReport(&buf, 250)) |len| {
            if (deck.parseReport(model, buf[0..len])) |report| {
                const snap = d.snapshot();
                switch (report) {
                    .keys => |states| d.onKeys(arena, &snap, states),
                    .dial_deltas => |deltas| d.onDialDeltas(arena, &snap, deltas),
                    .dial_presses => |presses| d.onDialPresses(arena, &snap, presses),
                    .touch_swipe => |s| {
                        if (deck.hasStrip(model)) {
                            const dx = @as(i32, s.to.x) - @as(i32, s.from.x);
                            if (@abs(dx) > 60) d.jogMatrix(arena, &snap, if (dx > 0) 1 else -1);
                        }
                    },
                    else => {},
                }
                try d.syncDisplayChecked(arena, &snap);
            }
        }
        const now = std.Io.Clock.awake.now(io).toMilliseconds();
        if (d.page == .mirror and deck.hasStrip(model) and now - d.last_mirror_ms >= 250) {
            const c = d.feed.frameCounter();
            if (c != d.mirror_drawn_counter) {
                d.mirror_drawn_counter = c;
                d.last_mirror_ms = now;
                const snap = d.snapshot();
                d.drawStrip(arena, &snap) catch |err| switch (err) {
                    error.DeviceGone => return error.DeviceGone,
                    else => {},
                };
                d.strip_sig = d.stripSignature(&snap);
            }
        }
        const gen = d.generation();
        if (gen != seen_gen) {
            seen_gen = gen;
            const snap = d.snapshot();
            try d.syncDisplayChecked(arena, &snap);
        }
    }
}

fn pollLoop(io: std.Io, d: *Daemon) void {
    var http = std.http.Client{ .allocator = std.heap.page_allocator, .io = io };
    defer http.deinit();
    const mx: matrix.Client = .{ .http = &http, .base = d.cfg.matrix_url };
    const sm = soma.Client.init(io);

    var arena_inst = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_inst.deinit();

    while (true) {
        _ = arena_inst.reset(.retain_capacity);
        const arena = arena_inst.allocator();
        const gen_at_start = blk: {
            d.state_mtx.lockUncancelable(io);
            defer d.state_mtx.unlock(io);
            break :blk d.cmd_gen;
        };

        var next: PollState = .{};
        if (mx.getConfig(arena)) |cfg| {
            next.mx_online = true;
            Daemon.copyInto(&next.current_buf, &next.current_len, cfg.current);
            next.auto_advance = cfg.auto_advance;
            const names = cfg.allNames(arena) catch &.{};
            next.screen_count = @min(names.len, max_screens);
            for (names[0..next.screen_count], 0..) |name, i| {
                Daemon.copyInto(&next.screen_buf[i], &next.screen_lens[i], name);
            }
        } else |_| {}
        if (sm.status(arena)) |st| {
            next.sm_online = true;
            next.sm_playing = st.playing or st.connecting;
            next.sm_volume = st.volume;
            Daemon.copyInto(&next.sm_channel_buf, &next.sm_channel_len, st.channel);
            Daemon.copyInto(&next.sm_id_buf, &next.sm_id_len, st.channel_id);
            Daemon.copyInto(&next.sm_track_buf, &next.sm_track_len, st.track);
        } else |_| {}

        d.swapState(next, gen_at_start);
        std.Io.sleep(io, .fromMilliseconds(2000), .awake) catch {};
    }
}

fn pubLoop(io: std.Io, d: *Daemon) void {
    while (true) {
        while (d.dequeuePublish()) |item| {
            d.mq.publish(item.topic(), item.payload()) catch |err| {
                std.debug.print("mqtt: publish failed: {s}\n", .{@errorName(err)});
                d.notePublished(false, "");
                continue;
            };
            var line: [128]u8 = undefined;
            const s = std.fmt.bufPrint(&line, "{s} = {s}", .{ item.topic(), item.payload() }) catch "";
            d.notePublished(true, s);
        }
        std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
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
    d.keys_sig = 0;
    d.strip_sig = 0;
    d.prev_keys = .{false} ** deck.max_keys;
    d.prev_dials = .{false} ** deck.max_dials;
    try deck.setBrightness(model, dev, d.brightness);
}
