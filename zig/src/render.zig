//! Text + shape drawing on image.Image, using the embedded font8x8.
const std = @import("std");
const image = @import("image.zig");
const font = @import("font8x8.zig");

pub fn drawChar(img: *image.Image, ch: u8, ox: usize, oy: usize, scale: usize, r: u8, g: u8, b: u8) void {
    if (ch >= 128) return;
    const glyph = font.basic[ch];
    for (glyph, 0..) |row_bits, row| {
        var col: usize = 0;
        while (col < 8) : (col += 1) {
            if (row_bits & (@as(u8, 1) << @intCast(col)) != 0) {
                img.fillRect(ox + col * scale, oy + row * scale, scale, scale, r, g, b);
            }
        }
    }
}

pub fn textWidth(text: []const u8, scale: usize) usize {
    return text.len * 8 * scale;
}

pub fn drawText(img: *image.Image, text: []const u8, ox: usize, oy: usize, scale: usize, r: u8, g: u8, b: u8) void {
    var x = ox;
    for (text) |ch| {
        drawChar(img, ch, x, oy, scale, r, g, b);
        x += 8 * scale;
    }
}

pub fn drawTextCentered(img: *image.Image, text: []const u8, oy: usize, scale: usize, r: u8, g: u8, b: u8) void {
    const w = textWidth(text, scale);
    const ox = if (w >= img.w) 0 else (img.w - w) / 2;
    drawText(img, text, ox, oy, scale, r, g, b);
}

pub fn border(img: *image.Image, thickness: usize, r: u8, g: u8, b: u8) void {
    img.fillRect(0, 0, img.w, thickness, r, g, b);
    img.fillRect(0, img.h - thickness, img.w, thickness, r, g, b);
    img.fillRect(0, 0, thickness, img.h, r, g, b);
    img.fillRect(img.w - thickness, 0, thickness, img.h, r, g, b);
}
