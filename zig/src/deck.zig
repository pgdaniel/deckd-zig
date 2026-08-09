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

pub const Event = union(enum) {
    key: struct { index: u8, pressed: bool },
    dial_rotate: struct { index: u8, delta: i8 },
    dial_press: struct { index: u8, pressed: bool },
    touch_press: struct { x: u16, y: u16 },
    touch_long_press: struct { x: u16, y: u16 },
    touch_swipe: struct { x0: u16, y0: u16, x1: u16, y1: u16 },
};

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

/// Parse an input report into an Event. Report layout verified against
/// hardware; see `deckd dump`.
pub fn parseEvent(report: []const u8) ?Event {
    if (report.len < 4) return null;
    switch (report[0]) {
        0x01 => {
            // Key states: 8 bytes, one per key.
            if (report.len < 4 + key_count) return null;
            // The device sends the full state each change; report one event
            // per changed key is the caller's job. Here we return the first
            // pressed key found, or null. Refined once dump data is in.
            return null;
        },
        0x03 => switch (report[1]) {
            0x00 => return null, // dial press states, 4 bytes at [2..6]
            0x01 => return null, // dial rotations, 4 signed bytes at [2..6]
            else => return null,
        },
        else => return null,
    }
}
