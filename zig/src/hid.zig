//! Raw hidraw access: device discovery, feature reports, report I/O.
const std = @import("std");

pub const vid = 0x0fd9;
pub const pid = 0x0084;

// linux/hidraw.h: HIDIOC{S,G}FEATURE = _IOC(_IOC_WRITE|_IOC_READ, 'H', 0x06/0x07, len)
fn ioc(dir: u32, ty: u32, nr: u32, size: u32) u32 {
    return (dir << 30) | (ty << 8) | nr | (size << 16);
}
fn hidioCSFeature(len: usize) u32 {
    return ioc(3, 'H', 0x06, @intCast(len));
}
fn hidioCGFeature(len: usize) u32 {
    return ioc(3, 'H', 0x07, @intCast(len));
}

pub const Device = struct {
    fd: std.posix.fd_t,

    pub fn open(path: []const u8) !Device {
        const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDWR, .NONBLOCK = true }, 0);
        return .{ .fd = fd };
    }

    pub fn close(self: *Device) void {
        _ = std.os.linux.close(self.fd);
    }

    /// Fetch a feature report into buf (report id goes in buf[0]; buf is
    /// zeroed first). On success buf holds the full report, id included.
    pub fn getFeature(self: *Device, report_id: u8, buf: []u8) !void {
        @memset(buf, 0);
        buf[0] = report_id;
        const rc = std.os.linux.ioctl(self.fd, hidioCGFeature(buf.len), @intFromPtr(buf.ptr));
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {},
            else => return error.IoctlFailed,
        }
    }

    /// Send a feature report. payload[0] is the report id.
    pub fn setFeature(self: *Device, payload: []const u8) !void {
        var buf: [32]u8 = std.mem.zeroes([32]u8);
        if (payload.len > buf.len) return error.PayloadTooLarge;
        @memcpy(buf[0..payload.len], payload);
        const rc = std.os.linux.ioctl(self.fd, hidioCSFeature(buf.len), @intFromPtr(&buf));
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {},
            else => return error.IoctlFailed,
        }
    }

    pub fn writeReport(self: *Device, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const rc = std.os.linux.write(self.fd, bytes.ptr + off, bytes.len - off);
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => off += rc,
                .AGAIN => continue,
                else => return error.WriteFailed,
            }
        }
    }

    /// Wait up to timeout_ms for an input report. Returns null on timeout.
    pub fn pollReport(self: *Device, buf: []u8, timeout_ms: i32) !?usize {
        var fds = [_]std.posix.pollfd{
            .{ .fd = self.fd, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const n = try std.posix.poll(&fds, timeout_ms);
        if (n == 0) return null;
        const got = std.posix.read(self.fd, buf) catch return null;
        return got;
    }
};

/// Find the /dev/hidrawN path for the Stream Deck Plus by matching
/// VID/PID in /sys/class/hidraw/hidrawN/device/uevent. Returns null if
/// absent. Probes the first 32 hidraw nodes (no directory iteration —
/// std.fs has no Dir in zig 0.16).
pub fn findDevicePath(buf: []u8) !?[]const u8 {
    var n: usize = 0;
    while (n < 32) : (n += 1) {
        var uevent_path_buf: [256]u8 = undefined;
        const uevent_path = std.fmt.bufPrint(&uevent_path_buf, "/sys/class/hidraw/hidraw{d}/device/uevent", .{n}) catch continue;
        const fd = std.posix.openat(std.posix.AT.FDCWD, uevent_path, .{ .ACCMODE = .RDONLY }, 0) catch continue;
        var content: [1024]u8 = undefined;
        const len = std.posix.read(fd, &content) catch 0;
        _ = std.os.linux.close(fd);
        if (std.mem.indexOf(u8, content[0..len], "00000FD9:00000084") == null) continue;
        return try std.fmt.bufPrint(buf, "/dev/hidraw{d}", .{n});
    }
    return null;
}
