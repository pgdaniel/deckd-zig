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

/// Decode an icon file (PNG/JPEG/BMP/GIF) and alpha-blend it onto dst,
/// nearest-neighbor scaled to fit dst's bounds (preserving aspect ratio)
/// and centered. dst should already be filled with the desired background
/// — that shows through untouched wherever the icon is transparent or
/// letterboxed. Icons are expected to be small; the file is read into a
/// fixed 1 MiB buffer and rejected outright if it doesn't fit.
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

    const scale = @min(
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
