//! Latest-message-per-topic store, plus `{topic}` template expansion.
//!
//! The daemon registers every topic its config refers to (key active
//! topics, `{...}` placeholders in labels and strip lines), subscribes to
//! them, and feeds incoming messages into `set`. The draw code then expands
//! templates against the current values. Topics are matched exactly.
const std = @import("std");

pub const max_topics = 128;
pub const value_len = 128;

pub const Store = struct {
    io: std.Io,
    mtx: std.Io.Mutex = .init,
    gen: u64 = 0,
    count: usize = 0,
    topics: [max_topics][]const u8 = undefined,
    vals: [max_topics][value_len]u8 = undefined,
    lens: [max_topics]u8 = .{0} ** max_topics,
    has: [max_topics]bool = .{false} ** max_topics,

    /// Startup only (before any thread reads). `topic` must outlive the store.
    pub fn register(self: *Store, topic: []const u8) void {
        if (topic.len == 0 or topic[0] == '@') return;
        for (self.topics[0..self.count]) |t| if (std.mem.eql(u8, t, topic)) return;
        if (self.count == max_topics) {
            std.debug.print("store: too many topics, ignoring {s}\n", .{topic});
            return;
        }
        self.topics[self.count] = topic;
        self.count += 1;
    }

    /// Register every `{topic}` placeholder found in a template.
    pub fn registerTemplate(self: *Store, template: []const u8) void {
        var it = placeholders(template);
        while (it.next()) |name| self.register(name);
    }

    /// Record a message. Returns false if nobody asked for this topic.
    pub fn set(self: *Store, topic: []const u8, payload: []const u8) bool {
        self.mtx.lockUncancelable(self.io);
        defer self.mtx.unlock(self.io);
        for (self.topics[0..self.count], 0..) |t, i| {
            if (!std.mem.eql(u8, t, topic)) continue;
            const n = @min(payload.len, value_len);
            if (self.has[i] and self.lens[i] == n and std.mem.eql(u8, self.vals[i][0..n], payload[0..n])) return true;
            @memcpy(self.vals[i][0..n], payload[0..n]);
            self.lens[i] = @intCast(n);
            self.has[i] = true;
            self.gen +%= 1;
            return true;
        }
        return false;
    }

    pub fn generation(self: *Store) u64 {
        self.mtx.lockUncancelable(self.io);
        defer self.mtx.unlock(self.io);
        return self.gen;
    }

    /// Copy of the latest value (arena-owned), or null if none yet.
    pub fn get(self: *Store, arena: std.mem.Allocator, topic: []const u8) ?[]const u8 {
        self.mtx.lockUncancelable(self.io);
        defer self.mtx.unlock(self.io);
        for (self.topics[0..self.count], 0..) |t, i| {
            if (!std.mem.eql(u8, t, topic)) continue;
            if (!self.has[i]) return null;
            return arena.dupe(u8, self.vals[i][0..self.lens[i]]) catch null;
        }
        return null;
    }

    /// Replace each `{topic}` with its latest value ("-" if none yet);
    /// `{@page}` becomes `page_name`. Result is arena-owned.
    pub fn expand(self: *Store, arena: std.mem.Allocator, template: []const u8, page_name: []const u8) []const u8 {
        if (std.mem.indexOfScalar(u8, template, '{') == null) return template;
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < template.len) {
            if (template[i] == '{') {
                if (std.mem.indexOfScalarPos(u8, template, i + 1, '}')) |end| {
                    const name = template[i + 1 .. end];
                    const val = if (std.mem.eql(u8, name, "@page")) page_name else (self.get(arena, name) orelse "-");
                    out.appendSlice(arena, val) catch return template;
                    i = end + 1;
                    continue;
                }
            }
            out.append(arena, template[i]) catch return template;
            i += 1;
        }
        return out.items;
    }
};

const Placeholders = struct {
    s: []const u8,
    i: usize = 0,

    fn next(self: *Placeholders) ?[]const u8 {
        while (std.mem.indexOfScalarPos(u8, self.s, self.i, '{')) |open| {
            const close = std.mem.indexOfScalarPos(u8, self.s, open + 1, '}') orelse return null;
            self.i = close + 1;
            return self.s[open + 1 .. close];
        }
        return null;
    }
};

fn placeholders(s: []const u8) Placeholders {
    return .{ .s = s };
}

test "expand substitutes values, dashes for unknown, and @page" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var st: Store = .{ .io = threaded.io() };
    st.registerTemplate("{a/b} and {c} on {@page}");
    try std.testing.expectEqual(@as(usize, 2), st.count);
    try std.testing.expect(st.set("a/b", "hello"));
    try std.testing.expect(!st.set("nope", "x"));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = st.expand(arena.allocator(), "{a/b} and {c} on {@page}", "LIGHTS");
    try std.testing.expectEqualStrings("hello and - on LIGHTS", out);
    try std.testing.expectEqualStrings("plain", st.expand(arena.allocator(), "plain", "X"));
}

test "set only bumps the generation on a change" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var st: Store = .{ .io = threaded.io() };
    st.register("t");
    _ = st.set("t", "1");
    const g = st.generation();
    _ = st.set("t", "1");
    try std.testing.expectEqual(g, st.generation());
    _ = st.set("t", "2");
    try std.testing.expect(st.generation() != g);
}
