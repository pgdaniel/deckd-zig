//! deckd configuration: ~/.config/deckd/config.json (all fields optional;
//! anything missing falls back to the defaults below).
//!
//! {
//!   "matrix_url": "http://192.168.1.109:8787",
//!   "brightness": 80,
//!   "matrix_keys": [ {"label": "WEATHER", "screen": "weather-cyberpunk", "color": "ff8c00", "icon": "/home/me/icons/weather.png"}, ... ],
//!   "soma_keys":   [ {"label": "GROOVE",  "id": "groovesalad",        "color": "78dc78"}, ... ],
//!   "mqtt_host": "192.168.1.10", "mqtt_port": 1883,
//!   "mqtt_user": "...", "mqtt_pass": "...",
//!   "mqtt_keys":   [ {"label": "LT ON",   "topic": "home/lights/set", "payload": "ON", "color": "ffc850"}, ... ]
//! }
//!
//! Key lists patch the default maps by index (up to the device's key count);
//! an entry may set just the fields it wants to change. Soma keys also accept
//! the special ids "viz" and "stop". MQTT keys publish payload to topic on
//! press; an empty topic disables the key. mqtt_host must be a literal IP (or
//! "localhost") — no DNS. icon is an absolute path to a PNG/JPEG/BMP/GIF
//! file (same convention as font_path — no ~ expansion): when set, it's
//! drawn on the key (scaled to fit, alpha-blended, centered) instead of the
//! label text.
const std = @import("std");
const deck = @import("deck.zig");

pub const KeyAction = struct {
    label: []const u8,
    screen: []const u8,
    r: u8,
    g: u8,
    b: u8,
    icon: []const u8 = "", // path to an image file; set = draw it instead of label
};

pub const SomaKey = struct {
    label: []const u8,
    id: []const u8, // SomaFM channel id; "viz"/"stop" are special actions
    r: u8,
    g: u8,
    b: u8,
    icon: []const u8 = "",
};

pub const MqttKey = struct {
    label: []const u8,
    topic: []const u8, // empty = key does nothing
    payload: []const u8,
    r: u8,
    g: u8,
    b: u8,
    icon: []const u8 = "",
};

pub const Config = struct {
    matrix_url: []const u8 = "http://localhost:8787",
    brightness: u8 = 80,
    font_path: ?[]const u8 = null,
    font_size_key: u16 = 22,
    font_size_strip: u16 = 30,
    matrix_keys: [deck.max_keys]KeyAction = undefined,
    soma_keys: [deck.max_keys]SomaKey = undefined,
    mqtt_host: []const u8 = "",
    mqtt_port: u16 = 1883,
    mqtt_user: []const u8 = "",
    mqtt_pass: []const u8 = "",
    mqtt_keys: [deck.max_keys]MqttKey = undefined,
    mqtt_intensity_topic: []const u8 = "",
    mqtt_intensity_min: u8 = 0,
    mqtt_intensity_max: u8 = 100,
};

pub const default_matrix_keys_plus = [8]KeyAction{
    .{ .label = "WEATHER", .screen = "weather-cyberpunk", .r = 255, .g = 140, .b = 0 },
    .{ .label = "HIGH", .screen = "high-temp-cyberpunk", .r = 255, .g = 220, .b = 0 },
    .{ .label = "CLOCK", .screen = "clock-cyberpunk", .r = 0, .g = 220, .b = 255 },
    .{ .label = "AQI", .screen = "aqi-cyberpunk", .r = 0, .g = 220, .b = 100 },
    .{ .label = "HUMID", .screen = "humidity-cyberpunk", .r = 60, .g = 120, .b = 255 },
    .{ .label = "SPECTR", .screen = "spectrum", .r = 255, .g = 0, .b = 220 },
    .{ .label = "SCOPE", .screen = "oscope", .r = 255, .g = 60, .b = 120 },
    .{ .label = "MSG", .screen = "message", .r = 220, .g = 220, .b = 220 },
};

pub const default_matrix_keys_mini = [6]KeyAction{
    .{ .label = "WEATHER", .screen = "weather-cyberpunk", .r = 255, .g = 140, .b = 0 },
    .{ .label = "HIGH", .screen = "high-temp-cyberpunk", .r = 255, .g = 220, .b = 0 },
    .{ .label = "CLOCK", .screen = "clock-cyberpunk", .r = 0, .g = 220, .b = 255 },
    .{ .label = "AQI", .screen = "aqi-cyberpunk", .r = 0, .g = 220, .b = 100 },
    .{ .label = "HUMID", .screen = "humidity-cyberpunk", .r = 60, .g = 120, .b = 255 },
    .{ .label = "SPECTR", .screen = "spectrum", .r = 255, .g = 0, .b = 220 },
};

pub const default_soma_keys_plus = [8]SomaKey{
    .{ .label = "GROOVE", .id = "groovesalad", .r = 120, .g = 220, .b = 120 },
    .{ .label = "DRONE", .id = "dronezone", .r = 100, .g = 160, .b = 255 },
    .{ .label = "DEFCON", .id = "defcon", .r = 255, .g = 80, .b = 80 },
    .{ .label = "AGENT", .id = "secretagent", .r = 220, .g = 180, .b = 255 },
    .{ .label = "LUSH", .id = "lush", .r = 255, .g = 160, .b = 200 },
    .{ .label = "DEEP", .id = "deepspaceone", .r = 140, .g = 240, .b = 240 },
    .{ .label = "VIZ", .id = "viz", .r = 255, .g = 220, .b = 100 },
    .{ .label = "STOP", .id = "stop", .r = 255, .g = 60, .b = 60 },
};

pub const default_soma_keys_mini = [6]SomaKey{
    .{ .label = "GROOVE", .id = "groovesalad", .r = 120, .g = 220, .b = 120 },
    .{ .label = "DRONE", .id = "dronezone", .r = 100, .g = 160, .b = 255 },
    .{ .label = "DEFCON", .id = "defcon", .r = 255, .g = 80, .b = 80 },
    .{ .label = "AGENT", .id = "secretagent", .r = 220, .g = 180, .b = 255 },
    .{ .label = "LUSH", .id = "lush", .r = 255, .g = 160, .b = 200 },
    .{ .label = "DEEP", .id = "deepspaceone", .r = 140, .g = 240, .b = 240 },
};

pub const default_mqtt_keys_plus = [8]MqttKey{
    .{ .label = "LT ON", .topic = "home/lights/set", .payload = "ON", .r = 255, .g = 200, .b = 80 },
    .{ .label = "LT OFF", .topic = "home/lights/set", .payload = "OFF", .r = 130, .g = 100, .b = 40 },
    .{ .label = "", .topic = "", .payload = "", .r = 0, .g = 0, .b = 0 },
    .{ .label = "", .topic = "", .payload = "", .r = 0, .g = 0, .b = 0 },
    .{ .label = "", .topic = "", .payload = "", .r = 0, .g = 0, .b = 0 },
    .{ .label = "", .topic = "", .payload = "", .r = 0, .g = 0, .b = 0 },
    .{ .label = "", .topic = "", .payload = "", .r = 0, .g = 0, .b = 0 },
    .{ .label = "", .topic = "", .payload = "", .r = 0, .g = 0, .b = 0 },
};

pub const default_mqtt_keys_mini = [6]MqttKey{
    .{ .label = "LT ON", .topic = "home/lights/set", .payload = "ON", .r = 255, .g = 200, .b = 80 },
    .{ .label = "LT OFF", .topic = "home/lights/set", .payload = "OFF", .r = 130, .g = 100, .b = 40 },
    .{ .label = "", .topic = "", .payload = "", .r = 0, .g = 0, .b = 0 },
    .{ .label = "", .topic = "", .payload = "", .r = 0, .g = 0, .b = 0 },
    .{ .label = "", .topic = "", .payload = "", .r = 0, .g = 0, .b = 0 },
    .{ .label = "", .topic = "", .payload = "", .r = 0, .g = 0, .b = 0 },
};

const JsonKey = struct {
    label: ?[]const u8 = null,
    screen: ?[]const u8 = null,
    id: ?[]const u8 = null,
    topic: ?[]const u8 = null,
    payload: ?[]const u8 = null,
    color: ?[]const u8 = null,
    icon: ?[]const u8 = null,
};

const JsonConfig = struct {
    matrix_url: ?[]const u8 = null,
    brightness: ?u8 = null,
    font_path: ?[]const u8 = null,
    font_size_key: ?u16 = null,
    font_size_strip: ?u16 = null,
    matrix_keys: []?JsonKey = &.{},
    soma_keys: []?JsonKey = &.{},
    mqtt_host: ?[]const u8 = null,
    mqtt_port: ?u16 = null,
    mqtt_user: ?[]const u8 = null,
    mqtt_pass: ?[]const u8 = null,
    mqtt_keys: []?JsonKey = &.{},
    mqtt_intensity_topic: ?[]const u8 = null,
    mqtt_intensity_min: ?u8 = null,
    mqtt_intensity_max: ?u8 = null,
};

fn parseColor(hex: []const u8) ?[3]u8 {
    if (hex.len != 6) return null;
    return .{
        std.fmt.parseInt(u8, hex[0..2], 16) catch return null,
        std.fmt.parseInt(u8, hex[2..4], 16) catch return null,
        std.fmt.parseInt(u8, hex[4..6], 16) catch return null,
    };
}

/// Load config from ~/.config/deckd/config.json, merged over the defaults
/// for the given device model. The arena must live for the whole process
/// (parsed strings point into it).
pub fn load(arena: std.mem.Allocator, model: deck.Model) Config {
    var cfg: Config = .{};

    const kc = deck.keyCount(model);
    switch (model) {
        .plus => {
            cfg.matrix_keys = default_matrix_keys_plus;
            cfg.soma_keys = default_soma_keys_plus;
            cfg.mqtt_keys = default_mqtt_keys_plus;
        },
        .mini => {
            cfg.matrix_keys = undefined;
            cfg.soma_keys = undefined;
            cfg.mqtt_keys = undefined;
            for (&cfg.matrix_keys, 0..) |*k, i| k.* = if (i < 6) default_matrix_keys_mini[i] else .{ .label = "", .screen = "", .r = 0, .g = 0, .b = 0 };
            for (&cfg.soma_keys, 0..) |*k, i| k.* = if (i < 6) default_soma_keys_mini[i] else .{ .label = "", .id = "", .r = 0, .g = 0, .b = 0 };
            for (&cfg.mqtt_keys, 0..) |*k, i| k.* = if (i < 6) default_mqtt_keys_mini[i] else .{ .label = "", .topic = "", .payload = "", .r = 0, .g = 0, .b = 0 };
        },
    }

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

    if (jc.matrix_url) |u| cfg.matrix_url = u;
    if (jc.brightness) |b| cfg.brightness = @min(b, 100);
    if (jc.font_path) |p| cfg.font_path = p;
    if (jc.font_size_key) |s| cfg.font_size_key = s;
    if (jc.font_size_strip) |s| cfg.font_size_strip = s;
    if (jc.mqtt_host) |h| cfg.mqtt_host = h;
    if (jc.mqtt_port) |p| cfg.mqtt_port = p;
    if (jc.mqtt_user) |u| cfg.mqtt_user = u;
    if (jc.mqtt_pass) |p| cfg.mqtt_pass = p;
    if (jc.mqtt_intensity_topic) |t| cfg.mqtt_intensity_topic = t;
    if (jc.mqtt_intensity_min) |v| cfg.mqtt_intensity_min = v;
    if (jc.mqtt_intensity_max) |v| cfg.mqtt_intensity_max = v;

    for (jc.matrix_keys, 0..) |maybe, i| {
        if (i >= kc) break;
        const jk = maybe orelse continue;
        if (jk.label) |v| cfg.matrix_keys[i].label = v;
        if (jk.screen) |v| cfg.matrix_keys[i].screen = v;
        if (jk.icon) |v| cfg.matrix_keys[i].icon = v;
        if (jk.color) |v| {
            if (parseColor(v)) |rgb| {
                cfg.matrix_keys[i].r = rgb[0];
                cfg.matrix_keys[i].g = rgb[1];
                cfg.matrix_keys[i].b = rgb[2];
            }
        }
    }
    for (jc.soma_keys, 0..) |maybe, i| {
        if (i >= kc) break;
        const jk = maybe orelse continue;
        if (jk.label) |v| cfg.soma_keys[i].label = v;
        if (jk.id) |v| cfg.soma_keys[i].id = v;
        if (jk.icon) |v| cfg.soma_keys[i].icon = v;
        if (jk.color) |v| {
            if (parseColor(v)) |rgb| {
                cfg.soma_keys[i].r = rgb[0];
                cfg.soma_keys[i].g = rgb[1];
                cfg.soma_keys[i].b = rgb[2];
            }
        }
    }
    for (jc.mqtt_keys, 0..) |maybe, i| {
        if (i >= kc) break;
        const jk = maybe orelse continue;
        if (jk.label) |v| cfg.mqtt_keys[i].label = v;
        if (jk.topic) |v| cfg.mqtt_keys[i].topic = v;
        if (jk.payload) |v| cfg.mqtt_keys[i].payload = v;
        if (jk.icon) |v| cfg.mqtt_keys[i].icon = v;
        if (jk.color) |v| {
            if (parseColor(v)) |rgb| {
                cfg.mqtt_keys[i].r = rgb[0];
                cfg.mqtt_keys[i].g = rgb[1];
                cfg.mqtt_keys[i].b = rgb[2];
            }
        }
    }
    std.debug.print("config: loaded {s} (matrix: {s})\n", .{ path, cfg.matrix_url });
    return cfg;
}

test "parseColor" {
    try std.testing.expectEqual([3]u8{ 255, 140, 0 }, parseColor("ff8c00").?);
    try std.testing.expect(parseColor("xyz") == null);
    try std.testing.expect(parseColor("ff8c0") == null);
}
