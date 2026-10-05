//! GhostShare's settings: the name nearby devices see and the folder
//! received files go to, kept as JSON (`settings.json`) in the app's data
//! directory. An empty (or missing) value means the default: the system's
//! device name, and the platform's default download folder.

const std = @import("std");

pub const file_name = "settings.json";
/// Longest device name, in characters.
pub const max_name_chars = 64;
/// Longest device name, in UTF-8 bytes: the mDNS TXT entry that carries it
/// ("n=" and the base64 of 18 bytes plus the name) must fit in 255 bytes.
/// Only names with many 3- or 4-byte characters reach it.
pub const max_name_bytes = 170;

pub const Settings = struct {
    device_name: []const u8 = "",
    download_dir: []const u8 = "",

    /// A copy whose strings `gpa` owns (free with `deinit`).
    pub fn clone(self: Settings, gpa: std.mem.Allocator) !Settings {
        const name = try gpa.dupe(u8, self.device_name);
        errdefer gpa.free(name);
        return .{ .device_name = name, .download_dir = try gpa.dupe(u8, self.download_dir) };
    }

    pub fn deinit(self: Settings, gpa: std.mem.Allocator) void {
        gpa.free(self.device_name);
        gpa.free(self.download_dir);
    }
};

pub const NameError = error{ NameTooLong, NameNotUtf8, NameHasControlCharacters };

/// The name to save: `name` trimmed of surrounding white space; empty means
/// the system's device name. Fails for more than `max_name_chars`
/// characters (or `max_name_bytes` bytes), invalid UTF-8, or control
/// characters.
pub fn normalizeName(name: []const u8) NameError![]const u8 {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    const view = std.unicode.Utf8View.init(trimmed) catch return error.NameNotUtf8;
    var chars: usize = 0;
    var it = view.iterator();
    while (it.nextCodepoint()) |c| {
        chars += 1;
        // C0, DEL and C1 controls.
        if (c < 0x20 or (c >= 0x7f and c <= 0x9f)) return error.NameHasControlCharacters;
    }
    if (chars > max_name_chars or trimmed.len > max_name_bytes) return error.NameTooLong;
    return trimmed;
}

/// What the page shows for a `NameError`.
pub fn nameErrorMessage(err: NameError) []const u8 {
    return switch (err) {
        error.NameTooLong => "Use a shorter name (up to 64 characters)",
        error.NameNotUtf8 => "The name has characters GhostShare can't use",
        error.NameHasControlCharacters => "The name can't contain control characters",
    };
}

/// Settings from JSON text; unknown fields are ignored, and a malformed
/// document or an invalid name gives the defaults for those values.
/// `gpa` owns the strings of the result.
pub fn parse(gpa: std.mem.Allocator, json: []const u8) !Settings {
    const parsed = std.json.parseFromSlice(Settings, gpa, json, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return Settings.clone(.{}, gpa),
    };
    defer parsed.deinit();
    const name = normalizeName(parsed.value.device_name) catch "";
    return Settings.clone(.{ .device_name = name, .download_dir = std.mem.trim(u8, parsed.value.download_dir, " \t\r\n") }, gpa);
}

/// Settings saved in `dir`, or the defaults when there are none (or they
/// can't be read). `gpa` owns the strings of the result.
pub fn load(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !Settings {
    const json = dir.readFileAlloc(io, file_name, gpa, .limited(64 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return Settings.clone(.{}, gpa),
    };
    defer gpa.free(json);
    return parse(gpa, json);
}

/// Save `settings` to `dir`, replacing the file atomically (a temporary
/// file renamed over it).
pub fn save(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, settings: Settings) !void {
    const json = try std.json.Stringify.valueAlloc(gpa, settings, .{ .whitespace = .indent_2 });
    defer gpa.free(json);
    const temporary = file_name ++ ".tmp";
    try dir.writeFile(io, .{ .sub_path = temporary, .data = json });
    errdefer dir.deleteFile(io, temporary) catch {};
    try dir.rename(temporary, dir, file_name, io);
}

const testing = std.testing;

test "names are trimmed and empty means the system name" {
    try testing.expectEqualStrings("Desk", try normalizeName("  Desk\t"));
    try testing.expectEqualStrings("", try normalizeName("   "));
    try testing.expectEqualStrings("Sergio's Café ☕", try normalizeName("Sergio's Café ☕"));
}

test "names are 64 characters at most, counted as characters" {
    try testing.expectEqualStrings("a" ** 64, try normalizeName("a" ** 64));
    try testing.expectError(error.NameTooLong, normalizeName("a" ** 65));
    // 64 two-byte characters (128 bytes) are fine.
    try testing.expectEqualStrings("é" ** 64, try normalizeName("é" ** 64));
    try testing.expectError(error.NameTooLong, normalizeName("é" ** 65));
    // 56 three-byte characters (168 bytes) fit the mDNS record; 57 don't.
    try testing.expectEqualStrings("☕" ** 56, try normalizeName("☕" ** 56));
    try testing.expectError(error.NameTooLong, normalizeName("☕" ** 57));
}

test "names reject control characters and invalid UTF-8" {
    try testing.expectError(error.NameHasControlCharacters, normalizeName("a\nb"));
    try testing.expectError(error.NameHasControlCharacters, normalizeName("a\x00b"));
    try testing.expectError(error.NameHasControlCharacters, normalizeName("a\x7fb"));
    try testing.expectError(error.NameHasControlCharacters, normalizeName("a\u{85}b"));
    try testing.expectError(error.NameNotUtf8, normalizeName("a\xffb"));
}

test "parse ignores unknown fields and falls back on bad input" {
    const gpa = testing.allocator;
    const full = try parse(gpa, "{\"device_name\":\" Desk \",\"download_dir\":\"/tmp/x\",\"other\":1}");
    defer full.deinit(gpa);
    try testing.expectEqualStrings("Desk", full.device_name);
    try testing.expectEqualStrings("/tmp/x", full.download_dir);

    const partial = try parse(gpa, "{\"download_dir\":\"/tmp/y\"}");
    defer partial.deinit(gpa);
    try testing.expectEqualStrings("", partial.device_name);
    try testing.expectEqualStrings("/tmp/y", partial.download_dir);

    const malformed = try parse(gpa, "{not json");
    defer malformed.deinit(gpa);
    try testing.expectEqualStrings("", malformed.device_name);
    try testing.expectEqualStrings("", malformed.download_dir);

    const bad_name = try parse(gpa, "{\"device_name\":\"a\\nb\",\"download_dir\":\"/d\"}");
    defer bad_name.deinit(gpa);
    try testing.expectEqualStrings("", bad_name.device_name);
    try testing.expectEqualStrings("/d", bad_name.download_dir);
}

test "load gives defaults without a file, and what save wrote" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const empty = try load(gpa, io, tmp.dir);
    defer empty.deinit(gpa);
    try testing.expectEqualStrings("", empty.device_name);
    try testing.expectEqualStrings("", empty.download_dir);

    try save(gpa, io, tmp.dir, .{ .device_name = "Desk \"2\"", .download_dir = "/home/me/In" });
    const saved = try load(gpa, io, tmp.dir);
    defer saved.deinit(gpa);
    try testing.expectEqualStrings("Desk \"2\"", saved.device_name);
    try testing.expectEqualStrings("/home/me/In", saved.download_dir);

    // Saving the defaults again: an empty settings file, read as defaults.
    try save(gpa, io, tmp.dir, .{});
    const reset = try load(gpa, io, tmp.dir);
    defer reset.deinit(gpa);
    try testing.expectEqualStrings("", reset.device_name);
    try testing.expectEqualStrings("", reset.download_dir);
    // No temporary file left behind.
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, file_name ++ ".tmp", .{}));
}
