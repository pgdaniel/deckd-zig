//! deckd-config: a standalone GTK4 GUI for editing
//! ~/.config/deckd/config.json. Deliberately independent of the daemon —
//! it shares nothing with config.zig/deck.zig, only the on-disk JSON
//! schema documented in config.zig's header comment. That keeps this tool
//! free to be rebuilt/changed without any risk to the daemon, and vice
//! versa.
//!
//! Always edits all 8 possible key slots per array (deck.max_keys on the
//! daemon side); the Mini/Plus toggle here only dims the rows a Mini
//! ignores (config.zig truncates by key count on load) — it never discards
//! them, so a file with 8 slots edited in "Mini" mode keeps slots 6-7
//! intact for later Plus use.
const std = @import("std");
const c = @cImport(@cInclude("gtk_flat.h"));

const max_rows = 8;

fn zPathFromHome(alloc: std.mem.Allocator, sub: []const u8) ![:0]u8 {
    const home = std.mem.sliceTo(std.c.getenv("HOME") orelse "/root", 0);
    return std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ home, sub }, 0);
}

// ---------------------------------------------------------------------
// On-disk schema. Slices point into the arena passed to loadDoc(), which
// tolerates any array length (0..N) — padded() below fits that to exactly
// max_rows for the UI, so a hand-edited file with fewer entries (or one
// saved by an older version of this tool) still loads cleanly.
// ---------------------------------------------------------------------

const MatrixKeyEntry = struct {
    label: []const u8 = "",
    screen: []const u8 = "",
    color: []const u8 = "000000",
    icon: []const u8 = "",
};
const SomaKeyEntry = struct {
    label: []const u8 = "",
    id: []const u8 = "",
    color: []const u8 = "000000",
    icon: []const u8 = "",
};
const MqttKeyEntry = struct {
    label: []const u8 = "",
    topic: []const u8 = "",
    payload: []const u8 = "",
    color: []const u8 = "000000",
    icon: []const u8 = "",
};

const Doc = struct {
    matrix_url: []const u8 = "http://localhost:8787",
    brightness: u8 = 80,
    font_path: []const u8 = "",
    font_size_key: u16 = 22,
    font_size_strip: u16 = 30,
    matrix_keys: []MatrixKeyEntry = &.{},
    soma_keys: []SomaKeyEntry = &.{},
    mqtt_host: []const u8 = "",
    mqtt_port: u16 = 1883,
    mqtt_user: []const u8 = "",
    mqtt_pass: []const u8 = "",
    mqtt_keys: []MqttKeyEntry = &.{},
    mqtt_intensity_topic: []const u8 = "",
    mqtt_intensity_min: u8 = 0,
    mqtt_intensity_max: u8 = 100,
};

fn loadDoc(arena: std.mem.Allocator, path: []const u8) Doc {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return .{};
    defer _ = std.os.linux.close(fd);
    var buf: [256 * 1024]u8 = undefined;
    const n = std.posix.read(fd, &buf) catch return .{};
    const parsed = std.json.parseFromSlice(Doc, arena, buf[0..n], .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        std.debug.print("config: {s} ignored: {s}\n", .{ path, @errorName(err) });
        return .{};
    };
    return parsed.value;
}

/// A single fixed-size backing array is easier to hand around than a
/// slice for the UI layer (always exactly max_rows, even for entries the
/// file didn't have — those just come out blank/default).
fn padded(comptime T: type, src: []const T) [max_rows]T {
    var out: [max_rows]T = undefined;
    for (&out, 0..) |*o, i| o.* = if (i < src.len) src[i] else .{};
    return out;
}

// ---------------------------------------------------------------------
// GTK helpers
// ---------------------------------------------------------------------

fn z(alloc: std.mem.Allocator, s: []const u8) [:0]const u8 {
    return alloc.dupeZ(u8, s) catch "";
}

fn getText(entry: ?*c.GtkWidget) []const u8 {
    const t = c.gtk_editable_get_text(@ptrCast(entry.?));
    return std.mem.span(t);
}

fn setText(entry: ?*c.GtkWidget, alloc: std.mem.Allocator, s: []const u8) void {
    c.gtk_editable_set_text(@ptrCast(entry.?), z(alloc, s));
}

fn mkEntry(alloc: std.mem.Allocator, initial: []const u8, placeholder: ?[]const u8) *c.GtkWidget {
    const e = c.gtk_entry_new().?;
    c.gtk_editable_set_text(@ptrCast(e), z(alloc, initial));
    if (placeholder) |p| c.gtk_entry_set_placeholder_text(@ptrCast(e), z(alloc, p));
    c.gtk_widget_set_hexpand(e, 1);
    return e;
}

fn mkSpin(min: f64, max: f64, step: f64, initial: f64) *c.GtkWidget {
    const s = c.gtk_spin_button_new_with_range(min, max, step).?;
    c.gtk_spin_button_set_value(@ptrCast(s), initial);
    return s;
}

fn mkLabel(alloc: std.mem.Allocator, text: []const u8) *c.GtkWidget {
    return c.gtk_label_new(z(alloc, text)).?;
}

fn hexToRgba(hex: []const u8) c.GdkRGBA {
    var rgba: c.GdkRGBA = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 };
    if (hex.len == 6) {
        const r = std.fmt.parseInt(u8, hex[0..2], 16) catch 0;
        const g = std.fmt.parseInt(u8, hex[2..4], 16) catch 0;
        const b = std.fmt.parseInt(u8, hex[4..6], 16) catch 0;
        rgba.red = @as(f32, @floatFromInt(r)) / 255.0;
        rgba.green = @as(f32, @floatFromInt(g)) / 255.0;
        rgba.blue = @as(f32, @floatFromInt(b)) / 255.0;
    }
    return rgba;
}

fn rgbaToHex(buf: []u8, rgba: *const c.GdkRGBA) []const u8 {
    const r: u8 = @intFromFloat(std.math.clamp(rgba.red, 0, 1) * 255.0);
    const g: u8 = @intFromFloat(std.math.clamp(rgba.green, 0, 1) * 255.0);
    const b: u8 = @intFromFloat(std.math.clamp(rgba.blue, 0, 1) * 255.0);
    return std.fmt.bufPrint(buf, "{x:0>2}{x:0>2}{x:0>2}", .{ r, g, b }) catch "000000";
}

fn mkColorButton(alloc: std.mem.Allocator, hex: []const u8) *c.GtkWidget {
    _ = alloc;
    const dialog = c.gtk_color_dialog_new().?;
    c.gtk_color_dialog_set_with_alpha(dialog, 0);
    const btn = c.gtk_color_dialog_button_new(dialog).?;
    var rgba = hexToRgba(hex);
    c.gtk_color_dialog_button_set_rgba(@ptrCast(btn), &rgba);
    return btn;
}

fn colorButtonHex(buf: []u8, btn: ?*c.GtkWidget) []const u8 {
    const rgba = c.gtk_color_dialog_button_get_rgba(@ptrCast(btn.?));
    return rgbaToHex(buf, rgba);
}

// File picker for icon paths, using the async GtkFileDialog (GTK4's
// current, non-deprecated API — there's no synchronous "run" call left in
// GTK4 for any dialog). The target GtkEntry travels through as user_data.
fn onIconChosen(source: ?*c.GObject, res: ?*c.GAsyncResult, user_data: ?*anyopaque) callconv(.c) void {
    const dialog: *c.GtkFileDialog = @ptrCast(@alignCast(source.?));
    const entry: *c.GtkWidget = @ptrCast(@alignCast(user_data.?));
    const file = c.gtk_file_dialog_open_finish(dialog, res, null);
    if (file == null) return;
    defer c.g_object_unref(file);
    const path = c.g_file_get_path(file);
    if (path == null) return;
    defer c.g_free(path);
    c.gtk_editable_set_text(@ptrCast(entry), path);
}

const BrowseCtx = struct { window: *c.GtkWidget, entry: *c.GtkWidget };
var browse_ctxs: std.ArrayList(*BrowseCtx) = .empty;

fn onBrowseClicked(_: ?*c.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    const ctx: *BrowseCtx = @ptrCast(@alignCast(user_data.?));
    const dialog = c.gtk_file_dialog_new().?;
    c.gtk_file_dialog_set_title(dialog, "Choose an icon image");
    const filter = c.gtk_file_filter_new().?;
    c.gtk_file_filter_set_name(filter, "Images");
    c.gtk_file_filter_add_pixbuf_formats(filter);
    const store = c.g_list_store_new(c.gtk_file_filter_get_type());
    c.g_list_store_append(store, filter);
    c.gtk_file_dialog_set_filters(dialog, @ptrCast(store));
    c.g_object_unref(store);
    c.gtk_file_dialog_open(dialog, @ptrCast(ctx.window), null, onIconChosen, ctx.entry);
}

fn mkIconRow(alloc: std.mem.Allocator, window: *c.GtkWidget, initial: []const u8) struct { box: *c.GtkWidget, entry: *c.GtkWidget } {
    const box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4).?;
    const entry = mkEntry(alloc, initial, "(none — use label text)");
    c.gtk_widget_set_size_request(entry, 220, -1);
    const browse = c.gtk_button_new_with_label("Browse…").?;
    const ctx = std.heap.page_allocator.create(BrowseCtx) catch @panic("OOM");
    ctx.* = .{ .window = window, .entry = entry };
    browse_ctxs.append(std.heap.page_allocator, ctx) catch {};
    _ = c.g_signal_connect_data(browse, "clicked", @ptrCast(&onBrowseClicked), ctx, null, 0);
    c.gtk_box_append(@ptrCast(box), entry);
    c.gtk_box_append(@ptrCast(box), browse);
    return .{ .box = box, .entry = entry };
}

fn addGridRow(grid: *c.GtkWidget, row: c_int, label: []const u8, alloc: std.mem.Allocator, widget: *c.GtkWidget) void {
    c.gtk_grid_attach(@ptrCast(grid), mkLabel(alloc, label), 0, row, 1, 1);
    c.gtk_grid_attach(@ptrCast(grid), widget, 1, row, 1, 1);
}

// ---------------------------------------------------------------------
// Key-array rows (matrix/soma/mqtt tabs)
// ---------------------------------------------------------------------

const MatrixRow = struct { label: *c.GtkWidget, screen: *c.GtkWidget, color: *c.GtkWidget, icon: *c.GtkWidget, root: *c.GtkWidget };
const SomaRow = struct { label: *c.GtkWidget, id: *c.GtkWidget, color: *c.GtkWidget, icon: *c.GtkWidget, root: *c.GtkWidget };
const MqttRow = struct { label: *c.GtkWidget, topic: *c.GtkWidget, payload: *c.GtkWidget, color: *c.GtkWidget, icon: *c.GtkWidget, root: *c.GtkWidget };

fn rowFrame(alloc: std.mem.Allocator, index: usize) *c.GtkWidget {
    const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8).?;
    c.gtk_widget_set_margin_start(row, 6);
    c.gtk_widget_set_margin_end(row, 6);
    c.gtk_widget_set_margin_top(row, 4);
    c.gtk_widget_set_margin_bottom(row, 4);
    var idx_buf: [8]u8 = undefined;
    const idx_s = std.fmt.bufPrint(&idx_buf, "{d}", .{index}) catch "?";
    const idx_label = mkLabel(alloc, idx_s);
    c.gtk_widget_set_size_request(idx_label, 18, -1);
    c.gtk_box_append(@ptrCast(row), idx_label);
    return row;
}

fn buildMatrixTab(alloc: std.mem.Allocator, window: *c.GtkWidget, entries: [max_rows]MatrixKeyEntry, rows: *[max_rows]MatrixRow) *c.GtkWidget {
    const list = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2).?;
    for (0..max_rows) |i| {
        const e = entries[i];
        const row = rowFrame(alloc, i);
        const label = mkEntry(alloc, e.label, "label");
        c.gtk_widget_set_size_request(label, 90, -1);
        const screen = mkEntry(alloc, e.screen, "matrix screen name");
        const color = mkColorButton(alloc, e.color);
        const icon = mkIconRow(alloc, window, e.icon);
        c.gtk_box_append(@ptrCast(row), label);
        c.gtk_box_append(@ptrCast(row), screen);
        c.gtk_box_append(@ptrCast(row), color);
        c.gtk_box_append(@ptrCast(row), icon.box);
        c.gtk_box_append(@ptrCast(list), row);
        rows[i] = .{ .label = label, .screen = screen, .color = color, .icon = icon.entry, .root = row };
    }
    return list;
}

fn buildSomaTab(alloc: std.mem.Allocator, window: *c.GtkWidget, entries: [max_rows]SomaKeyEntry, rows: *[max_rows]SomaRow) *c.GtkWidget {
    const list = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2).?;
    for (0..max_rows) |i| {
        const e = entries[i];
        const row = rowFrame(alloc, i);
        const label = mkEntry(alloc, e.label, "label");
        c.gtk_widget_set_size_request(label, 90, -1);
        const id = mkEntry(alloc, e.id, "SomaFM id, or viz/stop");
        const color = mkColorButton(alloc, e.color);
        const icon = mkIconRow(alloc, window, e.icon);
        c.gtk_box_append(@ptrCast(row), label);
        c.gtk_box_append(@ptrCast(row), id);
        c.gtk_box_append(@ptrCast(row), color);
        c.gtk_box_append(@ptrCast(row), icon.box);
        c.gtk_box_append(@ptrCast(list), row);
        rows[i] = .{ .label = label, .id = id, .color = color, .icon = icon.entry, .root = row };
    }
    return list;
}

fn buildMqttTab(alloc: std.mem.Allocator, window: *c.GtkWidget, entries: [max_rows]MqttKeyEntry, rows: *[max_rows]MqttRow) *c.GtkWidget {
    const list = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2).?;
    for (0..max_rows) |i| {
        const e = entries[i];
        const row = rowFrame(alloc, i);
        const label = mkEntry(alloc, e.label, "label");
        c.gtk_widget_set_size_request(label, 80, -1);
        const topic = mkEntry(alloc, e.topic, "mqtt topic (empty = disabled)");
        const payload = mkEntry(alloc, e.payload, "payload");
        c.gtk_widget_set_size_request(payload, 80, -1);
        const color = mkColorButton(alloc, e.color);
        const icon = mkIconRow(alloc, window, e.icon);
        c.gtk_box_append(@ptrCast(row), label);
        c.gtk_box_append(@ptrCast(row), topic);
        c.gtk_box_append(@ptrCast(row), payload);
        c.gtk_box_append(@ptrCast(row), color);
        c.gtk_box_append(@ptrCast(row), icon.box);
        c.gtk_box_append(@ptrCast(list), row);
        rows[i] = .{ .label = label, .topic = topic, .payload = payload, .color = color, .icon = icon.entry, .root = row };
    }
    return list;
}

fn setRowsSensitive(comptime T: type, rows: *const [max_rows]T, active_count: usize) void {
    for (rows, 0..) |*r, i| c.gtk_widget_set_sensitive(r.root, if (i < active_count) 1 else 0);
}

// ---------------------------------------------------------------------
// App state + wiring
// ---------------------------------------------------------------------

const General = struct {
    matrix_url: *c.GtkWidget,
    brightness: *c.GtkWidget,
    font_path: *c.GtkWidget,
    font_size_key: *c.GtkWidget,
    font_size_strip: *c.GtkWidget,
    mqtt_host: *c.GtkWidget,
    mqtt_port: *c.GtkWidget,
    mqtt_user: *c.GtkWidget,
    mqtt_pass: *c.GtkWidget,
    mqtt_intensity_topic: *c.GtkWidget,
    mqtt_intensity_min: *c.GtkWidget,
    mqtt_intensity_max: *c.GtkWidget,
};

const App = struct {
    path_buf: [512]u8 = undefined,
    path: []const u8 = "",
    window: *c.GtkWidget = undefined,
    status: *c.GtkWidget = undefined,
    model_mini: *c.GtkWidget = undefined,
    general: General = undefined,
    matrix_rows: [max_rows]MatrixRow = undefined,
    soma_rows: [max_rows]SomaRow = undefined,
    mqtt_rows: [max_rows]MqttRow = undefined,
};

var app_state: App = undefined;

fn onModelToggled(_: ?*c.GtkToggleButton, _: ?*anyopaque) callconv(.c) void {
    const mini = c.gtk_toggle_button_get_active(@ptrCast(app_state.model_mini)) != 0;
    const n: usize = if (mini) 6 else 8;
    setRowsSensitive(MatrixRow, &app_state.matrix_rows, n);
    setRowsSensitive(SomaRow, &app_state.soma_rows, n);
    setRowsSensitive(MqttRow, &app_state.mqtt_rows, n);
}

fn setStatus(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(alloc, fmt, args) catch return;
    c.gtk_label_set_text(@ptrCast(app_state.status), z(alloc, s));
}

fn buildDocFromUi(alloc: std.mem.Allocator) Doc {
    var doc: Doc = .{};
    doc.matrix_url = getText(app_state.general.matrix_url);
    doc.brightness = @intFromFloat(c.gtk_spin_button_get_value(@ptrCast(app_state.general.brightness)));
    doc.font_path = getText(app_state.general.font_path);
    doc.font_size_key = @intFromFloat(c.gtk_spin_button_get_value(@ptrCast(app_state.general.font_size_key)));
    doc.font_size_strip = @intFromFloat(c.gtk_spin_button_get_value(@ptrCast(app_state.general.font_size_strip)));
    doc.mqtt_host = getText(app_state.general.mqtt_host);
    doc.mqtt_port = @intFromFloat(c.gtk_spin_button_get_value(@ptrCast(app_state.general.mqtt_port)));
    doc.mqtt_user = getText(app_state.general.mqtt_user);
    doc.mqtt_pass = getText(app_state.general.mqtt_pass);
    doc.mqtt_intensity_topic = getText(app_state.general.mqtt_intensity_topic);
    doc.mqtt_intensity_min = @intFromFloat(c.gtk_spin_button_get_value(@ptrCast(app_state.general.mqtt_intensity_min)));
    doc.mqtt_intensity_max = @intFromFloat(c.gtk_spin_button_get_value(@ptrCast(app_state.general.mqtt_intensity_max)));

    var mk = alloc.alloc(MatrixKeyEntry, max_rows) catch @panic("OOM");
    for (&app_state.matrix_rows, 0..) |*r, i| {
        var cbuf: [8]u8 = undefined;
        mk[i] = .{ .label = getText(r.label), .screen = getText(r.screen), .color = alloc.dupe(u8, colorButtonHex(&cbuf, r.color)) catch "000000", .icon = getText(r.icon) };
    }
    doc.matrix_keys = mk;

    var sk = alloc.alloc(SomaKeyEntry, max_rows) catch @panic("OOM");
    for (&app_state.soma_rows, 0..) |*r, i| {
        var cbuf: [8]u8 = undefined;
        sk[i] = .{ .label = getText(r.label), .id = getText(r.id), .color = alloc.dupe(u8, colorButtonHex(&cbuf, r.color)) catch "000000", .icon = getText(r.icon) };
    }
    doc.soma_keys = sk;

    var qk = alloc.alloc(MqttKeyEntry, max_rows) catch @panic("OOM");
    for (&app_state.mqtt_rows, 0..) |*r, i| {
        var cbuf: [8]u8 = undefined;
        qk[i] = .{ .label = getText(r.label), .topic = getText(r.topic), .payload = getText(r.payload), .color = alloc.dupe(u8, colorButtonHex(&cbuf, r.color)) catch "000000", .icon = getText(r.icon) };
    }
    doc.mqtt_keys = qk;

    return doc;
}

fn onSaveClicked(_: ?*c.GtkButton, _: ?*anyopaque) callconv(.c) void {
    var arena_inst = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();

    const doc = buildDocFromUi(alloc);

    var out: std.Io.Writer.Allocating = .init(alloc);
    std.json.Stringify.value(doc, .{ .whitespace = .indent_2 }, &out.writer) catch {
        setStatus(alloc, "save failed: couldn't build JSON", .{});
        return;
    };

    // Keep one rotating backup of whatever was there before we clobber it.
    if (std.posix.openat(std.posix.AT.FDCWD, app_state.path, .{ .ACCMODE = .RDONLY }, 0)) |old_fd| {
        var old_buf: [256 * 1024]u8 = undefined;
        const old_n = std.posix.read(old_fd, &old_buf) catch 0;
        _ = std.os.linux.close(old_fd);
        if (old_n > 0) {
            const bak_path = std.fmt.allocPrint(alloc, "{s}.bak", .{app_state.path}) catch app_state.path;
            if (std.posix.openat(std.posix.AT.FDCWD, bak_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644)) |bak_fd| {
                _ = std.os.linux.write(bak_fd, old_buf[0..old_n].ptr, old_n);
                _ = std.os.linux.close(bak_fd);
            } else |_| {}
        }
    } else |_| {}

    const fd = std.posix.openat(std.posix.AT.FDCWD, app_state.path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch {
        setStatus(alloc, "save failed: couldn't open {s}", .{app_state.path});
        return;
    };
    defer _ = std.os.linux.close(fd);
    const written = out.written();
    _ = std.os.linux.write(fd, written.ptr, written.len);
    setStatus(alloc, "saved {s}", .{app_state.path});
}

fn reload(alloc: std.mem.Allocator) void {
    const doc = loadDoc(alloc, app_state.path);
    setText(app_state.general.matrix_url, alloc, doc.matrix_url);
    c.gtk_spin_button_set_value(@ptrCast(app_state.general.brightness), @floatFromInt(doc.brightness));
    setText(app_state.general.font_path, alloc, doc.font_path);
    c.gtk_spin_button_set_value(@ptrCast(app_state.general.font_size_key), @floatFromInt(doc.font_size_key));
    c.gtk_spin_button_set_value(@ptrCast(app_state.general.font_size_strip), @floatFromInt(doc.font_size_strip));
    setText(app_state.general.mqtt_host, alloc, doc.mqtt_host);
    c.gtk_spin_button_set_value(@ptrCast(app_state.general.mqtt_port), @floatFromInt(doc.mqtt_port));
    setText(app_state.general.mqtt_user, alloc, doc.mqtt_user);
    setText(app_state.general.mqtt_pass, alloc, doc.mqtt_pass);
    setText(app_state.general.mqtt_intensity_topic, alloc, doc.mqtt_intensity_topic);
    c.gtk_spin_button_set_value(@ptrCast(app_state.general.mqtt_intensity_min), @floatFromInt(doc.mqtt_intensity_min));
    c.gtk_spin_button_set_value(@ptrCast(app_state.general.mqtt_intensity_max), @floatFromInt(doc.mqtt_intensity_max));

    const mk = padded(MatrixKeyEntry, doc.matrix_keys);
    for (&app_state.matrix_rows, 0..) |*r, i| {
        setText(r.label, alloc, mk[i].label);
        setText(r.screen, alloc, mk[i].screen);
        var rgba = hexToRgba(mk[i].color);
        c.gtk_color_dialog_button_set_rgba(@ptrCast(r.color), &rgba);
        setText(r.icon, alloc, mk[i].icon);
    }
    const sk = padded(SomaKeyEntry, doc.soma_keys);
    for (&app_state.soma_rows, 0..) |*r, i| {
        setText(r.label, alloc, sk[i].label);
        setText(r.id, alloc, sk[i].id);
        var rgba = hexToRgba(sk[i].color);
        c.gtk_color_dialog_button_set_rgba(@ptrCast(r.color), &rgba);
        setText(r.icon, alloc, sk[i].icon);
    }
    const qk = padded(MqttKeyEntry, doc.mqtt_keys);
    for (&app_state.mqtt_rows, 0..) |*r, i| {
        setText(r.label, alloc, qk[i].label);
        setText(r.topic, alloc, qk[i].topic);
        setText(r.payload, alloc, qk[i].payload);
        var rgba = hexToRgba(qk[i].color);
        c.gtk_color_dialog_button_set_rgba(@ptrCast(r.color), &rgba);
        setText(r.icon, alloc, qk[i].icon);
    }
    setStatus(alloc, "loaded {s}", .{app_state.path});
}

fn onReloadClicked(_: ?*c.GtkButton, _: ?*anyopaque) callconv(.c) void {
    var arena_inst = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_inst.deinit();
    reload(arena_inst.allocator());
}

fn activate(gtk_app: ?*c.GtkApplication, _: ?*anyopaque) callconv(.c) void {
    var arena_inst = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();

    const window = c.gtk_application_window_new(gtk_app).?;
    app_state.window = window;
    c.gtk_window_set_title(@ptrCast(window), "deckd config");
    c.gtk_window_set_default_size(@ptrCast(window), 900, 640);

    const header = c.gtk_header_bar_new().?;
    c.gtk_window_set_titlebar(@ptrCast(window), header);

    const model_box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0).?;
    c.gtk_widget_add_css_class(model_box, "linked");
    const mini_btn = c.gtk_toggle_button_new_with_label("Mini (6 keys)").?;
    const plus_btn = c.gtk_toggle_button_new_with_label("Plus (8 keys)").?;
    c.gtk_toggle_button_set_group(@ptrCast(plus_btn), @ptrCast(mini_btn));
    c.gtk_toggle_button_set_active(@ptrCast(mini_btn), 1);
    app_state.model_mini = mini_btn;
    c.gtk_box_append(@ptrCast(model_box), mini_btn);
    c.gtk_box_append(@ptrCast(model_box), plus_btn);
    c.gtk_header_bar_pack_start(@ptrCast(header), model_box);
    _ = c.g_signal_connect_data(mini_btn, "toggled", @ptrCast(&onModelToggled), null, null, 0);
    _ = c.g_signal_connect_data(plus_btn, "toggled", @ptrCast(&onModelToggled), null, null, 0);

    const reload_btn = c.gtk_button_new_with_label("Reload").?;
    _ = c.g_signal_connect_data(reload_btn, "clicked", @ptrCast(&onReloadClicked), null, null, 0);
    c.gtk_header_bar_pack_start(@ptrCast(header), reload_btn);

    const save_btn = c.gtk_button_new_with_label("Save").?;
    c.gtk_widget_add_css_class(save_btn, "suggested-action");
    _ = c.g_signal_connect_data(save_btn, "clicked", @ptrCast(&onSaveClicked), null, null, 0);
    c.gtk_header_bar_pack_end(@ptrCast(header), save_btn);

    const root = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0).?;
    c.gtk_window_set_child(@ptrCast(window), root);

    const notebook = c.gtk_notebook_new().?;
    c.gtk_widget_set_vexpand(notebook, 1);
    c.gtk_box_append(@ptrCast(root), notebook);

    app_state.status = c.gtk_label_new("").?;
    c.gtk_widget_set_halign(app_state.status, c.GTK_ALIGN_START);
    c.gtk_widget_set_margin_start(app_state.status, 8);
    c.gtk_widget_set_margin_end(app_state.status, 8);
    c.gtk_widget_set_margin_top(app_state.status, 4);
    c.gtk_widget_set_margin_bottom(app_state.status, 4);
    c.gtk_box_append(@ptrCast(root), app_state.status);

    // General tab
    {
        const grid = c.gtk_grid_new().?;
        c.gtk_grid_set_row_spacing(@ptrCast(grid), 6);
        c.gtk_grid_set_column_spacing(@ptrCast(grid), 8);
        c.gtk_widget_set_margin_start(grid, 12);
        c.gtk_widget_set_margin_end(grid, 12);
        c.gtk_widget_set_margin_top(grid, 12);
        c.gtk_widget_set_margin_bottom(grid, 12);

        var row: c_int = 0;
        const g = &app_state.general;
        g.matrix_url = mkEntry(alloc, "", "http://192.168.1.109:8787");
        addGridRow(grid, row, "matrix_url", alloc, g.matrix_url);
        row += 1;
        g.brightness = mkSpin(0, 100, 1, 80);
        addGridRow(grid, row, "brightness", alloc, g.brightness);
        row += 1;
        {
            const icon = mkIconRow(alloc, window, "");
            g.font_path = icon.entry;
            addGridRow(grid, row, "font_path", alloc, icon.box);
        }
        row += 1;
        g.font_size_key = mkSpin(6, 72, 1, 22);
        addGridRow(grid, row, "font_size_key", alloc, g.font_size_key);
        row += 1;
        g.font_size_strip = mkSpin(6, 72, 1, 30);
        addGridRow(grid, row, "font_size_strip", alloc, g.font_size_strip);
        row += 1;
        g.mqtt_host = mkEntry(alloc, "", "literal IP, or \"localhost\"");
        addGridRow(grid, row, "mqtt_host", alloc, g.mqtt_host);
        row += 1;
        g.mqtt_port = mkSpin(1, 65535, 1, 1883);
        addGridRow(grid, row, "mqtt_port", alloc, g.mqtt_port);
        row += 1;
        g.mqtt_user = mkEntry(alloc, "", "");
        addGridRow(grid, row, "mqtt_user", alloc, g.mqtt_user);
        row += 1;
        g.mqtt_pass = c.gtk_password_entry_new().?;
        c.gtk_password_entry_set_show_peek_icon(@ptrCast(g.mqtt_pass), 1);
        addGridRow(grid, row, "mqtt_pass", alloc, g.mqtt_pass);
        row += 1;
        g.mqtt_intensity_topic = mkEntry(alloc, "", "e.g. office/brightness");
        addGridRow(grid, row, "mqtt_intensity_topic", alloc, g.mqtt_intensity_topic);
        row += 1;
        g.mqtt_intensity_min = mkSpin(0, 100, 1, 0);
        addGridRow(grid, row, "mqtt_intensity_min", alloc, g.mqtt_intensity_min);
        row += 1;
        g.mqtt_intensity_max = mkSpin(0, 100, 1, 100);
        addGridRow(grid, row, "mqtt_intensity_max", alloc, g.mqtt_intensity_max);

        const scroller = c.gtk_scrolled_window_new().?;
        c.gtk_scrolled_window_set_child(@ptrCast(scroller), grid);
        _ = c.gtk_notebook_append_page(@ptrCast(notebook), scroller, mkLabel(alloc, "General"));
    }

    // Key tabs: build with empty defaults now; reload() (called right
    // after present) fills them from disk.
    var empty_matrix: [max_rows]MatrixKeyEntry = undefined;
    for (&empty_matrix) |*e| e.* = .{};
    const matrix_list = buildMatrixTab(alloc, window, empty_matrix, &app_state.matrix_rows);
    const matrix_scroller = c.gtk_scrolled_window_new().?;
    c.gtk_scrolled_window_set_child(@ptrCast(matrix_scroller), matrix_list);
    _ = c.gtk_notebook_append_page(@ptrCast(notebook), matrix_scroller, mkLabel(alloc, "Matrix Keys"));

    var empty_soma: [max_rows]SomaKeyEntry = undefined;
    for (&empty_soma) |*e| e.* = .{};
    const soma_list = buildSomaTab(alloc, window, empty_soma, &app_state.soma_rows);
    const soma_scroller = c.gtk_scrolled_window_new().?;
    c.gtk_scrolled_window_set_child(@ptrCast(soma_scroller), soma_list);
    _ = c.gtk_notebook_append_page(@ptrCast(notebook), soma_scroller, mkLabel(alloc, "Soma Keys"));

    var empty_mqtt: [max_rows]MqttKeyEntry = undefined;
    for (&empty_mqtt) |*e| e.* = .{};
    const mqtt_list = buildMqttTab(alloc, window, empty_mqtt, &app_state.mqtt_rows);
    const mqtt_scroller = c.gtk_scrolled_window_new().?;
    c.gtk_scrolled_window_set_child(@ptrCast(mqtt_scroller), mqtt_list);
    _ = c.gtk_notebook_append_page(@ptrCast(notebook), mqtt_scroller, mkLabel(alloc, "MQTT Keys"));

    c.gtk_window_present(@ptrCast(window));

    reload(alloc);
    onModelToggled(null, null);
}

pub fn main() !void {
    var boot_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer boot_arena.deinit();
    const boot_alloc = boot_arena.allocator();

    app_state = .{};
    const p = try zPathFromHome(boot_alloc, ".config/deckd/config.json");
    @memcpy(app_state.path_buf[0..p.len], p);
    app_state.path = app_state.path_buf[0..p.len];

    const app = c.gtk_application_new("org.deckd.config", c.G_APPLICATION_DEFAULT_FLAGS);
    defer c.g_object_unref(app);
    _ = c.g_signal_connect_data(app, "activate", @ptrCast(&activate), null, null, 0);
    const status = c.g_application_run(@ptrCast(app), 0, null);
    std.process.exit(@intCast(status));
}
