//! Stream Deck Plus protocol: constants, feature commands, image upload,
//! input event parsing.
const std = @import("std");
const hid = @import("hid.zig");

pub const key_count = 8;
pub const dial_count = 4;
pub const key_px = 120; // keys are 120x120 JPEG
pub const strip_w = 800; // touch strip 800x100 JPEG
pub const strip_h = 100;
pub const feature_len = 32;
pub const report_len = 1024;

pub const Point = struct { x: u16, y: u16 };

/// Parsed input report. Keys and dial presses arrive as full-state
/// snapshots (diff against previous state to detect changes); rotations
/// and touch events are one-shot.
///
/// Wire layout (256-byte report, verified on hardware via `deckd dump`):
///   [0] 0x01 report id, [1] class, [2] payload len, [3] 0x00
///   class 0x00 keys:  [4..12]  u8 state per key (1 = pressed)
///   class 0x03 dials: [4] 0x00 → [5..9] u8 press state per dial
///                     [4] 0x01 → [5..9] i8 rotation delta per dial
///   class 0x02 touch: [4] 0x01 tap        x u16le [6]  y u16le [8]
///                     [4] 0x02 long press (same layout as tap)
///                     [4] 0x03 swipe      x0,y0,x1,y1 u16le at 6,8,10,12
pub const Report = union(enum) {
    keys: [key_count]bool,
    dial_presses: [dial_count]bool,
    dial_deltas: [dial_count]i8,
    touch_tap: Point,
    touch_long_press: Point,
    touch_swipe: struct { from: Point, to: Point },
};

fn u16le(report: []const u8, off: usize) u16 {
    return @as(u16, report[off]) | (@as(u16, report[off + 1]) << 8);
}

pub fn parseReport(report: []const u8) ?Report {
    if (report.len < 10 or report[0] != 0x01) return null;
    switch (report[1]) {
        0x00 => {
            var states: [key_count]bool = undefined;
            for (&states, report[4 .. 4 + key_count]) |*s, b| s.* = b != 0;
            return .{ .keys = states };
        },
        0x03 => switch (report[4]) {
            0x00 => {
                var presses: [dial_count]bool = undefined;
                for (&presses, report[5 .. 5 + dial_count]) |*p, b| p.* = b != 0;
                return .{ .dial_presses = presses };
            },
            0x01 => {
                var deltas: [dial_count]i8 = undefined;
                for (&deltas, report[5 .. 5 + dial_count]) |*d, b| d.* = @bitCast(b);
                return .{ .dial_deltas = deltas };
            },
            else => return null,
        },
        0x02 => switch (report[4]) {
            0x01 => return .{ .touch_tap = .{ .x = u16le(report, 6), .y = u16le(report, 8) } },
            0x02 => return .{ .touch_long_press = .{ .x = u16le(report, 6), .y = u16le(report, 8) } },
            0x03 => return .{ .touch_swipe = .{
                .from = .{ .x = u16le(report, 6), .y = u16le(report, 8) },
                .to = .{ .x = u16le(report, 10), .y = u16le(report, 12) },
            } },
            else => return null,
        },
        else => return null,
    }
}

// Real bytes captured from hardware with `deckd dump`.
fn testReport(comptime hex: []const u8) [256]u8 {
    var report = std.mem.zeroes([256]u8);
    var i: usize = 0;
    var val: u8 = 0;
    var high: bool = true;
    for (hex) |c| {
        const digit: u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            else => continue,
        };
        if (high) val = digit << 4 else report[i] = val | digit;
        if (!high) i += 1;
        high = !high;
    }
    return report;
}

test "parse key state snapshot" {
    const r = parseReport(&testReport("01 00 08 00 00 01 00 00 00 00 00 00")).?;
    try std.testing.expectEqual([8]bool{ false, true, false, false, false, false, false, false }, r.keys);
}

test "parse dial press snapshot" {
    const r = parseReport(&testReport("01 03 05 00 00 00 01 00 00 00 00")).?;
    try std.testing.expectEqual([4]bool{ false, true, false, false }, r.dial_presses);
}

test "parse dial rotation deltas" {
    const r = parseReport(&testReport("01 03 05 00 01 fe 00 00 02 00")).?;
    try std.testing.expectEqual([4]i8{ -2, 0, 0, 2 }, r.dial_deltas);
}

test "parse tap" {
    const r = parseReport(&testReport("01 02 0e 00 01 01 09 03 4a 00 00")).?;
    try std.testing.expectEqual(Point{ .x = 777, .y = 74 }, r.touch_tap);
}

test "parse swipe" {
    const r = parseReport(&testReport("01 02 0e 00 03 00 06 00 27 00 d6 00 2d 00")).?;
    try std.testing.expectEqual(Point{ .x = 6, .y = 39 }, r.touch_swipe.from);
    try std.testing.expectEqual(Point{ .x = 214, .y = 45 }, r.touch_swipe.to);
}

// Feature report commands (report 0x03) and queries (0x05/0x06).
pub fn reset(dev: *hid.Device) !void {
    try dev.setFeature(&.{ 0x03, 0x02 });
}

pub fn setBrightness(dev: *hid.Device, percent: u8) !void {
    try dev.setFeature(&.{ 0x03, 0x08, @min(percent, 100) });
}

pub fn firmwareVersion(dev: *hid.Device, buf: []u8) ![]const u8 {
    try dev.getFeature(0x05, buf);
    // ASCII string starting at offset 6.
    return std.mem.sliceTo(buf[6..], 0);
}

pub fn serialNumber(dev: *hid.Device, buf: []u8) ![]const u8 {
    try dev.getFeature(0x06, buf);
    // ASCII string starting at offset 2.
    return std.mem.sliceTo(buf[2..], 0);
}

/// Upload a JPEG to a key. Image must already be 120x120 and correctly
/// oriented for the panel.
pub fn setKeyImage(dev: *hid.Device, key: u8, jpeg: []const u8) !void {
    var page: u16 = 0;
    var off: usize = 0;
    while (off < jpeg.len or page == 0) {
        var report: [report_len]u8 = std.mem.zeroes([report_len]u8);
        const chunk = @min(jpeg.len -| off, report_len - 8);
        const last: u8 = if (off + chunk >= jpeg.len) 1 else 0;
        report[0] = 0x02;
        report[1] = 0x07;
        report[2] = key;
        report[3] = last;
        report[4] = @truncate(chunk);
        report[5] = @truncate(chunk >> 8);
        report[6] = @truncate(page);
        report[7] = @truncate(page >> 8);
        @memcpy(report[8 .. 8 + chunk], jpeg[off .. off + chunk]);
        try dev.writeReport(&report);
        off += chunk;
        page += 1;
        if (last == 1) break;
    }
}

/// Upload a JPEG to a region of the 800x100 touch strip.
pub fn setStripImage(dev: *hid.Device, x: u16, y: u16, w: u16, h: u16, jpeg: []const u8) !void {
    var page: u16 = 0;
    var off: usize = 0;
    while (off < jpeg.len or page == 0) {
        var report: [report_len]u8 = std.mem.zeroes([report_len]u8);
        const chunk = @min(jpeg.len -| off, report_len - 16);
        const last: u8 = if (off + chunk >= jpeg.len) 1 else 0;
        report[0] = 0x02;
        report[1] = 0x0c;
        report[2] = @truncate(x);
        report[3] = @truncate(x >> 8);
        report[4] = @truncate(y);
        report[5] = @truncate(y >> 8);
        report[6] = @truncate(w);
        report[7] = @truncate(w >> 8);
        report[8] = @truncate(h);
        report[9] = @truncate(h >> 8);
        report[10] = last;
        report[11] = @truncate(chunk);
        report[12] = @truncate(chunk >> 8);
        report[13] = @truncate(page);
        report[14] = @truncate(page >> 8);
        @memcpy(report[16 .. 16 + chunk], jpeg[off .. off + chunk]);
        try dev.writeReport(&report);
        off += chunk;
        page += 1;
        if (last == 1) break;
    }
}


