//! TrueType text rendering via vendored stb_truetype. Used for deck
//! key/strip labels when config.json sets font_path (e.g. a Nerd Font —
//! PUA icon codepoints work, labels are UTF-8). Falls back to the built-in
//! 8x8 bitmap font when no font is configured or the file won't load.
const std = @import("std");
const image = @import("image.zig");
const c = @cImport(@cInclude("stb_truetype.h"));

pub const Font = struct {
    info: c.stbtt_fontinfo,
    data: []u8, // keep the font file alive: info points into it
    ascent: i32,
    descent: i32,

    /// Load a .ttf from disk. Caller keeps the returned struct; the file
    /// bytes are freed by deinit.
    pub fn load(alloc: std.mem.Allocator, path: []const u8) !Font {
        const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return error.FontNotFound;
        var data: std.ArrayList(u8) = .empty;
        var tmp: [64 * 1024]u8 = undefined;
        while (true) {
            const n = std.posix.read(fd, &tmp) catch break;
            if (n == 0) break;
            try data.appendSlice(alloc, tmp[0..n]);
        }
        _ = std.os.linux.close(fd);
        if (data.items.len == 0) return error.FontNotFound;

        var info: c.stbtt_fontinfo = undefined;
        if (c.stbtt_InitFont(&info, data.items.ptr, 0) == 0) return error.BadFont;
        var ascent: i32 = 0;
        var descent: i32 = 0;
        var line_gap: i32 = 0;
        c.stbtt_GetFontVMetrics(&info, &ascent, &descent, &line_gap);
        return .{ .info = info, .data = data.items, .ascent = ascent, .descent = descent };
    }

    pub fn deinit(self: *Font, alloc: std.mem.Allocator) void {
        alloc.free(self.data);
    }

    /// Rendered width of `text` at `px` pixels (em height), no kerning.
    pub fn measure(self: *const Font, text: []const u8, px: u16) usize {
        const scale = c.stbtt_ScaleForPixelHeight(&self.info, px);
        var width: f32 = 0;
        var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
        while (it.nextCodepoint()) |cp| {
            var adv: i32 = 0;
            c.stbtt_GetCodepointHMetrics(&self.info, @intCast(cp), &adv, null);
            width += @as(f32, @floatFromInt(adv)) * scale;
        }
        return @intFromFloat(width);
    }

    /// Draw text with its horizontal center at cx and vertical center at cy.
    pub fn drawCentered(self: *const Font, img: *image.Image, text: []const u8, cx: usize, cy: usize, px: u16, r: u8, g: u8, b: u8) void {
        const w = self.measure(text, px);
        const scale = c.stbtt_ScaleForPixelHeight(&self.info, px);
        const baseline: i32 = @intFromFloat(@as(f32, @floatFromInt(cy)) + @as(f32, @floatFromInt(self.ascent + self.descent)) * scale / 2.0);
        var pen: i32 = @intFromFloat(@as(f32, @floatFromInt(cx)) - @as(f32, @floatFromInt(w)) / 2.0);

        var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
        while (it.nextCodepoint()) |cp| {
            var adv: i32 = 0;
            c.stbtt_GetCodepointHMetrics(&self.info, @intCast(cp), &adv, null);
            var gw: i32 = 0;
            var gh: i32 = 0;
            var xoff: i32 = 0;
            var yoff: i32 = 0;
            const bitmap = c.stbtt_GetCodepointBitmap(&self.info, 0, scale, @intCast(cp), &gw, &gh, &xoff, &yoff);
            if (bitmap != null and gw > 0 and gh > 0) {
                self.blend(img, bitmap, @intCast(gw), @intCast(gh), pen + xoff, baseline + yoff, r, g, b);
                c.stbtt_FreeBitmap(bitmap, null);
            }
            pen += @intFromFloat(@as(f32, @floatFromInt(adv)) * scale);
        }
    }

    /// Alpha-blend an stb coverage bitmap onto the RGB image.
    fn blend(self: *const Font, img: *image.Image, bitmap: [*]const u8, w: usize, h: usize, ox: i32, oy: i32, r: u8, g: u8, b: u8) void {
        _ = self;
        var y: usize = 0;
        while (y < h) : (y += 1) {
            const dy = oy + @as(i32, @intCast(y));
            if (dy < 0 or dy >= @as(i32, @intCast(img.h))) continue;
            var x: usize = 0;
            while (x < w) : (x += 1) {
                const dx = ox + @as(i32, @intCast(x));
                if (dx < 0 or dx >= @as(i32, @intCast(img.w))) continue;
                const a = bitmap[y * w + x];
                if (a == 0) continue;
                const i = (@as(usize, @intCast(dy)) * img.w + @as(usize, @intCast(dx))) * 3;
                const af: u16 = a;
                const inv: u16 = 255 - af;
                img.px[i] = @intCast((@as(u16, r) * af + @as(u16, img.px[i]) * inv) / 255);
                img.px[i + 1] = @intCast((@as(u16, g) * af + @as(u16, img.px[i + 1]) * inv) / 255);
                img.px[i + 2] = @intCast((@as(u16, b) * af + @as(u16, img.px[i + 2]) * inv) / 255);
            }
        }
    }
};
