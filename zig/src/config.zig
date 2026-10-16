//! deckd configuration: ~/.config/deckd/config.json (every field optional).
//!
//! deckd talks to the world over MQTT only. The config says what each key,
//! dial and strip line does in terms of topics; nothing about any particular
//! device on the other end is built in.
//!
//! {
//!   "mqtt_host": "192.168.1.10", "mqtt_port": 1883,
//!   "mqtt_user": "...", "mqtt_pass": "...",
//!   "topic_prefix": "deckd",
//!   "brightness": 80,
//!   "pages": [
//!     { "name": "LIGHTS", "color": "ffc850",
//!       "keys": [
//!         { "label": "LT ON",  "color": "ffc850", "topic": "home/lights/set", "payload": "ON",
//!           "active_topic": "home/lights/state", "active_value": "ON" },
//!         { "label": "{home/temp}C", "icon": "/abs/path.png" }
//!       ],
//!       "strip": [ "{@page}", "lights: {home/lights/state}" ],
//!       "dials": [ null, null, { "turn_topic": "home/dimmer", "turn_mode": "value",
//!                                "turn_min": 0, "turn_max": 100, "turn_step": 5 } ]
//!     }
//!   ],
//!   "dials": [ null, null, null, { "turn_action": "brightness", "press_action": "page" } ]
//! }
//!
//! Keys: pressing publishes `payload` to `topic` (empty topic = nothing
//! published). A key is drawn with a white border while `active_topic`'s last
//! message equals `active_value` (empty value = "ON"/"1"/"true").
//!
//! Templates: `label` and each `strip` line may contain `{some/topic}`, which
//! is replaced by that topic's latest message ("-" until one arrives); deckd
//! subscribes to every topic it finds. `{@page}` is the current page name.
//!
//! Dials: `turn_topic` publishes the rotation (`turn_mode` "delta": signed
//! turn_step*clicks; "value": a running total from turn_start, clamped to
//! turn_min..turn_max); `press_topic`/`press_payload` publish on push.
//! `turn_action` ("brightness") and `press_action` ("page") are built-in
//! alternatives. A page's `dials` entry replaces the global one at the same
//! index while that page is showing; null entries keep the global dial.
//!
//! Backgrounds: a page's `background_topic` names a topic whose message is
//! an image (JPEG/PNG bytes, up to ~250 KB). It is center-cropped across the
//! whole key grid and shown dimmed behind the labels/icons. An empty message
//! clears it. One background topic is supported per config.
//!
//! Key/dial/page lists patch by index. mqtt_host must be a literal IP (or
//! "localhost") — no DNS. icon is an absolute path to a PNG/JPEG/BMP/GIF
//! file (no ~ expansion, same as font_path), drawn instead of the label.
const std = @import("std");
const deck = @import("deck.zig");

pub const max_pages = 8;
pub const max_strip_lines = 3;

pub const Key = struct {
    label: []const u8 = "",
    icon: []const u8 = "",
    r: u8 = 200,
    g: u8 = 200,
    b: u8 = 200,
    topic: []const u8 = "", // empty = key publishes nothing
    payload: []const u8 = "",
    retain: bool = false,
    active_topic: []const u8 = "",
    active_value: []const u8 = "",
};

pub const Action = enum { none, page, brightness };
pub const TurnMode = enum { delta, value };

pub const Dial = struct {
    turn_topic: []const u8 = "",
    turn_mode: TurnMode = .delta,
    turn_step: i32 = 1,
    turn_min: i32 = 0,
    turn_max: i32 = 100,
    turn_start: i32 = 0,
    turn_action: Action = .none,
    press_topic: []const u8 = "",
    press_payload: []const u8 = "",
    press_action: Action = .none,
};

pub const Page = struct {
    name: []const u8 = "",
    /// Topic carrying a JPEG/PNG shown dimmed behind all of this page's keys.
    background_topic: []const u8 = "",
    r: u8 = 240,
    g: u8 = 180,
    b: u8 = 60,
    keys: [deck.max_keys]Key = .{Key{}} ** deck.max_keys,
    strip: [max_strip_lines][]const u8 = .{ "", "", "" },
    /// null = fall through to the global dial at that index.
    dials: [deck.max_dials]?Dial = .{null} ** deck.max_dials,
};

pub const Config = struct {
    brightness: u8 = 80,
    font_path: ?[]const u8 = null,
    font_size_key: u16 = 22,
    font_size_strip: u16 = 30,
    mqtt_host: []const u8 = "",
    mqtt_port: u16 = 1883,
    mqtt_user: []const u8 = "",
    mqtt_pass: []const u8 = "",
    topic_prefix: []const u8 = "deckd",
    pages: [max_pages]Page = .{Page{}} ** max_pages,
    page_count: usize = 1,
    dials: [deck.max_dials]Dial = .{Dial{}} ** deck.max_dials,
};

const JsonKey = struct {
    label: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    color: ?[]const u8 = null,
    topic: ?[]const u8 = null,
    payload: ?[]const u8 = null,
    retain: ?bool = null,
    active_topic: ?[]const u8 = null,
    active_value: ?[]const u8 = null,
};

const JsonDial = struct {
    turn_topic: ?[]const u8 = null,
    turn_mode: ?TurnMode = null,
    turn_step: ?i32 = null,
    turn_min: ?i32 = null,
    turn_max: ?i32 = null,
    turn_start: ?i32 = null,
    turn_action: ?Action = null,
    press_topic: ?[]const u8 = null,
    press_payload: ?[]const u8 = null,
    press_action: ?Action = null,

    fn apply(self: JsonDial, base: Dial) Dial {
        var d = base;
        if (self.turn_topic) |v| d.turn_topic = v;
        if (self.turn_mode) |v| d.turn_mode = v;
        if (self.turn_step) |v| d.turn_step = v;
        if (self.turn_min) |v| d.turn_min = v;
        if (self.turn_max) |v| d.turn_max = v;
        if (self.turn_start) |v| d.turn_start = v;
        if (self.turn_action) |v| d.turn_action = v;
        if (self.press_topic) |v| d.press_topic = v;
        if (self.press_payload) |v| d.press_payload = v;
        if (self.press_action) |v| d.press_action = v;
        return d;
    }
};

const JsonPage = struct {
    name: ?[]const u8 = null,
    background_topic: ?[]const u8 = null,
    color: ?[]const u8 = null,
    keys: []?JsonKey = &.{},
    strip: []const []const u8 = &.{},
    dials: []?JsonDial = &.{},
};

const JsonConfig = struct {
    brightness: ?u8 = null,
    font_path: ?[]const u8 = null,
    font_size_key: ?u16 = null,
    font_size_strip: ?u16 = null,
    mqtt_host: ?[]const u8 = null,
    mqtt_port: ?u16 = null,
    mqtt_user: ?[]const u8 = null,
    mqtt_pass: ?[]const u8 = null,
    topic_prefix: ?[]const u8 = null,
    pages: []?JsonPage = &.{},
    dials: []?JsonDial = &.{},
};

fn parseColor(hex: []const u8) ?[3]u8 {
    if (hex.len != 6) return null;
    return .{
        std.fmt.parseInt(u8, hex[0..2], 16) catch return null,
        std.fmt.parseInt(u8, hex[2..4], 16) catch return null,
        std.fmt.parseInt(u8, hex[4..6], 16) catch return null,
    };
}

fn defaults() Config {
    var cfg: Config = .{};
    cfg.pages[0].name = "DECK";
    // Out of the box the only wired-up controls are the built-ins: dial 4
    // turns the backlight and pushes through the pages.
    cfg.dials[3] = .{ .turn_action = .brightness, .press_action = .page, .turn_step = 5 };
    return cfg;
}

fn applyKey(k: *Key, jk: JsonKey) void {
    if (jk.label) |v| k.label = v;
    if (jk.icon) |v| k.icon = v;
    if (jk.topic) |v| k.topic = v;
    if (jk.payload) |v| k.payload = v;
    if (jk.retain) |v| k.retain = v;
    if (jk.active_topic) |v| k.active_topic = v;
    if (jk.active_value) |v| k.active_value = v;
    if (jk.color) |v| {
        if (parseColor(v)) |rgb| {
            k.r = rgb[0];
            k.g = rgb[1];
            k.b = rgb[2];
        }
    }
}

/// Load config from ~/.config/deckd/config.json over the defaults. The
/// arena must live for the whole process (parsed strings point into it).
pub fn load(arena: std.mem.Allocator, model: deck.Model) Config {
    _ = model; // key slots beyond the device's count are simply never drawn
    var cfg = defaults();

    const home = std.c.getenv("HOME") orelse return cfg;
    const path = std.fmt.allocPrint(arena, "{s}/.config/deckd/config.json", .{std.mem.sliceTo(home, 0)}) catch return cfg;
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return cfg;
    var text_buf: [64 * 1024]u8 = undefined;
    const n = std.posix.read(fd, &text_buf) catch 0;
    _ = std.os.linux.close(fd);
    const text = arena.dupe(u8, text_buf[0..n]) catch return cfg;

    const parsed = std.json.parseFromSlice(JsonConfig, arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        std.debug.print("config: {s} ignored: {s}\n", .{ path, @errorName(err) });
        return cfg;
    };
    const jc = parsed.value;

    if (jc.brightness) |b| cfg.brightness = @min(b, 100);
    if (jc.font_path) |p| cfg.font_path = p;
    if (jc.font_size_key) |s| cfg.font_size_key = s;
    if (jc.font_size_strip) |s| cfg.font_size_strip = s;
    if (jc.mqtt_host) |h| cfg.mqtt_host = h;
    if (jc.mqtt_port) |p| cfg.mqtt_port = p;
    if (jc.mqtt_user) |u| cfg.mqtt_user = u;
    if (jc.mqtt_pass) |p| cfg.mqtt_pass = p;
    if (jc.topic_prefix) |p| cfg.topic_prefix = p;

    for (jc.dials, 0..) |maybe, i| {
        if (i >= deck.max_dials) break;
        if (maybe) |jd| cfg.dials[i] = jd.apply(cfg.dials[i]);
    }

    if (jc.pages.len > 0) {
        cfg.page_count = @min(jc.pages.len, max_pages);
        for (jc.pages[0..cfg.page_count], 0..) |maybe, pi| {
            const jp = maybe orelse JsonPage{};
            const page = &cfg.pages[pi];
            page.* = .{};
            page.name = jp.name orelse (std.fmt.allocPrint(arena, "PAGE {d}", .{pi + 1}) catch "PAGE");
            if (jp.background_topic) |t| page.background_topic = t;
            if (jp.color) |v| {
                if (parseColor(v)) |rgb| {
                    page.r = rgb[0];
                    page.g = rgb[1];
                    page.b = rgb[2];
                }
            }
            for (jp.keys, 0..) |mk, ki| {
                if (ki >= deck.max_keys) break;
                if (mk) |jk| applyKey(&page.keys[ki], jk);
            }
            for (jp.strip, 0..) |line, li| {
                if (li >= max_strip_lines) break;
                page.strip[li] = line;
            }
            for (jp.dials, 0..) |md, di| {
                if (di >= deck.max_dials) break;
                if (md) |jd| page.dials[di] = jd.apply(.{});
            }
        }
    }
    std.debug.print("config: loaded {s} ({d} pages)\n", .{ path, cfg.page_count });
    return cfg;
}

test "parseColor" {
    try std.testing.expectEqual([3]u8{ 255, 140, 0 }, parseColor("ff8c00").?);
    try std.testing.expect(parseColor("xyz") == null);
    try std.testing.expect(parseColor("ff8c0") == null);
}

test "JsonDial.apply patches only what is set" {
    const base: Dial = .{ .turn_step = 5, .press_action = .page };
    const d = (JsonDial{ .turn_topic = "x", .turn_mode = .value }).apply(base);
    try std.testing.expectEqualStrings("x", d.turn_topic);
    try std.testing.expectEqual(TurnMode.value, d.turn_mode);
    try std.testing.expectEqual(@as(i32, 5), d.turn_step);
    try std.testing.expectEqual(Action.page, d.press_action);
}
