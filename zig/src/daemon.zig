//! The deckd daemon: Stream Deck Plus → matrix control API + soma player IPC
//! + MQTT broker.
//!
//! Pages (knob 4 push cycles them) swap what the 8 keys and the strip show:
//!   MATRIX — keys direct-select matrix screens (white border = active),
//!            strip shows screen name / auto-advance / soma now-playing.
//!   SOMA   — keys are SomaFM channel presets + VIZ + STOP (border = playing),
//!            strip shows channel / track / volume.
//!   MQTT   — keys publish their configured topic/payload to the broker,
//!            strip shows the broker and the last thing published.
//!
//! Knobs (fixed roles on all pages):
//!   knob 1 rotate: soma volume        push: mute toggle
//!   knob 2 rotate: soma channel surf  push: play/stop toggle
//!   knob 3 rotate: matrix screen jog  push: auto-advance toggle
//!   knob 4 rotate: deck LCD brightness  push: switch page
//! Strip left/right swipe jogs matrix screens too.
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

/// Matrix/soma state, refreshed by the poller thread every 2 s and swapped
/// in under Daemon.state_mtx. The event loop works on snapshots (see
/// Daemon.snapshot), so it always reads a consistent view and never blocks
/// on the network.
const PollState = struct {
    mx_online: bool = false,
    auto_advance: bool = false,
    current_buf: [name_len]u8 = undefined,
    current_len: usize = 0,
    // Jog list: all screens in panel order (the deck can reach disabled
    // screens too — "enabled" only governs the auto-advance rotation).
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

    // Publisher-thread-owned (pubLoop) — carried across swaps, NOT
    // refreshed by polling. "online" just means the last publish worked —
    // optimistic until one fails.
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

/// One queued MQTT publish. Fixed-size so the queue never allocates;
/// oversized topics/payloads are rejected at enqueue time.
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

    // Polled matrix/soma state (see PollState). state_gen is bumped on
    // every swap/write-back so the event loop knows to re-sync the display;
    // cmd_gen guards against the poller clobbering a just-issued command
    // with state that predates it. state_mtx also guards the publish queue
    // below — one lock, always tiny memcpy critical sections.
    state: PollState = .{},
    state_mtx: std.Io.Mutex = .init,
    state_gen: u64 = 0,
    cmd_gen: u64 = 0,

    // MQTT publish queue: event loop enqueues, pubLoop drains. Ring buffer;
    // when full, new presses are dropped (freshest intent is what matters,
    // and a full queue means the broker is down anyway).
    pub_queue: [16]PubItem = undefined,
    pub_head: usize = 0, // next write
    pub_tail: usize = 0, // next read
    pub_dropped: u64 = 0,

    // what's currently on the deck (redraw when the signature changes)
    keys_sig: u64 = 0,
    strip_sig: u64 = 0,

    brightness: u8 = 80,
    prev_keys: [deck.key_count]bool = .{false} ** deck.key_count,
    prev_dials: [deck.dial_count]bool = .{false} ** deck.dial_count,

    /// Consistent copy of the latest polled state. ~2 KB stack copy, lock
    /// held only for the memcpy.
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

    /// Poller thread: swap in freshly-polled state — unless a command was
    /// written back while we were polling (this round's data predates the
    /// command, so dropping it avoids visibly reverting the deck; the next
    /// round, ≤2 s out, converges). The mqtt fields are the publisher
    /// thread's business and are carried across untouched.
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

    /// Event loop, after a successful matrix command: reflect it at once
    /// instead of waiting for the poller's next round.
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

    /// Event loop, after a soma command: quick status refresh written back
    /// under the same protocol. null = soma unreachable.
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

    /// Event loop: queue a publish for pubLoop. Never blocks on the
    /// network — the worst case is a full queue (broker down), in which
    /// case the press is dropped and logged.
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

    /// pubLoop: take the oldest queued publish, or null when empty.
    fn dequeuePublish(self: *Daemon) ?PubItem {
        self.state_mtx.lockUncancelable(self.io);
        defer self.state_mtx.unlock(self.io);
        if (self.pub_tail == self.pub_head) return null;
        const item = self.pub_queue[self.pub_tail];
        self.pub_tail = (self.pub_tail + 1) % self.pub_queue.len;
        return item;
    }

    /// pubLoop: record the outcome of a publish for the strip.
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

    // ----------------------------------------------------------
    // State polling happens on the poller thread (see pollLoop).
    // ----------------------------------------------------------
    fn somaCmd(self: *Daemon, arena: std.mem.Allocator, cmd: []const u8) void {
        _ = self.sm.command(arena, cmd) catch {
            self.noteSomaStatus(null);
            return;
        };
        // The command is applied on soma's next frame (~40ms); give it a
        // moment, then refresh so the strip reflects the change at once.
        // Local socket, so this stays quick even when the matrix is down.
        std.Io.sleep(self.sm.io, .fromMilliseconds(60), .awake) catch {};
        const st = self.sm.status(arena) catch {
            self.noteSomaStatus(null);
            return;
        };
        self.noteSomaStatus(st);
    }

    // ----------------------------------------------------------
    // Drawing
    // ----------------------------------------------------------
    fn activeKeyName(self: *const Daemon, snap: *const PollState) []const u8 {
        return switch (self.page) {
            .matrix, .mirror => if (snap.mx_online) snap.currentScreen() else "",
            .soma => if (snap.sm_online and snap.sm_playing) snap.somaId() else "",
            .mqtt => "", // publish-only: no per-key state to highlight
        };
    }

    fn drawKeys(self: *Daemon, arena: std.mem.Allocator, snap: *const PollState) !void {
        switch (self.page) {
            .matrix, .mirror => for (self.cfg.matrix_keys, 0..) |ka, i| {
                try self.drawKey(arena, @intCast(i), ka.label, ka.r, ka.g, ka.b, std.mem.eql(u8, ka.screen, self.activeKeyName(snap)));
            },
            .soma => for (self.cfg.soma_keys, 0..) |ka, i| {
                try self.drawKey(arena, @intCast(i), ka.label, ka.r, ka.g, ka.b, std.mem.eql(u8, ka.id, self.activeKeyName(snap)));
            },
            .mqtt => for (self.cfg.mqtt_keys, 0..) |ka, i| {
                try self.drawKey(arena, @intCast(i), ka.label, ka.r, ka.g, ka.b, false);
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

    fn drawStrip(self: *Daemon, arena: std.mem.Allocator, snap: *const PollState) !void {
        var img = try image.Image.init(arena, deck.strip_w, deck.strip_h);
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
            .mqtt => {
                if (self.cfg.mqtt_host.len == 0) {
                    self.drawCenteredText(&img, "MQTT NOT CONFIGURED", 50, self.cfg.font_size_strip, 255, 60, 60);
                } else if (!snap.mq_online) {
                    self.drawCenteredText(&img, "MQTT OFFLINE", 28, self.cfg.font_size_strip, 255, 60, 60);
                    self.drawCenteredText(&img, self.cfg.mqtt_host[0..@min(self.cfg.mqtt_host.len, 40)], 60, 16, 140, 140, 160);
                } else {
                    self.drawCenteredText(&img, "MQTT", 28, self.cfg.font_size_strip, 240, 180, 60);
                    self.drawCenteredText(&img, self.cfg.mqtt_host[0..@min(self.cfg.mqtt_host.len, 40)], 60, 16, 140, 140, 160);
                    self.drawCenteredText(&img, snap.lastPub()[0..@min(snap.lastPub().len, 48)], 84, 16, 200, 160, 60);
                }
            },
        }
        var jpeg: std.ArrayList(u8) = .empty;
        try image.encodeJpeg(&img, 90, &jpeg, arena);
        try deck.setStripImage(self.dev, 0, 0, deck.strip_w, deck.strip_h, jpeg.items);
    }

    fn keysSignature(self: *const Daemon, snap: *const PollState) u64 {
        var h = std.hash.Wyhash.init(1);
        // Mirror page shows the same keys as the matrix page.
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
        return h.final();
    }

    fn syncDisplay(self: *Daemon, arena: std.mem.Allocator, snap: *const PollState) !void {
        const ks = self.keysSignature(snap);
        const ss = self.stripSignature(snap);
        if (ks != self.keys_sig) {
            try self.drawKeys(arena, snap);
            self.keys_sig = ks;
        }
        if (ss != self.strip_sig) {
            try self.drawStrip(arena, snap);
            self.strip_sig = ss;
        }
    }

    /// Like syncDisplay, but a dead device propagates so the event loop
    /// can hand off to the reconnect logic instead of spinning on a
    /// corpse fd.
    fn syncDisplayChecked(self: *Daemon, arena: std.mem.Allocator, snap: *const PollState) error{DeviceGone}!void {
        self.syncDisplay(arena, snap) catch |err| switch (err) {
            error.DeviceGone => return error.DeviceGone,
            else => {},
        };
    }

    // ----------------------------------------------------------
    // Actions
    // ----------------------------------------------------------
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
        self.mx.showScreen(arena, name) catch return; // poller marks it offline
        self.noteScreenSet(name);
    }

    fn onKeys(self: *Daemon, arena: std.mem.Allocator, snap: *const PollState, states: [deck.key_count]bool) void {
        for (states, 0..) |pressed, i| {
            if (!pressed or self.prev_keys[i]) continue;
            switch (self.page) {
                .matrix, .mirror => {
                    const ka = self.cfg.matrix_keys[i];
                    // Skip the (blocking) HTTP call entirely when the latest
                    // snapshot already says the matrix is down — the poller
                    // will flip it back when it's reachable again.
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

    fn onDialDeltas(self: *Daemon, arena: std.mem.Allocator, snap: *const PollState, deltas: [deck.dial_count]i8) void {
        for (deltas, 0..) |delta, i| {
            if (delta == 0) continue;
            switch (i) {
                0 => self.somaCmd(arena, if (delta > 0) "vol +5" else "vol -5"),
                1 => self.somaCmd(arena, if (delta > 0) "surf-next" else "surf-prev"),
                2 => self.jogMatrix(arena, snap, if (delta > 0) 1 else -1),
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

    fn onDialPresses(self: *Daemon, arena: std.mem.Allocator, snap: *const PollState, presses: [deck.dial_count]bool) void {
        for (presses, 0..) |pressed, i| {
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
    try deck.setBrightness(dev, d.brightness);

    // State polling runs on its own thread (like the framebuffer feed) so a
    // slow/dead matrix or soma never stalls input handling on the deck.
    const poll_thread = try std.Thread.spawn(.{}, pollLoop, .{ io, &d });
    poll_thread.detach();

    // MQTT publishes run on their own thread too: key presses only enqueue,
    // so a dead broker can't stall the deck either.
    const pub_thread = try std.Thread.spawn(.{}, pubLoop, .{ io, &d });
    pub_thread.detach();

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
    {
        // Give the poller's first round a moment so the first paint usually
        // has real state — but cap it, or a dead matrix would stall startup
        // (and the first input) just like the old in-loop polling did.
        var waited_ms: usize = 0;
        while (d.generation() == 0 and waited_ms < 1000) : (waited_ms += 10) {
            std.Io.sleep(io, .fromMilliseconds(10), .awake) catch break;
        }
        const snap = d.snapshot();
        try d.syncDisplay(arena, &snap);
        std.debug.print("daemon running (matrix: {s} current: {s} | soma: {s} playing: {})\n", .{
            d.mx.base, snap.currentScreen(), if (snap.sm_online) "online" else "offline", snap.sm_playing,
        });
    }

    var buf: [256]u8 = undefined;
    var seen_gen: u64 = d.generation();
    while (true) {
        defer _ = cycle.reset(.retain_capacity);
        if (try dev.pollReport(&buf, 250)) |len| {
            if (deck.parseReport(buf[0..len])) |report| {
                const snap = d.snapshot();
                switch (report) {
                    .keys => |states| d.onKeys(arena, &snap, states),
                    .dial_deltas => |deltas| d.onDialDeltas(arena, &snap, deltas),
                    .dial_presses => |presses| d.onDialPresses(arena, &snap, presses),
                    .touch_swipe => |s| {
                        const dx = @as(i32, s.to.x) - @as(i32, s.from.x);
                        if (@abs(dx) > 60) d.jogMatrix(arena, &snap, if (dx > 0) 1 else -1);
                    },
                    else => {},
                }
                try d.syncDisplayChecked(arena, &snap);
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
                const snap = d.snapshot();
                d.drawStrip(arena, &snap) catch |err| switch (err) {
                    error.DeviceGone => return error.DeviceGone,
                    else => {},
                };
                d.strip_sig = d.stripSignature(&snap);
            }
        }
        // The poller thread swapped in fresh state → re-sync (draws only if
        // what the deck shows actually changed, same as after input).
        const gen = d.generation();
        if (gen != seen_gen) {
            seen_gen = gen;
            const snap = d.snapshot();
            try d.syncDisplayChecked(arena, &snap);
        }
    }
}

/// Poller thread: refresh matrix/soma state every 2 s and swap it into
/// d.state. Never touches the deck; all its network stalls (dead matrix,
/// down soma) stay off the event loop. Owns its own HTTP client/arena so
/// nothing here races the command clients the event loop uses.
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

/// Publisher thread: drain the MQTT publish queue. All broker I/O —
/// including the multi-second TCP connect stall when the broker is down —
/// happens here, never on the event loop. ~100 ms worst-case latency from
/// key press to publish, imperceptible next to the key's own debounce.
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
