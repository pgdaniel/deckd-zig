//! deckd configuration: ~/.config/deckd/config.json (all fields optional;
//! anything missing falls back to the defaults below).
//!
//! {
//!   "matrix_url": "http://192.168.1.160:8787",
//!   "brightness": 80,
//!   "matrix_keys": [ {"label": "WEATHER", "screen": "weather-cyberpunk", "color": "ff8c00"}, ... ],
//!   "soma_keys":   [ {"label": "GROOVE",  "id": "groovesalad",        "color": "78dc78"}, ... ]
//! }
//!
//! Key lists patch the default maps by index (8 entries max); an entry may
//! set just the fields it wants to change. Soma keys also accept the special
//! ids "viz" and "stop".
const std = @import("std");

pub const KeyAction = struct {
    label: []const u8,
    screen: []const u8,
    r: u8,
    g: u8,
    b: u8,
};

pub const SomaKey = struct {
    label: []const u8,
    id: []const u8, // SomaFM channel id; "viz"/"stop" are special actions
    r: u8,
    g: u8,
    b: u8,
};

pub const Config = struct {
    matrix_url: []const u8 = "http://localhost:8787",
    brightness: u8 = 80,
    /// .ttf to render key/strip text with (e.g. any Nerd Font — PUA icon
    /// codepoints in labels work, labels are UTF-8). null → built-in 8x8
    /// bitmap font.
    font_path: ?[]const u8 = null,
    font_size_key: u16 = 22, // px em height on the 120x120 keys
    font_size_strip: u16 = 30, // px em height for the strip's main line
    matrix_keys: [8]KeyAction = default_matrix_keys,
    soma_keys: [8]SomaKey = default_soma_keys,
};

pub const default_matrix_keys = [8]KeyAction{
    .{ .label = "WEATHER", .screen = "weather-cyberpunk", .r = 255, .g = 140, .b = 0 },
    .{ .label = "HIGH", .screen = "high-temp-cyberpunk", .r = 255, .g = 220, .b = 0 },
    .{ .label = "CLOCK", .screen = "clock-cyberpunk", .r = 0, .g = 220, .b = 255 },
    .{ .label = "AQI", .screen = "aqi-cyberpunk", .r = 0, .g = 220, .b = 100 },
    .{ .label = "HUMID", .screen = "humidity-cyberpunk", .r = 60, .g = 120, .b = 255 },
    .{ .label = "SPECTR", .screen = "spectrum", .r = 255, .g = 0, .b = 220 },
    .{ .label = "SCOPE", .screen = "oscope", .r = 255, .g = 60, .b = 120 },
    .{ .label = "MSG", .screen = "message", .r = 220, .g = 220, .b = 220 },
};

pub const default_soma_keys = [8]SomaKey{
    .{ .label = "GROOVE", .id = "groovesalad", .r = 120, .g = 220, .b = 120 },
    .{ .label = "DRONE", .id = "dronezone", .r = 100, .g = 160, .b = 255 },
    .{ .label = "DEFCON", .id = "defcon", .r = 255, .g = 80, .b = 80 },
    .{ .label = "AGENT", .id = "secretagent", .r = 220, .g = 180, .b = 255 },
    .{ .label = "LUSH", .id = "lush", .r = 255, .g = 160, .b = 200 },
    .{ .label = "DEEP", .id = "deepspaceone", .r = 140, .g = 240, .b = 240 },
    .{ .label = "VIZ", .id = "viz", .r = 255, .g = 220, .b = 100 },
    .{ .label = "STOP", .id = "stop", .r = 255, .g = 60, .b = 60 },
};

const JsonKey = struct {
    label: ?[]const u8 = null,
    screen: ?[]const u8 = null,
    id: ?[]const u8 = null,
    color: ?[]const u8 = null,
};

const JsonConfig = struct {
    matrix_url: ?[]const u8 = null,
    brightness: ?u8 = null,
    font_path: ?[]const u8 = null,
    font_size_key: ?u16 = null,
    font_size_strip: ?u16 = null,
    matrix_keys: []?JsonKey = &.{},
    soma_keys: []?JsonKey = &.{},
};

fn parseColor(hex: []const u8) ?[3]u8 {
    if (hex.len != 6) return null;
    return .{
        std.fmt.parseInt(u8, hex[0..2], 16) catch return null,
        std.fmt.parseInt(u8, hex[2..4], 16) catch return null,
        std.fmt.parseInt(u8, hex[4..6], 16) catch return null,
    };
}

/// Load config from ~/.config/deckd/config.json, merged over the defaults.
/// The arena must live for the whole process (parsed strings point into it).
pub fn load(arena: std.mem.Allocator) Config {
    var cfg: Config = .{};

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

    for (jc.matrix_keys, 0..) |maybe, i| {
        if (i >= 8) break;
        const jk = maybe orelse continue;
        if (jk.label) |v| cfg.matrix_keys[i].label = v;
        if (jk.screen) |v| cfg.matrix_keys[i].screen = v;
        if (jk.color) |v| {
            if (parseColor(v)) |rgb| {
                cfg.matrix_keys[i].r = rgb[0];
                cfg.matrix_keys[i].g = rgb[1];
                cfg.matrix_keys[i].b = rgb[2];
            }
        }
    }
    for (jc.soma_keys, 0..) |maybe, i| {
        if (i >= 8) break;
        const jk = maybe orelse continue;
        if (jk.label) |v| cfg.soma_keys[i].label = v;
        if (jk.id) |v| cfg.soma_keys[i].id = v;
        if (jk.color) |v| {
            if (parseColor(v)) |rgb| {
                cfg.soma_keys[i].r = rgb[0];
                cfg.soma_keys[i].g = rgb[1];
                cfg.soma_keys[i].b = rgb[2];
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
