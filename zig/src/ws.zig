//! Minimal WebSocket client for the matrix framebuffer stream
//! (matrix_sim.py's FrameBroadcaster). Runs a background thread that keeps
//! the newest 64x32 RGB frame; reconnects forever on failure.
//!
//! Protocol: text frames only. On connect the server sends
//! {"type":"hello","w":64,"h":32}, then one {"type":"frame",...,"data":
//! "<base64 raw R,G,B,...>"} per redraw. The python `websockets` server
//! pings periodically; we must pong back.
const std = @import("std");

pub const max_w = 128;
pub const max_h = 64;

pub const FrameFeed = struct {
    io: std.Io,
    host: [64]u8 = undefined,
    host_len: usize = 0,
    port: u16 = 8888,

    mtx: std.Io.Mutex = .init,
    frame: [max_w * max_h * 3]u8 = undefined,
    w: usize = 0,
    h: usize = 0,
    counter: u64 = 0, // bumped per new frame; 0 = none yet

    pub fn init(io: std.Io, base_url: []const u8) FrameFeed {
        var self: FrameFeed = .{ .io = io };
        // base_url looks like http://host:8787 — borrow the host, use 8888.
        var rest = base_url;
        if (std.mem.indexOf(u8, rest, "://")) |i| rest = rest[i + 3 ..];
        var host = rest;
        if (std.mem.indexOfScalar(u8, host, ':')) |i| {
            host = host[0..i];
        } else if (std.mem.indexOfScalar(u8, host, '/')) |i| {
            host = host[0..i];
        }
        const n = @min(host.len, self.host.len);
        @memcpy(self.host[0..n], host[0..n]);
        self.host_len = n;
        return self;
    }

    /// Copy out the latest frame. Returns false if none has arrived.
    pub fn latest(self: *FrameFeed, out: []u8, w: *usize, h: *usize) bool {
        self.mtx.lockUncancelable(self.io);
        defer self.mtx.unlock(self.io);
        if (self.counter == 0) return false;
        w.* = self.w;
        h.* = self.h;
        @memcpy(out[0 .. self.w * self.h * 3], self.frame[0 .. self.w * self.h * 3]);
        return true;
    }

    pub fn frameCounter(self: *FrameFeed) u64 {
        self.mtx.lockUncancelable(self.io);
        defer self.mtx.unlock(self.io);
        return self.counter;
    }

    /// Never returns; spawn on its own thread.
    pub fn run(self: *FrameFeed) void {
        while (true) {
            self.connectAndRead() catch {};
            std.Io.sleep(self.io, .fromMilliseconds(2000), .awake) catch {};
        }
    }

    fn connectAndRead(self: *FrameFeed) !void {
        const host = self.host[0..self.host_len];
        // Literal IPs only; map the usual names by hand.
        const ip_txt = if (std.mem.eql(u8, host, "localhost")) "127.0.0.1" else host;
        const addr = std.Io.net.IpAddress.parse(ip_txt, self.port) catch return error.BadHost;
        const stream = try addr.connect(self.io, .{ .mode = .stream });
        defer stream.close(self.io);

        var rbuf: [64 * 1024]u8 = undefined;
        var reader = stream.reader(self.io, &rbuf);
        var wbuf: [4 * 1024]u8 = undefined;
        var writer = stream.writer(self.io, &wbuf);

        try self.handshake(&reader.interface, &writer.interface, host);
        while (true) try self.readFrame(&reader.interface, &writer.interface);
    }

    fn handshake(self: *FrameFeed, r: *std.Io.Reader, w: *std.Io.Writer, host: []const u8) !void {
        // Random-ish key; the server is local and trusted, so no accept check.
        var key_bytes: [16]u8 = undefined;
        std.Io.random(self.io, &key_bytes);
        var key_b64: [24]u8 = undefined;
        const key = std.base64.standard.Encoder.encode(&key_b64, &key_bytes);
        try w.print("GET / HTTP/1.1\r\nHost: {s}:{d}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n", .{ host, self.port, key });
        try w.flush();
        // Status line must be 101; then drain headers.
        const status = r.takeDelimiterInclusive('\n') catch return error.HandshakeFailed;
        if (std.mem.indexOf(u8, status, " 101") == null) return error.HandshakeFailed;
        while (true) {
            const line = r.takeDelimiterInclusive('\n') catch return error.HandshakeFailed;
            if (line.len <= 2) break;
        }
    }

    fn readFrame(self: *FrameFeed, r: *std.Io.Reader, w: *std.Io.Writer) !void {
        const b0 = try r.takeByte();
        const b1 = try r.takeByte();
        const opcode = b0 & 0x0f;
        var len: u64 = b1 & 0x7f;
        if (len == 126) len = try r.takeInt(u16, .big);
        if (len == 127) len = try r.takeInt(u64, .big);
        if (len > 256 * 1024) return error.FrameTooLarge;

        switch (opcode) {
            0x9 => { // ping → pong with same payload
                var payload: [125]u8 = undefined;
                if (len > payload.len) return error.FrameTooLarge;
                try r.readSliceAll(payload[0..@intCast(len)]);
                // server→client frames are unmasked; client must mask.
                try writeFrame(w, 0xA, payload[0..@intCast(len)]);
            },
            0x8 => return error.Closed,
            0x1, 0x0 => { // text / continuation
                var payload: [200 * 1024]u8 = undefined;
                try r.readSliceAll(payload[0..@intCast(len)]);
                self.handleMessage(payload[0..@intCast(len)]) catch {};
            },
            else => { // pong and others: discard payload
                var sink: [256]u8 = undefined;
                var left = len;
                while (left > 0) {
                    const chunk: usize = @intCast(@min(left, sink.len));
                    try r.readSliceAll(sink[0..chunk]);
                    left -= chunk;
                }
            },
        }
    }

    fn handleMessage(self: *FrameFeed, msg: []const u8) !void {
        const parsed = try std.json.parseFromSlice(struct {
            type: []const u8 = "",
            w: usize = 0,
            h: usize = 0,
            data: []const u8 = "",
        }, std.heap.page_allocator, msg, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const v = parsed.value;
        if (!std.mem.eql(u8, v.type, "frame")) return;
        if (v.w == 0 or v.h == 0 or v.w > max_w or v.h > max_h) return;
        const need = v.w * v.h * 3;
        if (std.base64.standard.Decoder.calcSizeForSlice(v.data) catch return != need) return;

        self.mtx.lockUncancelable(self.io);
        defer self.mtx.unlock(self.io);
        std.base64.standard.Decoder.decode(self.frame[0..need], v.data) catch return;
        self.w = v.w;
        self.h = v.h;
        self.counter += 1;
        if (self.counter == 1)
            std.debug.print("feed: first frame {d}x{d} from matrix stream\n", .{ self.w, self.h });
    }
};

/// Client-side frame: must set the mask bit. Only used for pong.
fn writeFrame(w: *std.Io.Writer, opcode: u8, payload: []const u8) !void {
    try w.writeByte(0x80 | opcode);
    const mask_bit: u8 = 0x80;
    if (payload.len < 126) {
        try w.writeByte(mask_bit | @as(u8, @intCast(payload.len)));
    } else {
        try w.writeByte(mask_bit | 126);
        try w.writeInt(u16, @intCast(payload.len), .big);
    }
    const mask = [4]u8{ 0x12, 0x34, 0x56, 0x78 }; // arbitrary
    try w.writeAll(&mask);
    for (payload, 0..) |b, i| try w.writeByte(b ^ mask[i % 4]);
    try w.flush();
}
