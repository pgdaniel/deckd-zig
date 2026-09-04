//! Stream Deck protocol: constants, feature commands, image upload,
//! input event parsing. Supports the Plus (8 keys + strip + dials) and
//! the Mini (6 keys, no strip, no dials).
const std = @import("std");
const hid = @import("hid.zig");
const image = @import("image.zig");

pub const Model = enum { plus, mini };

pub const max_keys = 8;
pub const max_dials = 4;

pub fn keyCount(model: Model) u8 {
    return switch (model) {
        .plus => 8,
        .mini => 6,
    };
}

pub fn dialCount(model: Model) u8 {
    return switch (model) {
        .plus => 4,
        .mini => 0,
    };
}

pub fn keyPx(model: Model) u16 {
    return switch (model) {
        .plus => 120,
        .mini => 80,
    };
}

pub fn hasStrip(model: Model) bool {
    return switch (model) {
        .plus => true,
        .mini => false,
    };
}

pub fn stripW(model: Model) u16 {
    return switch (model) {
        .plus => 800,
        .mini => 0,
    };
}

pub fn stripH(model: Model) u16 {
    return switch (model) {
        .plus => 100,
        .mini => 0,
    };
}

pub fn featureLen(model: Model) u16 {
    return switch (model) {
        .plus => 32,
        .mini => 17,
    };
}

pub fn reportLen(model: Model) u16 {
    return switch (model) {
        .plus => 1024,
        .mini => 1024,
    };
}

pub const Point = struct { x: u16, y: u16 };

/// Parsed input report. Keys arrive as full-state snapshots (diff against
/// previous state to detect changes); rotations and touch events are one-shot.
pub const Report = union(enum) {
    keys: [max_keys]bool,
    dial_presses: [max_dials]bool,
    dial_deltas: [max_dials]i8,
    touch_tap: Point,
    touch_long_press: Point,
    touch_swipe: struct { from: Point, to: Point },
};

fn u16le(report: []const u8, off: usize) u16 {
    return @as(u16, report[off]) | (@as(u16, report[off + 1]) << 8);
}

/// Parse an input report for the given model. Returns null if the report
/// is unrecognized.
pub fn parseReport(model: Model, report: []const u8) ?Report {
    return switch (model) {
        .plus => parseReportPlus(report),
        .mini => parseReportMini(report),
    };
}

/// Plus input: 256-byte report, byte 0 = 0x01, byte 1 = class,
/// byte 2 = payload length, byte 3 = 0x00.
/// class 0x00 keys:  [4..12]  u8 state per key (1 = pressed)
/// class 0x03 dials: [4] 0x00 → [5..9] u8 press state per dial
///                   [4] 0x01 → [5..9] i8 rotation delta per dial
/// class 0x02 touch: [4] 0x01 tap        x u16le [6]  y u16le [8]
///                   [4] 0x02 long press (same layout as tap)
///                   [4] 0x03 swipe      x0,y0,x1,y1 u16le at 6,8,10,12
fn parseReportPlus(report: []const u8) ?Report {
    if (report.len < 10 or report[0] != 0x01) return null;
    switch (report[1]) {
        0x00 => {
            var states: [max_keys]bool = .{false} ** max_keys;
            for (states[0..8], report[4 .. 4 + 8]) |*s, b| s.* = b != 0;
            return .{ .keys = states };
        },
        0x03 => switch (report[4]) {
            0x00 => {
                var presses: [max_dials]bool = .{false} ** max_dials;
                for (presses[0..4], report[5 .. 5 + 4]) |*p, b| p.* = b != 0;
                return .{ .dial_presses = presses };
            },
            0x01 => {
                var deltas: [max_dials]i8 = .{0} ** max_dials;
                for (deltas[0..4], report[5 .. 5 + 4]) |*d, b| d.* = @bitCast(b);
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

/// Mini input: 17-byte report, byte 0 = 0x01, bytes 1-6 = key states.
fn parseReportMini(report: []const u8) ?Report {
    if (report.len < 7 or report[0] != 0x01) return null;
    var states: [max_keys]bool = .{false} ** max_keys;
    for (states[0..6], report[1..7]) |*s, b| s.* = b != 0;
    return .{ .keys = states };
}

// Real bytes captured from hardware with `deckd dump`.
fn testReportPlus(comptime hex: []const u8) [256]u8 {
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

fn testReportMini(comptime hex: []const u8) [17]u8 {
    var report = std.mem.zeroes([17]u8);
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
    const r = parseReportPlus(&testReportPlus("01 00 08 00 00 01 00 00 00 00 00 00")).?;
    try std.testing.expectEqual([8]bool{ false, true, false, false, false, false, false, false }, r.keys[0..8].*);
}

test "parse dial press snapshot" {
    const r = parseReportPlus(&testReportPlus("01 03 05 00 00 00 01 00 00 00 00")).?;
    try std.testing.expectEqual([4]bool{ false, true, false, false }, r.dial_presses[0..4].*);
}

test "parse dial rotation deltas" {
    const r = parseReportPlus(&testReportPlus("01 03 05 00 01 fe 00 00 02 00")).?;
    try std.testing.expectEqual([4]i8{ -2, 0, 0, 2 }, r.dial_deltas[0..4].*);
}

test "parse tap" {
    const r = parseReportPlus(&testReportPlus("01 02 0e 00 01 01 09 03 4a 00 00")).?;
    try std.testing.expectEqual(Point{ .x = 777, .y = 74 }, r.touch_tap);
}

test "parse swipe" {
    const r = parseReportPlus(&testReportPlus("01 02 0e 00 03 00 06 00 27 00 d6 00 2d 00")).?;
    try std.testing.expectEqual(Point{ .x = 6, .y = 39 }, r.touch_swipe.from);
    try std.testing.expectEqual(Point{ .x = 214, .y = 45 }, r.touch_swipe.to);
}

test "parse mini key state" {
    const r = parseReportMini(&testReportMini("01 00 01 00 01 00 01")).?;
    try std.testing.expectEqual([6]bool{ false, true, false, true, false, true }, r.keys[0..6].*);
}

// Feature report commands. Feature report payloads are always padded to
// the device's full report length (Plus: 32, Mini: 17).
pub fn reset(model: Model, dev: *hid.Device) !void {
    var buf: [32]u8 = std.mem.zeroes([32]u8);
    switch (model) {
        .plus => {
            buf[0] = 0x03;
            buf[1] = 0x02;
            try dev.setFeature(buf[0..32]);
        },
        .mini => {
            buf[0] = 0x0B;
            buf[1] = 0x63;
            try dev.setFeature(buf[0..17]);
        },
    }
}

pub fn setBrightness(model: Model, dev: *hid.Device, percent: u8) !void {
    var buf: [32]u8 = std.mem.zeroes([32]u8);
    switch (model) {
        .plus => {
            buf[0] = 0x03;
            buf[1] = 0x08;
            buf[2] = @min(percent, 100);
            try dev.setFeature(buf[0..32]);
        },
        .mini => {
            buf[0] = 0x05;
            buf[1] = 0x55;
            buf[2] = 0xAA;
            buf[3] = 0xD1;
            buf[4] = 0x01;
            buf[5] = @min(percent, 100);
            try dev.setFeature(buf[0..17]);
        },
    }
}

pub fn firmwareVersion(model: Model, dev: *hid.Device, buf: []u8) ![]const u8 {
    switch (model) {
        .plus => {
            try dev.getFeature(0x05, buf[0..featureLen(model)]);
            return std.mem.sliceTo(buf[6..], 0);
        },
        .mini => {
            try dev.getFeature(0x04, buf[0..17]);
            return std.mem.sliceTo(buf[5..], 0);
        },
    }
}

pub fn serialNumber(model: Model, dev: *hid.Device, buf: []u8) ![]const u8 {
    switch (model) {
        .plus => {
            try dev.getFeature(0x06, buf[0..featureLen(model)]);
            return std.mem.sliceTo(buf[2..], 0);
        },
        .mini => {
            // Report 0x03 is 32 bytes on the Mk2 module (per the HID
            // descriptor); ASCII string at offset 5.
            try dev.getFeature(0x03, buf[0..32]);
            return std.mem.sliceTo(buf[5..], 0);
        },
    }
}

/// Upload an image to a key. For Plus: JPEG, 120x120. For Mini: BMP, 80x80,
/// BGR, bottom-up, horizontally mirrored.
pub fn setKeyImage(model: Model, dev: *hid.Device, key: u8, img: *const image.Image) !void {
    switch (model) {
        .plus => try setKeyImagePlus(dev, key, img),
        .mini => try setKeyImageMini(dev, key, img),
    }
}

fn setKeyImagePlus(dev: *hid.Device, key: u8, img: *const image.Image) !void {
    const alloc = std.heap.page_allocator;
    var jpeg: std.ArrayList(u8) = .empty;
    defer jpeg.deinit(alloc);
    try image.encodeJpeg(img, 90, &jpeg, alloc);
    try setKeyImagePlusRaw(dev, key, jpeg.items);
}

fn setKeyImagePlusRaw(dev: *hid.Device, key: u8, jpeg: []const u8) !void {
    var page: u16 = 0;
    var off: usize = 0;
    while (off < jpeg.len or page == 0) {
        var report: [1024]u8 = std.mem.zeroes([1024]u8);
        const chunk: usize = @min(jpeg.len -| off, 1024 - 8);
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

fn setKeyImageMini(dev: *hid.Device, key: u8, img: *const image.Image) !void {
    var bmp: [bmpSize(80, 80)]u8 = undefined;
    const bmp_data = encodeBmpFlippedRotated(&bmp, img);
    try setKeyImageMiniRaw(dev, key, bmp_data);
}

fn setKeyImageMiniRaw(dev: *hid.Device, key: u8, bmp: []const u8) !void {
    const payload_per_report: usize = 1024 - 16;
    var page_number: u8 = 0;
    var off: usize = 0;
    while (off < bmp.len or page_number == 0) {
        var report: [1024]u8 = std.mem.zeroes([1024]u8);
        const chunk: usize = @min(bmp.len -| off, payload_per_report);
        const last: u8 = if (off + chunk >= bmp.len) 1 else 0;
        report[0] = 0x02;
        report[1] = 0x01;
        report[2] = page_number;
        report[3] = 0x00;
        report[4] = last;
        report[5] = key + 1;
        @memcpy(report[16 .. 16 + chunk], bmp[off .. off + chunk]);
        try dev.writeReport(&report);
        off += chunk;
        page_number += 1;
        if (last == 1) break;
    }
}

/// Upload a JPEG to a region of the 800x100 touch strip (Plus only).
pub fn setStripImage(dev: *hid.Device, x: u16, y: u16, w: u16, h: u16, jpeg: []const u8) !void {
    var page: u16 = 0;
    var off: usize = 0;
    while (off < jpeg.len or page == 0) {
        var report: [1024]u8 = std.mem.zeroes([1024]u8);
        const chunk: usize = @min(jpeg.len -| off, 1024 - 16);
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
        report[11] = @truncate(page);
        report[12] = @truncate(page >> 8);
        report[13] = @truncate(chunk);
        report[14] = @truncate(chunk >> 8);
        @memcpy(report[16 .. 16 + chunk], jpeg[off .. off + chunk]);
        try dev.writeReport(&report);
        off += chunk;
        page += 1;
        if (last == 1) break;
    }
}

/// BMP file size for a WxH 24-bit image (14-byte file header + 40-byte
/// info header + pixel data, rows padded to 4-byte boundary).
fn bmpSize(w: usize, h: usize) usize {
    const row = ((w * 3 + 3) / 4) * 4;
    return 54 + row * h;
}

/// Encode an RGB image as a 24-bit BMP with vertical flip + 90° CW rotation
/// (the Mini expects this transform). For a V-flipped then 90° CW rotated
/// image in a bottom-up BMP, BMP row `by`, column `bx` maps to source
/// pixel (by, H-1-bx).
fn encodeBmpFlippedRotated(buf: []u8, img: *const image.Image) []const u8 {
    const w = img.w;
    const h = img.h;
    const rotated_w = h;
    const rotated_h = w;
    const row_padded = ((rotated_w * 3 + 3) / 4) * 4;
    const pixel_size = row_padded * rotated_h;
    const file_size = 54 + pixel_size;

    buf[0] = 'B';
    buf[1] = 'M';
    buf[2] = @truncate(file_size);
    buf[3] = @truncate(file_size >> 8);
    buf[4] = @truncate(file_size >> 16);
    buf[5] = @truncate(file_size >> 24);
    buf[6] = 0;
    buf[7] = 0;
    buf[8] = 0;
    buf[9] = 0;
    buf[10] = 54;
    buf[11] = 0;
    buf[12] = 0;
    buf[13] = 0;

    buf[14] = 40;
    buf[15] = 0;
    buf[16] = 0;
    buf[17] = 0;
    buf[18] = @truncate(rotated_w);
    buf[19] = @truncate(rotated_w >> 8);
    buf[20] = @truncate(rotated_w >> 16);
    buf[21] = @truncate(rotated_w >> 24);
    buf[22] = @truncate(rotated_h);
    buf[23] = @truncate(rotated_h >> 8);
    buf[24] = @truncate(rotated_h >> 16);
    buf[25] = @truncate(rotated_h >> 24);
    buf[26] = 1;
    buf[27] = 0;
    buf[28] = 24;
    buf[29] = 0;
    buf[30] = 0;
    buf[31] = 0;
    buf[32] = 0;
    buf[33] = 0;
    buf[34] = @truncate(pixel_size);
    buf[35] = @truncate(pixel_size >> 8);
    buf[36] = @truncate(pixel_size >> 16);
    buf[37] = @truncate(pixel_size >> 24);
    buf[38] = 0x13;
    buf[39] = 0x0B;
    buf[40] = 0x00;
    buf[41] = 0x00;
    buf[42] = 0x13;
    buf[43] = 0x0B;
    buf[44] = 0x00;
    buf[45] = 0x00;
    buf[46] = 0;
    buf[47] = 0;
    buf[48] = 0;
    buf[49] = 0;
    buf[50] = 0;
    buf[51] = 0;
    buf[52] = 0;
    buf[53] = 0;

    var by: usize = 0;
    while (by < rotated_h) : (by += 1) {
        const dst_off = 54 + by * row_padded;
        var bx: usize = 0;
        while (bx < rotated_w) : (bx += 1) {
            const src_x = by;
            const src_y = h - 1 - bx;
            const si = (src_y * w + src_x) * 3;
            const di = dst_off + bx * 3;
            buf[di] = img.px[si + 2];
            buf[di + 1] = img.px[si + 1];
            buf[di + 2] = img.px[si];
        }
        var pad: usize = rotated_w * 3;
        while (pad < row_padded) : (pad += 1) {
            buf[dst_off + pad] = 0;
        }
    }
    return buf[0..file_size];
}

test "bmpSize" {
    try std.testing.expectEqual(54 + 80 * 80 * 3, bmpSize(80, 80));
    try std.testing.expectEqual(54 + 120 * 120 * 3, bmpSize(120, 120));
}
