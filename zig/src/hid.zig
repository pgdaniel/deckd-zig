//! Raw hidraw access: device discovery, feature reports, report I/O.
const std = @import("std");
const deck = @import("deck.zig");

pub const vid = 0x0fd9;
pub const pid_plus = 0x0084;
pub const pid_mini = 0x00b8;
pub const pid_v2 = 0x006d; // Stream Deck original V2 (15 keys)
pub const pid_mk2 = 0x0080; // Stream Deck MK.2 (same protocol as the V2)

pub const DeviceInfo = struct {
    path: [64]u8,
    path_len: usize,
    model: deck.Model,
};

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
            .IO, .NODEV, .NXIO => return error.DeviceGone,
            else => return error.IoctlFailed,
        }
    }

    /// Send a feature report. payload[0] is the report id.
    pub fn setFeature(self: *Device, payload: []const u8) !void {
        var buf: [32]u8 = std.mem.zeroes([32]u8);
        if (payload.len > buf.len) return error.PayloadTooLarge;
        @memcpy(buf[0..payload.len], payload);
        const rc = std.os.linux.ioctl(self.fd, hidioCSFeature(payload.len), @intFromPtr(&buf));
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {},
            .IO, .NODEV, .NXIO => return error.DeviceGone,
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
                .IO, .NODEV, .NXIO => return error.DeviceGone,
                else => return error.WriteFailed,
            }
        }
    }

    /// Wait up to timeout_ms for an input report. Returns null on timeout.
    /// error.DeviceGone means the cable was pulled: the kernel keeps the fd
    /// open but signals POLLERR|POLLHUP (and reads fail with EIO), so
    /// without this check poll would return instantly forever — a busy loop.
    pub fn pollReport(self: *Device, buf: []u8, timeout_ms: i32) !?usize {
        var fds = [_]std.posix.pollfd{
            .{ .fd = self.fd, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const n = try std.posix.poll(&fds, timeout_ms);
        if (n == 0) return null;
        if (fds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) != 0)
            return error.DeviceGone;
        const got = std.posix.read(self.fd, buf) catch |err| switch (err) {
            error.WouldBlock => return null, // raced with poll; treat as timeout
            else => return error.DeviceGone,
        };
        return got;
    }
};

/// Find the /dev/hidrawN path for a supported Stream Deck by matching
/// VID/PID in /sys/class/hidraw/hidrawN/device/uevent. Returns the path
/// and detected model, or null if no device is found. Probes the first 32
/// hidraw nodes (no directory iteration — std.fs has no Dir in zig 0.16).
pub fn findDevice(buf: []u8) !?DeviceInfo {
    var n: usize = 0;
    while (n < 32) : (n += 1) {
        var uevent_path_buf: [256]u8 = undefined;
        const uevent_path = std.fmt.bufPrint(&uevent_path_buf, "/sys/class/hidraw/hidraw{d}/device/uevent", .{n}) catch continue;
        const fd = std.posix.openat(std.posix.AT.FDCWD, uevent_path, .{ .ACCMODE = .RDONLY }, 0) catch continue;
        var content: [1024]u8 = undefined;
        const len = std.posix.read(fd, &content) catch 0;
        _ = std.os.linux.close(fd);
        const slice = content[0..len];
        const model: ?deck.Model = if (std.mem.indexOf(u8, slice, "00000FD9:00000084") != null)
            .plus
        else if (std.mem.indexOf(u8, slice, "00000FD9:000000B8") != null)
            .mini
        else if (std.mem.indexOf(u8, slice, "00000FD9:0000006D") != null or
            std.mem.indexOf(u8, slice, "00000FD9:00000080") != null)
            .v2
        else
            null;
        if (model) |m| {
            const path = try std.fmt.bufPrint(buf, "/dev/hidraw{d}", .{n});
            var info: DeviceInfo = undefined;
            @memcpy(info.path[0..path.len], path);
            info.path_len = path.len;
            info.model = m;
            return info;
        }
    }
    return null;
}
