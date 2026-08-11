//! Client for matrix_server.py's HTTP control API (default port 8787).
const std = @import("std");

pub const ScreenEntry = struct {
    name: []const u8,
    enabled: bool,
};

pub const Config = struct {
    screens: []ScreenEntry,
    auto_advance: bool,
    current: []const u8,

    /// Names of ALL screens, in panel order. Owned by caller's arena. This
    /// is the jog list: the deck can reach any screen directly, since
    /// "enabled" only governs the auto-advance rotation.
    pub fn allNames(self: *const Config, arena: std.mem.Allocator) ![][]const u8 {
        var names: std.ArrayList([]const u8) = .empty;
        for (self.screens) |s| try names.append(arena, s.name);
        return names.items;
    }
};

const JsonConfig = struct {
    screens: []JsonScreen = &.{},
    auto_advance: bool = false,
    current: []const u8 = "",
};
const JsonScreen = struct {
    name: []const u8 = "",
    enabled: bool = false,
    seconds: f64 = 10,
};

pub const Client = struct {
    http: *std.http.Client,
    base: []const u8,

    fn get(self: *const Client, arena: std.mem.Allocator, path: []const u8) ![]u8 {
        const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ self.base, path });
        const uri = try std.Uri.parse(url);
        var req = try self.http.request(.GET, uri, .{});
        defer req.deinit();
        try req.sendBodiless();
        var redirect_buf: [1024]u8 = undefined;
        var res = try req.receiveHead(&redirect_buf);
        if (@intFromEnum(res.head.status) >= 400) return error.BadStatus;
        var transfer_buf: [4096]u8 = undefined;
        const reader = res.reader(&transfer_buf);
        return reader.allocRemaining(arena, .limited(256 * 1024));
    }

    fn post(self: *const Client, arena: std.mem.Allocator, path: []const u8, body: []const u8) !void {
        const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ self.base, path });
        const uri = try std.Uri.parse(url);
        var req = try self.http.request(.POST, uri, .{
            .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        });
        defer req.deinit();
        try req.sendBodyComplete(@constCast(body));
        var redirect_buf: [1024]u8 = undefined;
        const res = try req.receiveHead(&redirect_buf);
        if (@intFromEnum(res.head.status) >= 400) return error.BadStatus;
    }

    /// GET /screen → bare screen name. Owned by arena.
    pub fn currentScreen(self: *const Client, arena: std.mem.Allocator) ![]const u8 {
        const body = try self.get(arena, "/screen");
        return std.mem.trim(u8, body, " \t\r\n");
    }

    pub fn getConfig(self: *const Client, arena: std.mem.Allocator) !Config {
        const body = try self.get(arena, "/config");
        const parsed = try std.json.parseFromSlice(JsonConfig, arena, body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        const screens = try arena.alloc(ScreenEntry, parsed.value.screens.len);
        for (parsed.value.screens, screens) |js, *se| se.* = .{ .name = js.name, .enabled = js.enabled };
        return .{
            .screens = screens,
            .auto_advance = parsed.value.auto_advance,
            .current = parsed.value.current,
        };
    }

    /// POST /screen/<name> — jump straight to a screen.
    pub fn showScreen(self: *const Client, arena: std.mem.Allocator, name: []const u8) !void {
        const path = try std.fmt.allocPrint(arena, "/screen/{s}", .{name});
        try self.post(arena, path, "");
    }

    pub fn nextScreen(self: *const Client, arena: std.mem.Allocator) !void {
        try self.post(arena, "/next-screen", "");
    }

    pub fn setAutoAdvance(self: *const Client, arena: std.mem.Allocator, on: bool) !void {
        const body = try std.fmt.allocPrint(arena, "{{\"auto_advance\":{}}}", .{on});
        try self.post(arena, "/config", body);
    }
};
