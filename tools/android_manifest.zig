//! Adds the Android permissions GhostShare needs beyond the ones Oriel
//! declares from `oriel.addApp(.permissions)` to the generated manifest
//! (android/app/src/main/AndroidManifest.xml, written by `oriel android
//! init`, which keeps an existing manifest unless forced).
//!
//! Oriel 0.9.0 declares only the permissions of its own kinds (microphone,
//! camera, location, notifications); GhostShare's discovery also needs
//! CHANGE_WIFI_MULTICAST_STATE for the multicast lock (src/android_multicast.zig).
//! Remove this tool once Oriel can declare extra manifest permissions.
//!
//! Usage: android_manifest <AndroidManifest.xml> <permission>...
//! A missing manifest (no `oriel android init` yet) is not an error.

const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.debug.print("usage: android_manifest <AndroidManifest.xml> <permission>...\n", .{});
        return 2;
    }
    const path = args[1];
    const cwd = std.Io.Dir.cwd();
    const manifest = cwd.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer gpa.free(manifest);
    const patched = try addPermissions(gpa, manifest, args[2..]) orelse return 0;
    defer gpa.free(patched);
    try cwd.writeFile(io, .{ .sub_path = path, .data = patched });
    std.debug.print("android manifest: added GhostShare's permissions to {s}\n", .{path});
    return 0;
}

/// `manifest` with a `<uses-permission>` for each of `permissions` it lacks,
/// after its INTERNET permission (or before `<application`); null when it
/// already declares them all.
fn addPermissions(gpa: std.mem.Allocator, manifest: []const u8, permissions: []const []const u8) !?[]u8 {
    var lines: std.ArrayList(u8) = .empty;
    defer lines.deinit(gpa);
    for (permissions) |permission| {
        const name = try std.fmt.allocPrint(gpa, "android:name=\"android.permission.{s}\"", .{permission});
        defer gpa.free(name);
        if (std.mem.indexOf(u8, manifest, name) != null) continue;
        try lines.print(gpa, "    <uses-permission {s} />\n", .{name});
    }
    if (lines.items.len == 0) return null;
    const anchor = "<uses-permission android:name=\"android.permission.INTERNET\" />\n";
    const at = if (std.mem.indexOf(u8, manifest, anchor)) |i|
        i + anchor.len
    else if (std.mem.indexOf(u8, manifest, "<application")) |i|
        (std.mem.lastIndexOfScalar(u8, manifest[0..i], '\n') orelse return error.UnexpectedManifest) + 1
    else
        return error.UnexpectedManifest;
    return try std.mem.concat(gpa, u8, &.{ manifest[0..at], lines.items, manifest[at..] });
}

test addPermissions {
    const gpa = std.testing.allocator;
    const manifest =
        \\<manifest>
        \\    <uses-permission android:name="android.permission.INTERNET" />
        \\    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
        \\    <application />
        \\</manifest>
        \\
    ;
    const patched = (try addPermissions(gpa, manifest, &.{ "CHANGE_WIFI_MULTICAST_STATE", "POST_NOTIFICATIONS" })).?;
    defer gpa.free(patched);
    try std.testing.expectEqualStrings(
        \\<manifest>
        \\    <uses-permission android:name="android.permission.INTERNET" />
        \\    <uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE" />
        \\    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
        \\    <application />
        \\</manifest>
        \\
    , patched);
    try std.testing.expectEqual(null, try addPermissions(gpa, patched, &.{"CHANGE_WIFI_MULTICAST_STATE"}));

    const bare = "<manifest>\n    <application />\n</manifest>\n";
    const added = (try addPermissions(gpa, bare, &.{"CHANGE_WIFI_MULTICAST_STATE"})).?;
    defer gpa.free(added);
    try std.testing.expectEqualStrings("<manifest>\n    <uses-permission android:name=\"android.permission.CHANGE_WIFI_MULTICAST_STATE\" />\n    <application />\n</manifest>\n", added);
}
