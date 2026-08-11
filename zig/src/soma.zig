//! Client for soma-zig's Unix-socket IPC (see soma-zig src/ipc.zig).
const std = @import("std");

pub const Status = struct {
    playing: bool = false,
    connecting: bool = false,
    channel: []const u8 = "",
    channel_id: []const u8 = "",
    track: []const u8 = "",
    volume: u8 = 0,
};

const JsonStatus = struct {
    playing: bool = false,
    connecting: bool = false,
    channel: []const u8 = "",
    channel_id: []const u8 = "",
    track: []const u8 = "",
    volume: u8 = 0,
};

pub const Client = struct {
    io: std.Io,
    path_buf: [108]u8 = undefined,
    path_len: usize = 0,

    pub fn init(io: std.Io) Client {
        var self: Client = .{ .io = io };
        var sock_path: []const u8 = "/tmp/soma.sock";
        if (std.c.getenv("XDG_RUNTIME_DIR")) |dir| {
            const d = std.mem.sliceTo(dir, 0);
            if (std.fmt.bufPrint(&self.path_buf, "{s}/soma.sock", .{d}) catch null) |p| {
                self.path_len = p.len;
                return self;
            }
        } else {
            const uid = std.os.linux.getuid();
            sock_path = std.fmt.bufPrint(&self.path_buf, "/tmp/soma-{d}.sock", .{uid}) catch sock_path;
        }
        self.path_len = sock_path.len;
        return self;
    }

    fn path(self: *const Client) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    /// Send one command line; returns the reply line (arena-owned).
    pub fn command(self: *const Client, arena: std.mem.Allocator, cmd: []const u8) ![]const u8 {
        // Pre-check the socket file exists: connecting to a missing one
        // surfaces ECONNREFUSED through std as a noisy "unexpected errno"
        // trace on 0.16, and soma simply not running is the common case.
        {
            const p = self.path();
            var path_z: [109]u8 = undefined;
            @memcpy(path_z[0..p.len], p);
            path_z[p.len] = 0;
            const rc = std.os.linux.access(@ptrCast(path_z[0..p.len :0].ptr), 0); // F_OK
            if (std.os.linux.errno(rc) != .SUCCESS) return error.Offline;
        }
        const addr = try std.Io.net.UnixAddress.init(self.path());
        const stream = std.Io.net.UnixAddress.connect(&addr, self.io) catch return error.Offline;
        defer stream.close(self.io);

        var wbuf: [256]u8 = undefined;
        var writer = stream.writer(self.io, &wbuf);
        const w = &writer.interface;
        try w.writeAll(cmd);
        try w.writeAll("\n");
        try w.flush();

        var rbuf: [2048]u8 = undefined;
        var reader = stream.reader(self.io, &rbuf);
        const line = (try reader.interface.takeDelimiter('\n')) orelse return error.NoReply;
        return arena.dupe(u8, std.mem.trim(u8, line, " \t\r"));
    }

    pub fn status(self: *const Client, arena: std.mem.Allocator) !Status {
        const reply = try self.command(arena, "status");
        const parsed = try std.json.parseFromSlice(JsonStatus, arena, reply, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        const v = parsed.value;
        return .{
            .playing = v.playing,
            .connecting = v.connecting,
            .channel = v.channel,
            .channel_id = v.channel_id,
            .track = v.track,
            .volume = v.volume,
        };
    }
};
