//! RGB framebuffer → JPEG, via vendored stb_image_write.
const std = @import("std");
const c = @cImport(@cInclude("stb_image_write.h"));

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
