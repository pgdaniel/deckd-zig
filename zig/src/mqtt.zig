//! Minimal MQTT 3.1.1 publish-only client (QoS 0, no TLS) — just enough to
//! turn a key press into a broker message for home-automation targets
//! (lights, switches, scripts). Connects per publish, the same way soma.zig
//! connects per command; a LAN broker is the intended target.
//!
//! Host must be a literal IP (or "localhost") — no DNS, same constraint as
//! ws.zig. If the broker is unreachable the caller marks the page offline
//! and carries on, matching the matrix/soma offline handling.
const std = @import("std");

pub const Client = struct {
    io: std.Io,
    host: []const u8 = "",
    port: u16 = 1883,
    username: []const u8 = "",
    password: []const u8 = "",

    /// One shot: connect, PUBLISH topic/payload at QoS 0, DISCONNECT.
    pub fn publish(self: *const Client, topic: []const u8, payload: []const u8) !void {
        if (self.host.len == 0) return error.NotConfigured;
        if (topic.len == 0) return error.EmptyTopic;
        const ip_txt = if (std.mem.eql(u8, self.host, "localhost")) "127.0.0.1" else self.host;
        const addr = std.Io.net.IpAddress.parse(ip_txt, self.port) catch return error.BadHost;
        const stream = addr.connect(self.io, .{ .mode = .stream }) catch return error.Offline;
        defer stream.close(self.io);

        var wbuf: [256]u8 = undefined;
        var writer = stream.writer(self.io, &wbuf);
        const w = &writer.interface;

        var pkt: [1024]u8 = undefined;
        try w.writeAll(try buildConnect(&pkt, "deckd", self.username, self.password));
        try w.flush();

        // CONNACK: 0x20 0x02 <session-present> <return-code>; rc 0 = accepted.
        var rbuf: [64]u8 = undefined;
        var reader = stream.reader(self.io, &rbuf);
        var connack: [4]u8 = undefined;
        try reader.interface.readSliceAll(&connack);
        if (connack[0] != 0x20 or connack[3] != 0) return error.Refused;

        try w.writeAll(try buildPublish(&pkt, topic, payload));
        try w.writeAll(&.{ 0xE0, 0x00 }); // DISCONNECT
        try w.flush();
    }
};

fn writeVarint(w: *std.Io.Writer, x: usize) !void {
    var v = x;
    while (true) {
        var b: u8 = @intCast(v & 0x7f);
        v >>= 7;
        if (v > 0) b |= 0x80;
        try w.writeByte(b);
        if (v == 0) break;
    }
}

fn writeStr(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeInt(u16, @intCast(s.len), .big);
    try w.writeAll(s);
}

fn buildConnect(buf: []u8, client_id: []const u8, username: []const u8, password: []const u8) error{PacketTooLarge}![]const u8 {
    var fbs = std.Io.Writer.fixed(buf);
    const w = &fbs;
    buildConnectInner(w, client_id, username, password) catch return error.PacketTooLarge;
    return fbs.buffered();
}

fn buildConnectInner(w: *std.Io.Writer, client_id: []const u8, username: []const u8, password: []const u8) !void {
    var flags: u8 = 0x02; // clean session
    if (username.len > 0) flags |= 0x80;
    if (password.len > 0) flags |= 0x40;
    var remaining: usize = 10 + 2 + client_id.len;
    if (username.len > 0) remaining += 2 + username.len;
    if (password.len > 0) remaining += 2 + password.len;

    try w.writeByte(0x10);
    try writeVarint(w, remaining);
    try writeStr(w, "MQTT");
    try w.writeByte(4); // protocol level 3.1.1
    try w.writeByte(flags);
    try w.writeInt(u16, 60, .big); // keepalive — irrelevant for one-shot publishes
    try writeStr(w, client_id);
    if (username.len > 0) try writeStr(w, username);
    if (password.len > 0) try writeStr(w, password);
}

fn buildPublish(buf: []u8, topic: []const u8, payload: []const u8) error{PacketTooLarge}![]const u8 {
    var fbs = std.Io.Writer.fixed(buf);
    const w = &fbs;
    buildPublishInner(w, topic, payload) catch return error.PacketTooLarge;
    return fbs.buffered();
}

fn buildPublishInner(w: *std.Io.Writer, topic: []const u8, payload: []const u8) !void {
    try w.writeByte(0x30); // PUBLISH, QoS 0, no retain
    try writeVarint(w, 2 + topic.len + payload.len);
    try writeStr(w, topic);
    try w.writeAll(payload);
}

test "writeVarint" {
    var buf: [8]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try writeVarint(&fbs, 0);
    try writeVarint(&fbs, 127);
    try writeVarint(&fbs, 128);
    try writeVarint(&fbs, 321);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x7f, 0x80, 0x01, 0xc1, 0x02 }, fbs.buffered());
}

test "buildConnect without auth" {
    var buf: [128]u8 = undefined;
    const pkt = try buildConnect(&buf, "deckd", "", "");
    try std.testing.expectEqualSlices(u8, &.{
        0x10, 19, // remaining length
        0x00, 0x04, 'M', 'Q', 'T', 'T', 0x04, 0x02, 0x00, 0x3c,
        0x00, 0x05, 'd', 'e', 'c', 'k', 'd',
    }, pkt);
}

test "buildConnect with user/pass sets flags and appends them" {
    var buf: [128]u8 = undefined;
    const pkt = try buildConnect(&buf, "deckd", "u", "p");
    try std.testing.expectEqual(@as(u8, 0x10), pkt[0]);
    try std.testing.expectEqual(@as(u8, 25), pkt[1]); // 19 + 2+1 + 2+1
    try std.testing.expectEqual(@as(u8, 0xC2), pkt[12]); // clean | user | pass
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x01, 'u', 0x00, 0x01, 'p' }, pkt[pkt.len - 6 ..]);
}

test "buildPublish" {
    var buf: [128]u8 = undefined;
    const pkt = try buildPublish(&buf, "a/b", "ON");
    try std.testing.expectEqualSlices(u8, &.{
        0x30, 0x08, 0x00, 0x03, 'a', '/', 'b', 'O', 'N',
    }, pkt);
}
