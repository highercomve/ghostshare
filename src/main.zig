const std = @import("std");
const oriel = @import("oriel");
const builtin = @import("builtin");
const desktop_linux = builtin.os.tag == .linux and builtin.abi != .android;
const app = @import("oriel_app");
const updates = @import("updates.zig");
const cli = @import("cli.zig");
const android_multicast = if (builtin.abi == .android) @import("android_multicast.zig") else struct {
    pub fn acquire() void {}
    pub fn release() void {}
};

pub const std_options: std.Options = .{ .logFn = oriel.log.logFn };
extern fn ghostshare_start(directory: [*:0]const u8) ?[*:0]u8;
extern fn ghostshare_request(request: [*:0]const u8) ?[*:0]u8;
extern fn ghostshare_free(pointer: [*:0]u8) void;
extern fn ghostshare_stop() void;
extern fn ghostshare_set_device_name(name: ?[*:0]const u8) void;
extern fn ghostshare_set_event_callback(callback: ?*const fn ([*:0]const u8) callconv(.c) void) void;
extern fn ghostshare_desktop_init(application: ?*anyopaque, window: ?*anyopaque) void;
extern fn ghostshare_desktop_cleanup() void;
extern fn ghostshare_desktop_dark() c_int;
extern fn ghostshare_desktop_quit() void;
extern fn ghostshare_desktop_notify(id: [*:0]const u8, kind: [*:0]const u8, name: [*:0]const u8, pin: [*:0]const u8, text: c_int) void;
extern fn ghostshare_select_folder() ?[*:0]u8;
extern fn ghostshare_desktop_free(pointer: [*:0]u8) void;
extern fn ghostshare_open_path(path: [*:0]const u8) c_int;
var tray: ?*oriel.tray.Tray = null;
var startup_error: ?[]const u8 = null;
/// Where received files go: set by `main` before `start_engine`.
var engine_directory: [:0]const u8 = "";
var device_visible: std.atomic.Value(bool) = .init(true);

const ClipboardText = struct { text: []const u8 };
const FileSelection = struct { path: []const u8, name: []const u8, size: u64 };
fn request_json(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(json);
    const terminated = try allocator.dupeZ(u8, json);
    defer allocator.free(terminated);
    const response = ghostshare_request(terminated) orelse return error.QuickShareUnavailable;
    defer ghostshare_free(response);
    return allocator.dupe(u8, std.mem.span(response));
}
pub const Events = struct {
    system_theme: struct { dark: bool },
    tray_send: bool,
    tray_clipboard: bool,
    tray_visibility: bool,
    tray_update: bool,
    notification_error: []const u8,
    review_request: struct { id: []const u8 },
};
fn show_window() void {
    oriel.App.showWindow();
    if (oriel.App.getWindow("main")) |window| window.focus();
}
fn tray_menu(id: []const u8, checked: ?bool) void {
    if (std.mem.eql(u8, id, "visible")) {
        oriel.App.spawn(tray_set_visibility, .{checked orelse !device_visible.load(.acquire)}) catch {
            oriel.App.runOnMain({}, sync_tray_visibility);
        };
        return;
    }
    if (std.mem.eql(u8, id, "quit")) {
        request_quit();
        return;
    }
    show_window();
    if (std.mem.eql(u8, id, "updates")) oriel.App.events(Events).emit(.tray_update, true);
    if (std.mem.eql(u8, id, "clipboard")) oriel.App.events(Events).emit(.tray_clipboard, true);
    if (std.mem.eql(u8, id, "send")) oriel.App.events(Events).emit(.tray_send, true);
}
fn sync_tray_visibility(_: void) void {
    const visible = device_visible.load(.acquire);
    if (tray) |icon| icon.setChecked("visible", visible);
    oriel.App.events(Events).emit(.tray_visibility, visible);
}
fn set_visibility(allocator: std.mem.Allocator, visible: bool) ![]const u8 {
    const response = try request_json(allocator, .{ .command = "visibility", .visible = visible });
    errdefer allocator.free(response);
    const parsed = try std.json.parseFromSlice(struct { ok: bool }, allocator, response, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.ok) device_visible.store(visible, .release);
    oriel.App.runOnMain({}, sync_tray_visibility);
    return response;
}
fn tray_set_visibility(visible: bool) void {
    const allocator = std.heap.smp_allocator;
    const response = set_visibility(allocator, visible) catch {
        oriel.App.runOnMain({}, sync_tray_visibility);
        return;
    };
    defer allocator.free(response);
}
/// The name nearby devices see: the platform's device name (on Android,
/// Settings > About phone) instead of the host name, which is "localhost"
/// there. Failures leave the engine on the host name.
fn set_device_name(gpa: std.mem.Allocator) void {
    const name = oriel.system.deviceName(gpa) catch return;
    defer gpa.free(name);
    const name_z = gpa.dupeZ(u8, name) catch return;
    defer gpa.free(name_z);
    ghostshare_set_device_name(name_z);
}
/// Start the Quick Share engine; a failure it reports is kept for the page
/// (`snapshot`).
fn start_engine(gpa: std.mem.Allocator) !void {
    set_device_name(gpa);
    // Before the engine starts browsing, so its first mDNS answers get through.
    android_multicast.acquire();
    const response = ghostshare_start(engine_directory) orelse return error.QuickShareUnavailable;
    defer ghostshare_free(response);
    const result = try std.json.parseFromSlice(struct { ok: bool }, gpa, std.mem.span(response), .{ .ignore_unknown_fields = true });
    defer result.deinit();
    if (!result.value.ok) startup_error = try gpa.dupe(u8, std.mem.span(response));
}
fn setup() !void {
    // Android: oriel.system.deviceName asks the UI thread, which runs only
    // once oriel.main has started, so the engine starts here, before the
    // page's first command.
    if (builtin.abi == .android) start_engine(std.heap.smp_allocator) catch |err| {
        startup_error = std.fmt.allocPrint(std.heap.smp_allocator, "{{\"ok\":false,\"error\":\"Quick Share could not start: {s}\"}}", .{@errorName(err)}) catch null;
    };
    if (desktop_linux) ghostshare_desktop_init(oriel.App.gtk_app, oriel.App.main_window);
    tray = oriel.tray.Tray.create(std.heap.smp_allocator, .{
        .id = "dev.ghostshare.App",
        .title = "GhostShare",
        .tooltip = "Share files nearby",
        .icon = .{ .png = @import("tray_icon").bytes },
        .menu = &.{
            .{ .item = .{ .id = "show", .label = "Show GhostShare" } },
            .{ .item = .{ .id = "send", .label = "Send files…" } },
            .{ .item = .{ .id = "clipboard", .label = "Send clipboard…" } },
            .{ .check = .{ .id = "visible", .label = "Visible to nearby devices", .checked = true } },
            .separator,
            .{ .item = .{ .id = "updates", .label = "Check for updates" } },
            .separator,
            .{ .item = .{ .id = "quit", .label = "Quit GhostShare" } },
        },
        .on_menu = tray_menu,
        .on_activate = show_window,
    }) catch null;
    if (@hasDecl(oriel.notification, "onAction")) oriel.notification.onAction(notification_action);
    ghostshare_set_event_callback(transfer_event);
}
export fn ghostshare_theme_changed(dark: c_int) void {
    oriel.App.events(Events).emit(.system_theme, .{ .dark = dark != 0 });
}
export fn ghostshare_review_transfer(id: [*:0]const u8) void {
    notification_action(std.mem.span(id), null);
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
    const parsed = std.json.parseFromSlice(struct { id: []const u8, kind: []const u8, name: []const u8, pin: ?[]const u8 = null, text: bool = false }, allocator, event.bytes[0..event.len], .{}) catch return;
    const dismiss = std.mem.eql(u8, parsed.value.kind, "dismiss");
    if (desktop_linux and (dismiss or !@hasDecl(oriel.notification, "onAction"))) {
        const id = allocator.dupeZ(u8, parsed.value.id) catch return;
        const kind = allocator.dupeZ(u8, parsed.value.kind) catch return;
        const name = allocator.dupeZ(u8, parsed.value.name) catch return;
        const pin = allocator.dupeZ(u8, parsed.value.pin orelse "") catch return;
        ghostshare_desktop_notify(id, kind, name, pin, @intFromBool(parsed.value.text));
        return;
    }
    if (dismiss) return;
    const incoming = std.mem.eql(u8, parsed.value.kind, "request");
    const body = std.fmt.allocPrint(allocator, "{s}{s}{s}{s}", .{ parsed.value.name, if (incoming) (if (parsed.value.text) " wants to share text. Compare this code before accepting: " else " wants to share files. Compare this code before accepting: ") else (if (parsed.value.text) " · Text is ready to copy in GhostShare." else " · Files are ready. Open GhostShare to view them."), (if (incoming) parsed.value.pin orelse "" else ""), if (incoming and !parsed.value.text) " · Accept saves to the default folder." else "" }) catch return;
    if (@hasDecl(oriel.notification, "onAction")) {
        oriel.notification.notify(.{
            .id = parsed.value.id,
            .title = if (parsed.value.text) (if (incoming) "Incoming text" else "Text received") else (if (incoming) "Incoming files" else "Files received"),
            .body = body,
            .actions = if (incoming) (if (parsed.value.pin != null) &.{
                .{ .id = "accept", .label = "Accept" },
                .{ .id = "review", .label = "Review" },
                .{ .id = "decline", .label = "Deny" },
            } else &.{ .{ .id = "review", .label = "Review" }, .{ .id = "decline", .label = "Deny" } }) else if (parsed.value.text) &.{ .{ .id = "copy_text", .label = "Copy text" }, .{ .id = "review", .label = "Review" } } else &.{
                .{ .id = "open_file", .label = "Open file" },
                .{ .id = "open_folder", .label = "Open folder" },
            },
        }) catch {};
    } else {
        oriel.notification.notify(.{ .id = parsed.value.id, .title = if (parsed.value.text) (if (incoming) "Incoming text" else "Text received") else (if (incoming) "Incoming files" else "Files received"), .body = body }) catch {};
    }
}
const NotificationTask = struct {
    id: [256]u8,
    len: usize,
    action: enum { accept, decline, open_file, open_folder, copy_text },
};
export fn ghostshare_notification_action(id: [*:0]const u8, action: [*:0]const u8) void {
    notification_action(std.mem.span(id), std.mem.span(action));
}
fn notification_action(id: []const u8, action: ?[]const u8) void {
    if (action) |selected| {
        const kind = std.meta.stringToEnum(@FieldType(NotificationTask, "action"), selected);
        if (kind) |value| {
            if (id.len > 256) return;
            var task: NotificationTask = .{ .id = undefined, .len = id.len, .action = value };
            @memcpy(task.id[0..id.len], id);
            oriel.App.spawn(notification_task, .{task}) catch {
                show_window();
                oriel.App.events(Events).emit(.notification_error, "Could not perform notification action. Please review the transfer.");
            };
            return;
        }
    }
    show_window();
    oriel.App.events(Events).emit(.review_request, .{ .id = id });
}
fn notification_task(task: NotificationTask) void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();
    perform_notification_task(arena.allocator(), task) catch {
        oriel.App.runOnMain({}, notification_failed);
    };
}
fn perform_notification_task(allocator: std.mem.Allocator, task: NotificationTask) !void {
    const id = task.id[0..task.len];
    switch (task.action) {
        .copy_text => try Commands.copy_transfer(allocator, .{ .id = id }),
        .open_file, .open_folder => try Commands.open_transfer(allocator, .{ .id = id, .folder = task.action == .open_folder }),
        .accept, .decline => {
            const response = try Commands.decide(allocator, .{ .id = id, .accept = task.action == .accept });
            const parsed = try std.json.parseFromSlice(struct { ok: bool }, allocator, response, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            if (!parsed.value.ok) return error.RequestExpired;
        },
    }
}
fn notification_failed(_: void) void {
    show_window();
    oriel.App.events(Events).emit(.notification_error, "This notification is no longer available. Review the transfer in GhostShare.");
}
fn second_instance(args: []const []const u8) void {
    _ = args;
    show_window();
}
fn request_quit() void {
    if (desktop_linux) ghostshare_desktop_quit() else ghostshare_quit_requested();
}
export fn ghostshare_quit_requested() void {
    ghostshare_set_event_callback(null);
    oriel.App.quit(0);
}

pub const Commands = struct {
    pub const async_commands = .{ "snapshot", "select_file", "send_files", "read_clipboard", "send_text", "copy_transfer", "decide", "cancel", "visibility", "select_folder", "open_transfer", "updater_check", "updater_install", "updater_restart" };
    pub const update_info = updates.info;
    pub const updater_check = updates.check;
    pub const updater_install = updates.install;
    pub fn updater_restart(allocator: std.mem.Allocator, io: std.Io) !void {
        const response = try request_json(allocator, .{ .command = "snapshot" });
        defer allocator.free(response);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
        defer parsed.deinit();
        const data = parsed.value.object.get("data") orelse return error.QuickShareUnavailable;
        for (data.object.get("transfers").?.array.items) |transfer| {
            const state = transfer.object.get("state") orelse continue;
            if (state != .string) return error.TransfersActive;
            const terminal = [_][]const u8{ "Finished", "Rejected", "Cancelled", "Disconnected" };
            const finished = for (terminal) |name| {
                if (std.mem.eql(u8, name, state.string)) break true;
            } else false;
            if (!finished) return oriel.ipc.fail("Finish or cancel current transfers before restarting", .{});
        }
        try updates.restart(allocator, io);
    }
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
    pub fn read_clipboard(allocator: std.mem.Allocator) !ClipboardText {
        const text = try oriel.clipboard.readText(allocator);
        if (text.len > 1024 * 1024) return oriel.ipc.fail("Clipboard text exceeds 1 MB", .{});
        return .{ .text = text };
    }
    pub fn send_text(allocator: std.mem.Allocator, args: struct { address: []const u8, name: []const u8, text: []const u8 }) ![]const u8 {
        return request_json(allocator, .{ .command = "send_text", .address = args.address, .name = args.name, .text = args.text });
    }
    pub fn copy_transfer(allocator: std.mem.Allocator, args: struct { id: []const u8 }) !void {
        const response = try request_json(allocator, .{ .command = "resolve_text", .id = args.id });
        defer allocator.free(response);
        const parsed = try std.json.parseFromSlice(struct { ok: bool, data: ?[]const u8 = null, @"error": ?[]const u8 = null }, allocator, response, .{});
        defer parsed.deinit();
        if (!parsed.value.ok) return oriel.ipc.fail("{s}", .{parsed.value.@"error" orelse "Text unavailable"});
        try oriel.clipboard.writeText(parsed.value.data orelse return error.MissingText);
    }
    pub fn decide(allocator: std.mem.Allocator, args: struct { id: []const u8, accept: bool, directory: ?[]const u8 = null }) ![]const u8 {
        return request_json(allocator, .{ .command = "decide", .id = args.id, .accept = args.accept, .directory = args.directory });
    }
    pub fn select_folder(allocator: std.mem.Allocator) !?[]const u8 {
        if (!desktop_linux) return oriel.ipc.fail("Folder selection is currently supported on Linux", .{});
        const path = ghostshare_select_folder() orelse return null;
        defer ghostshare_desktop_free(path);
        return try allocator.dupe(u8, std.mem.span(path));
    }
    pub fn system_info() struct { dark: ?bool } {
        return .{ .dark = if (desktop_linux) ghostshare_desktop_dark() != 0 else null };
    }
    pub fn quit() void {
        request_quit();
    }
    pub fn open_transfer(allocator: std.mem.Allocator, args: struct { id: []const u8, index: usize = 0, folder: bool = false }) !void {
        const response = try request_json(allocator, .{ .command = "resolve_path", .id = args.id, .index = args.index, .folder = args.folder });
        defer allocator.free(response);
        const parsed = try std.json.parseFromSlice(struct { ok: bool, data: ?[]const u8 = null, @"error": ?[]const u8 = null }, allocator, response, .{});
        defer parsed.deinit();
        if (!parsed.value.ok) return oriel.ipc.fail("{s}", .{parsed.value.@"error" orelse "File unavailable"});
        const path = try allocator.dupeZ(u8, parsed.value.data orelse return error.MissingPath);
        defer allocator.free(path);
        if (desktop_linux) {
            if (ghostshare_open_path(path) == 0) return oriel.ipc.fail("Could not open this file or folder", .{});
        } else return oriel.ipc.fail("Opening files is currently supported on Linux", .{});
    }
    pub fn cancel(allocator: std.mem.Allocator, args: struct { id: []const u8 }) ![]const u8 {
        return request_json(allocator, .{ .command = "cancel", .id = args.id });
    }
    pub fn visibility(allocator: std.mem.Allocator, args: struct { visible: bool }) ![]const u8 {
        return set_visibility(allocator, args.visible);
    }
};
pub fn main(init: std.process.Init) !u8 {
    if (builtin.abi != .android) {
        const arena = init.arena.allocator();
        const all_args = try init.minimal.args.toSlice(arena);
        const argv = try arena.alloc([]const u8, all_args.len -| 1);
        for (argv, 1..) |*a, i| a.* = all_args[i];

        if (cli.isCliCommand(argv)) {
            set_device_name(init.gpa);
            return cli.run(init, argv);
        }
    }

    const directory = if (builtin.abi == .android) try std.fs.path.join(init.arena.allocator(), &.{ oriel.platform.impl.paths.externalFilesDir() orelse return error.MissingAndroidStorage, "Received" }) else "";
    engine_directory = try init.arena.allocator().dupeZ(u8, directory);
    defer android_multicast.release();
    if (builtin.abi != .android) try start_engine(init.arena.allocator());
    defer ghostshare_stop();
    defer {
        ghostshare_set_event_callback(null);
        if (@hasDecl(oriel.notification, "onAction")) oriel.notification.onAction(null);
        if (tray) |icon| icon.deinit();
        if (desktop_linux) ghostshare_desktop_cleanup();
    }
    return oriel.main(init, .{ .commands = Commands, .events = Events }, .{
        .setup = setup,
        .on_close = if (builtin.abi == .android) .quit else .hide,
        .on_second_instance = second_instance,
        .id = "dev.ghostshare.App",
        .title = "GhostShare",
        .width = 980,
        .height = 860,
        .assets = app.assets,
        .dev = app.dev,
        .deep_link_schemes = app.url_schemes,
        .permissions = app.permissions,
        .security = .{ .isolation = app.isolation },
    });
}
