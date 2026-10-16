//! RGB framebuffer → JPEG, via vendored stb_image_write. Icon files (PNG/
//! JPEG/BMP/GIF) load the other way, via vendored stb_image.
const std = @import("std");
const c = @cImport(@cInclude("stb_image_write.h"));
const ic = @cImport(@cInclude("stb_image.h"));

pub const Image = struct {
    w: usize,
    h: usize,
    px: []u8, // RGB, row-major, top-left origin

    pub fn init(alloc: std.mem.Allocator, w: usize, h: usize) !Image {
        return .{ .w = w, .h = h, .px = try alloc.alloc(u8, w * h * 3) };
    }

    pub fn fill(self: *Image, r: u8, g: u8, b: u8) void {
        var i: usize = 0;
        while (i < self.px.len) : (i += 3) {
            self.px[i] = r;
            self.px[i + 1] = g;
            self.px[i + 2] = b;
        }
    }

    pub fn set(self: *Image, x: usize, y: usize, r: u8, g: u8, b: u8) void {
        if (x >= self.w or y >= self.h) return;
        const i = (y * self.w + x) * 3;
        self.px[i] = r;
        self.px[i + 1] = g;
        self.px[i + 2] = b;
    }

    pub fn fillRect(self: *Image, x: usize, y: usize, w: usize, h: usize, r: u8, g: u8, b: u8) void {
        var yy = y;
        while (yy < y + h) : (yy += 1) {
            var xx = x;
            while (xx < x + w) : (xx += 1) self.set(xx, yy, r, g, b);
        }
    }
};

const EncodeCtx = struct {
    list: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    failed: bool = false,
};

fn encodeCb(ctx_ptr: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void {
    const ctx: *EncodeCtx = @ptrCast(@alignCast(ctx_ptr.?));
    const bytes: [*]const u8 = @ptrCast(data.?);
    ctx.list.appendSlice(ctx.alloc, bytes[0..@intCast(size)]) catch {
        ctx.failed = true;
    };
}

/// Encode as JPEG, appended to out. quality 1-100.
pub fn encodeJpeg(img: *const Image, quality: c_int, out: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    var ctx: EncodeCtx = .{ .list = out, .alloc = alloc };
    const ok = c.stbi_write_jpg_to_func(
        encodeCb,
        &ctx,
        @intCast(img.w),
        @intCast(img.h),
        3,
        img.px.ptr,
        quality,
    );
    if (ok == 0 or ctx.failed) return error.EncodeFailed;
}

/// Icon fit margin: the icon is scaled to fit within this fraction of
/// dst's bounds rather than the full canvas, so it doesn't touch the
/// key's edges (an icon scaled to fill the whole key reads as cropped/
/// cramped at a glance, even though nothing is actually cut off).
const icon_fit_margin: f32 = 0.8;

/// Decode an icon file (PNG/JPEG/BMP/GIF) and alpha-blend it onto dst,
/// nearest-neighbor scaled to fit dst's bounds (preserving aspect ratio,
/// leaving a margin — see icon_fit_margin) and centered. dst should
/// already be filled with the desired background — that shows through
/// untouched wherever the icon is transparent, letterboxed, or margined.
/// Icons are expected to be small; the file is read into a fixed 1 MiB
/// buffer and rejected outright if it doesn't fit.
pub fn drawIconFit(dst: *Image, path: []const u8) !void {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = std.os.linux.close(fd);

    var file_buf: [1024 * 1024]u8 = undefined;
    const n = try std.posix.read(fd, &file_buf);
    if (n == file_buf.len) return error.FileTooLarge;

    var w: c_int = 0;
    var h: c_int = 0;
    var channels: c_int = 0;
    const rgba = ic.stbi_load_from_memory(file_buf[0..n].ptr, @intCast(n), &w, &h, &channels, 4);
    if (rgba == null or w <= 0 or h <= 0) return error.DecodeFailed;
    defer ic.stbi_image_free(rgba);
    const sw: usize = @intCast(w);
    const sh: usize = @intCast(h);

    const scale = icon_fit_margin * @min(
        @as(f32, @floatFromInt(dst.w)) / @as(f32, @floatFromInt(sw)),
        @as(f32, @floatFromInt(dst.h)) / @as(f32, @floatFromInt(sh)),
    );
    const out_w: usize = @max(1, @as(usize, @intFromFloat(@as(f32, @floatFromInt(sw)) * scale)));
    const out_h: usize = @max(1, @as(usize, @intFromFloat(@as(f32, @floatFromInt(sh)) * scale)));
    const ox = (dst.w -| out_w) / 2;
    const oy = (dst.h -| out_h) / 2;

    var y: usize = 0;
    while (y < out_h) : (y += 1) {
        const sy = @min(sh - 1, (y * sh) / out_h);
        var x: usize = 0;
        while (x < out_w) : (x += 1) {
            const sx = @min(sw - 1, (x * sw) / out_w);
            const si = (sy * sw + sx) * 4;
            const a: u16 = rgba[si + 3];
            if (a == 0) continue;
            if (a == 255) {
                dst.set(ox + x, oy + y, rgba[si], rgba[si + 1], rgba[si + 2]);
                continue;
            }
            const di = ((oy + y) * dst.w + (ox + x)) * 3;
            const ia: u16 = 255 - a;
            const r: u8 = @intCast((@as(u16, rgba[si]) * a + @as(u16, dst.px[di]) * ia) / 255);
            const g: u8 = @intCast((@as(u16, rgba[si + 1]) * a + @as(u16, dst.px[di + 1]) * ia) / 255);
            const b: u8 = @intCast((@as(u16, rgba[si + 2]) * a + @as(u16, dst.px[di + 2]) * ia) / 255);
            dst.set(ox + x, oy + y, r, g, b);
        }
    }
}

/// Decode a JPEG/PNG from memory and "cover" it into dst: scaled (bilinear)
/// so it fills dst completely, center-cropping whichever axis overflows.
pub fn decodeCover(dst: *Image, bytes: []const u8) !void {
    var w: c_int = 0;
    var h: c_int = 0;
    var channels: c_int = 0;
    const rgb = ic.stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &channels, 3);
    if (rgb == null or w <= 0 or h <= 0) return error.DecodeFailed;
    defer ic.stbi_image_free(rgb);
    const sw: usize = @intCast(w);
    const sh: usize = @intCast(h);

    const dw: f32 = @floatFromInt(dst.w);
    const dh: f32 = @floatFromInt(dst.h);
    const fsw: f32 = @floatFromInt(sw);
    const fsh: f32 = @floatFromInt(sh);
    const s = @max(dw / fsw, dh / fsh);
    const off_x = (fsw - dw / s) / 2;
    const off_y = (fsh - dh / s) / 2;

    var y: usize = 0;
    while (y < dst.h) : (y += 1) {
        const fy = std.math.clamp((@as(f32, @floatFromInt(y)) + 0.5) / s + off_y - 0.5, 0, fsh - 1);
        const y0: usize = @intFromFloat(fy);
        const y1 = @min(sh - 1, y0 + 1);
        const ty = fy - @as(f32, @floatFromInt(y0));
        var x: usize = 0;
        while (x < dst.w) : (x += 1) {
            const fx = std.math.clamp((@as(f32, @floatFromInt(x)) + 0.5) / s + off_x - 0.5, 0, fsw - 1);
            const x0: usize = @intFromFloat(fx);
            const x1 = @min(sw - 1, x0 + 1);
            const tx = fx - @as(f32, @floatFromInt(x0));
            const di = (y * dst.w + x) * 3;
            inline for (0..3) |ch| {
                const p00: f32 = @floatFromInt(rgb[(y0 * sw + x0) * 3 + ch]);
                const p10: f32 = @floatFromInt(rgb[(y0 * sw + x1) * 3 + ch]);
                const p01: f32 = @floatFromInt(rgb[(y1 * sw + x0) * 3 + ch]);
                const p11: f32 = @floatFromInt(rgb[(y1 * sw + x1) * 3 + ch]);
                const top = p00 + (p10 - p00) * tx;
                const bot = p01 + (p11 - p01) * tx;
                dst.px[di + ch] = @intFromFloat(@round(top + (bot - top) * ty));
            }
        }
    }
}

/// Copy the dst-sized window of src at (sx, sy) into dst, scaled to
/// `percent` brightness (so text drawn on top stays readable).
pub fn blitDim(dst: *Image, src: *const Image, sx: usize, sy: usize, percent: u16) void {
    var y: usize = 0;
    while (y < dst.h) : (y += 1) {
        var x: usize = 0;
        while (x < dst.w) : (x += 1) {
            if (sx + x >= src.w or sy + y >= src.h) continue;
            const si = ((sy + y) * src.w + sx + x) * 3;
            const di = (y * dst.w + x) * 3;
            inline for (0..3) |ch| dst.px[di + ch] = @intCast(@as(u16, src.px[si + ch]) * percent / 100);
        }
    }
}
