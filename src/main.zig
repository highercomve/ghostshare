const std = @import("std");
const oriel = @import("oriel");
const builtin = @import("builtin");
const desktop_linux = builtin.os.tag == .linux and builtin.abi != .android;
const app = @import("oriel_app");

pub const std_options: std.Options = .{ .logFn = oriel.log.logFn };
extern fn ghostfile_start(directory: [*:0]const u8) ?[*:0]u8;
extern fn ghostfile_request(request: [*:0]const u8) ?[*:0]u8;
extern fn ghostfile_free(pointer: [*:0]u8) void;
extern fn ghostfile_stop() void;
extern fn ghostfile_set_event_callback(callback: ?*const fn ([*:0]const u8) callconv(.c) void) void;
extern fn ghostfile_desktop_init(application: ?*anyopaque, window: ?*anyopaque) void;
extern fn ghostfile_desktop_cleanup() void;
extern fn ghostfile_desktop_dark() c_int;
extern fn ghostfile_desktop_notify(id: [*:0]const u8, kind: [*:0]const u8, name: [*:0]const u8) void;
extern fn ghostfile_select_folder() ?[*:0]u8;
extern fn ghostfile_desktop_free(pointer: [*:0]u8) void;
extern fn ghostfile_open_path(path: [*:0]const u8) c_int;
var tray: ?*oriel.tray.Tray = null;
var startup_error: ?[]const u8 = null;

const FileSelection = struct { path: []const u8, name: []const u8, size: u64 };
fn request_json(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(json);
    const terminated = try allocator.dupeZ(u8, json);
    defer allocator.free(terminated);
    const response = ghostfile_request(terminated) orelse return error.QuickShareUnavailable;
    defer ghostfile_free(response);
    return allocator.dupe(u8, std.mem.span(response));
}
pub const Events = struct {
    system_theme: struct { dark: bool },
    tray_send: bool,
    review_request: struct { id: []const u8 },
};
fn show_window() void {
    oriel.App.showWindow();
    if (oriel.App.getWindow("main")) |window| window.focus();
}
fn tray_menu(id: []const u8, checked: ?bool) void {
    _ = checked;
    if (std.mem.eql(u8, id, "quit")) { oriel.App.quit(0); return; }
    show_window();
    if (std.mem.eql(u8, id, "send")) oriel.App.events(Events).emit(.tray_send, true);
}
fn setup() !void {
    if (desktop_linux) ghostfile_desktop_init(oriel.App.gtk_app, oriel.App.main_window);
    tray = oriel.tray.Tray.create(std.heap.smp_allocator, .{
        .id = "dev.ghostfile.App", .title = "GhostFile", .tooltip = "Share files nearby",
        .icon = .{ .png = app.icon_bytes },
        .menu = &.{
            .{ .item = .{ .id = "show", .label = "Show GhostFile" } },
            .{ .item = .{ .id = "send", .label = "Send files…" } },
            .separator,
            .{ .item = .{ .id = "quit", .label = "Quit GhostFile" } },
        }, .on_menu = tray_menu, .on_activate = show_window,
    }) catch null;
    if (@hasDecl(oriel.notification, "onAction")) oriel.notification.onAction(notification_action);
    ghostfile_set_event_callback(transfer_event);
}
export fn ghostfile_theme_changed(dark: c_int) void {
    oriel.App.events(Events).emit(.system_theme, .{ .dark = dark != 0 });
}
export fn ghostfile_review_transfer(id: [*:0]const u8) void {
    show_window();
    oriel.App.events(Events).emit(.review_request, .{ .id = std.mem.span(id) });
}
const NotificationEvent = struct { bytes: [4096]u8, len: usize };
fn transfer_event(json: [*:0]const u8) callconv(.c) void {
    const source = std.mem.span(json);
    if (source.len > 4096) return;
    var event: NotificationEvent = .{ .bytes = undefined, .len = source.len };
    @memcpy(event.bytes[0..source.len], source);
    oriel.App.runOnMain(event, notify_main);
}
fn notify_main(event: NotificationEvent) void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parsed = std.json.parseFromSlice(struct { id: []const u8, kind: []const u8, name: []const u8 }, allocator, event.bytes[0..event.len], .{}) catch return;
    const id = allocator.dupeZ(u8, parsed.value.id) catch return;
    const kind = allocator.dupeZ(u8, parsed.value.kind) catch return;
    const name = allocator.dupeZ(u8, parsed.value.name) catch return;
    if (desktop_linux) {
        ghostfile_desktop_notify(id, kind, name);
    } else if (!std.mem.eql(u8, parsed.value.kind, "dismiss")) {
        oriel.notification.notify(.{ .id = parsed.value.id, .title = "GhostFile", .body = if (std.mem.eql(u8, parsed.value.kind, "request")) "Incoming files. Open GhostFile to review and accept." else "Files received." }) catch {};
    }
}
fn notification_action(id: []const u8, action: ?[]const u8) void {
    _ = action;
    show_window();
    oriel.App.events(Events).emit(.review_request, .{ .id = id });
}
fn second_instance(args: []const []const u8) void { _ = args; show_window(); }

pub const Commands = struct {
    pub const async_commands = .{ "snapshot", "select_file", "send_files", "decide", "cancel", "visibility", "select_folder", "open_transfer" };
    pub fn snapshot(allocator: std.mem.Allocator) ![]const u8 {
        if (startup_error) |message| return allocator.dupe(u8, message);
        return request_json(allocator, .{ .command = "snapshot" });
    }
    pub fn select_file(allocator: std.mem.Allocator, io: std.Io) !?FileSelection {
        const path = try oriel.dialog.openFile(allocator, .{ .title = "Choose a file to share" }) orelse return null;
        errdefer allocator.free(path);
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        const stat = try file.stat(io);
        if (stat.kind != .file) return error.NotARegularFile;
        return .{ .path = path, .name = try allocator.dupe(u8, std.fs.path.basename(path)), .size = stat.size };
    }
    pub fn send_files(allocator: std.mem.Allocator, args: struct { address: []const u8, name: []const u8, paths: []const []const u8 }) ![]const u8 {
        return request_json(allocator, .{ .command = "send", .address = args.address, .name = args.name, .paths = args.paths });
    }
    pub fn decide(allocator: std.mem.Allocator, args: struct { id: []const u8, accept: bool, directory: ?[]const u8 = null }) ![]const u8 {
        return request_json(allocator, .{ .command = "decide", .id = args.id, .accept = args.accept, .directory = args.directory });
    }
    pub fn select_folder(allocator: std.mem.Allocator) !?[]const u8 {
        if (!desktop_linux) return oriel.ipc.fail("Folder selection is currently supported on Linux", .{});
        const path = ghostfile_select_folder() orelse return null;
        defer ghostfile_desktop_free(path);
        return try allocator.dupe(u8, std.mem.span(path));
    }
    pub fn system_info() struct { dark: ?bool } {
        return .{ .dark = if (desktop_linux) ghostfile_desktop_dark() != 0 else null };
    }
    pub fn quit() void { oriel.App.quit(0); }
    pub fn open_transfer(allocator: std.mem.Allocator, args: struct { id: []const u8, index: usize = 0, folder: bool = false }) !void {
        const response = try request_json(allocator, .{ .command = "resolve_path", .id = args.id, .index = args.index, .folder = args.folder });
        defer allocator.free(response);
        const parsed = try std.json.parseFromSlice(struct { ok: bool, data: ?[]const u8 = null, @"error": ?[]const u8 = null }, allocator, response, .{});
        defer parsed.deinit();
        if (!parsed.value.ok) return oriel.ipc.fail("{s}", .{parsed.value.@"error" orelse "File unavailable"});
        const path = try allocator.dupeZ(u8, parsed.value.data orelse return error.MissingPath);
        defer allocator.free(path);
        if (desktop_linux) {
            if (ghostfile_open_path(path) == 0) return oriel.ipc.fail("Could not open this file or folder", .{});
        } else return oriel.ipc.fail("Opening files is currently supported on Linux", .{});
    }
    pub fn cancel(allocator: std.mem.Allocator, args: struct { id: []const u8 }) ![]const u8 {
        return request_json(allocator, .{ .command = "cancel", .id = args.id });
    }
    pub fn visibility(allocator: std.mem.Allocator, args: struct { visible: bool }) ![]const u8 {
        return request_json(allocator, .{ .command = "visibility", .visible = args.visible });
    }
};
pub fn main(init: std.process.Init) !u8 {
    const directory = if (builtin.abi == .android) try std.fs.path.join(init.arena.allocator(), &.{ oriel.platform.impl.paths.externalFilesDir() orelse return error.MissingAndroidStorage, "Received" }) else "";
    const directory_z = try init.arena.allocator().dupeZ(u8, directory);
    const response = ghostfile_start(directory_z) orelse return error.QuickShareUnavailable;
    defer ghostfile_free(response);
    const result = try std.json.parseFromSlice(struct { ok: bool }, init.gpa, std.mem.span(response), .{ .ignore_unknown_fields = true });
    defer result.deinit();
    if (!result.value.ok) startup_error = try init.arena.allocator().dupe(u8, std.mem.span(response));
    defer ghostfile_stop();
    defer {
        ghostfile_set_event_callback(null);
        if (tray) |icon| icon.deinit();
        if (desktop_linux) ghostfile_desktop_cleanup();
    }
    return oriel.main(init, .{ .commands = Commands, .events = Events }, .{
        .setup = setup,
        .on_close = if (builtin.abi == .android) .quit else .hide,
        .on_second_instance = second_instance,
        .id = "dev.ghostfile.App",
        .title = "GhostFile",
        .width = 980,
        .height = 860,
        .assets = app.assets,
        .dev = app.dev,
        .deep_link_schemes = app.url_schemes,
        .permissions = app.permissions,
        .security = .{ .isolation = app.isolation },
    });
}
