//! "Choose App…" for the per-app visibility list: the native open dialog set up for each
//! desktop's idea of an application, and the chosen file turned into the id the
//! foreground-app tracking reports (zpui `foregroundApp`), so list entries match:
//!
//!   macOS    an `.app` bundle from /Applications → its CFBundleIdentifier (what
//!            NSRunningApplication reports), name from CFBundleDisplayName / CFBundleName
//!   Windows  an `.exe` → its file name ("Code.exe", what the process image reports),
//!            name without the extension
//!   Linux    a `.desktop` entry → StartupWMClass (the X11 WM_CLASS) or else the entry's
//!            name ("org.mozilla.firefox", the usual Wayland app_id); name from Name=
//!
//! Matching also compares names case-insensitively (visibility.zig), so an X11 class
//! like "firefox" still matches an entry whose desktop file id differs.

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const settings_mod = @import("settings.zig");

const AppEntry = settings_mod.AppEntry;

/// The dialog for this desktop.
pub fn promptOptions() zpui.platform.PathPromptOptions {
    return switch (builtin.os.tag) {
        .macos => .{ .files = true, .directories = false, .prompt = "Choose", .title = "Choose an app for typebud's list", .directory = "/Applications", .extensions = &.{"app"}, .filter_label = "Applications" },
        .windows => .{ .files = true, .directories = false, .prompt = "Choose", .title = "Choose a program for typebud's list", .directory = "C:\\Program Files", .extensions = &.{"exe"}, .filter_label = "Programs" },
        else => .{ .files = true, .directories = false, .prompt = "Choose", .title = "Choose an app for typebud's list", .directory = "/usr/share/applications", .extensions = &.{"desktop"}, .filter_label = "Applications" },
    };
}

pub const Error = error{ NotAnApp, Unreadable };

/// The list entry for the chosen file.
pub fn identify(gpa: std.mem.Allocator, io: std.Io, path: []const u8) Error!AppEntry {
    return switch (builtin.os.tag) {
        .macos => identifyBundle(path),
        .windows => fromExecutable(path),
        else => {
            if (!std.mem.endsWith(u8, path, ".desktop")) {
                // A binary picked instead of a desktop entry: its file name is the usual
                // WM_CLASS / app_id.
                return fromExecutable(path);
            }
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 * 1024)) catch return error.Unreadable;
            defer gpa.free(bytes);
            return fromDesktopEntry(bytes, basename(path));
        },
    };
}

pub fn describe(e: Error) []const u8 {
    return switch (e) {
        error.NotAnApp => "That doesn't look like an app",
        error.Unreadable => "Couldn't read that app",
    };
}

fn basename(path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |c, i| if (c == '/' or (builtin.os.tag == .windows and c == '\\')) {
        start = i + 1;
    };
    return path[start..];
}

/// An executable: id = its file name, name = without ".exe".
pub fn fromExecutable(path: []const u8) Error!AppEntry {
    const base = basename(path);
    if (base.len == 0) return error.NotAnApp;
    var stem = base;
    if (stem.len > 4 and std.ascii.eqlIgnoreCase(stem[stem.len - 4 ..], ".exe")) stem = stem[0 .. stem.len - 4];
    return .{ .id = .init(base), .name = .init(stem) };
}

/// A freedesktop entry (`[Desktop Entry]` group): id = StartupWMClass, else the file name
/// without ".desktop"; name = Name= (unlocalized), else the id.
pub fn fromDesktopEntry(bytes: []const u8, file_name: []const u8) Error!AppEntry {
    var in_group = false;
    var name: []const u8 = "";
    var wm_class: []const u8 = "";
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_group = std.mem.eql(u8, line, "[Desktop Entry]");
            continue;
        }
        if (!in_group) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "Name")) name = value;
        if (std.mem.eql(u8, key, "StartupWMClass")) wm_class = value;
    }
    var stem = file_name;
    if (std.mem.endsWith(u8, stem, ".desktop")) stem = stem[0 .. stem.len - ".desktop".len];
    const id = if (wm_class.len > 0) wm_class else stem;
    if (id.len == 0) return error.NotAnApp;
    return .{ .id = .init(id), .name = .init(if (name.len > 0) name else id) };
}

// ---- macOS: CFBundle ----------------------------------------------------------------------

const CFTypeRef = *const anyopaque;
const CFIndex = isize;
const kCFStringEncodingUTF8: u32 = 0x08000100;

const cf = if (builtin.os.tag == .macos) struct {
    extern "c" fn CFURLCreateFromFileSystemRepresentation(alloc: ?*anyopaque, buf: [*]const u8, len: CFIndex, is_dir: u8) ?CFTypeRef;
    extern "c" fn CFBundleCreate(alloc: ?*anyopaque, url: CFTypeRef) ?CFTypeRef;
    extern "c" fn CFBundleGetIdentifier(bundle: CFTypeRef) ?CFTypeRef;
    extern "c" fn CFBundleGetValueForInfoDictionaryKey(bundle: CFTypeRef, key: CFTypeRef) ?CFTypeRef;
    extern "c" fn CFStringCreateWithCString(alloc: ?*anyopaque, s: [*:0]const u8, enc: u32) ?CFTypeRef;
    extern "c" fn CFStringGetCString(s: CFTypeRef, buf: [*]u8, size: CFIndex, enc: u32) u8;
    extern "c" fn CFGetTypeID(t: CFTypeRef) usize;
    extern "c" fn CFStringGetTypeID() usize;
    extern "c" fn CFRelease(t: CFTypeRef) void;
} else struct {};

fn identifyBundle(path: []const u8) Error!AppEntry {
    if (builtin.os.tag != .macos) unreachable;
    const trimmed = std.mem.trimEnd(u8, path, "/");
    const url = cf.CFURLCreateFromFileSystemRepresentation(null, trimmed.ptr, @intCast(trimmed.len), 1) orelse return error.Unreadable;
    defer cf.CFRelease(url);
    const bundle = cf.CFBundleCreate(null, url) orelse return error.NotAnApp;
    defer cf.CFRelease(bundle);
    var id_buf: [256]u8 = undefined;
    const id = cfString(cf.CFBundleGetIdentifier(bundle), &id_buf) orelse return error.NotAnApp;
    var name_buf: [256]u8 = undefined;
    var stem = basename(trimmed);
    if (std.mem.endsWith(u8, stem, ".app")) stem = stem[0 .. stem.len - 4];
    const name = infoString(bundle, "CFBundleDisplayName", &name_buf) orelse infoString(bundle, "CFBundleName", &name_buf) orelse stem;
    return .{ .id = .init(id), .name = .init(name) };
}

fn infoString(bundle: CFTypeRef, comptime key: [:0]const u8, buf: []u8) ?[]const u8 {
    const k = cf.CFStringCreateWithCString(null, key.ptr, kCFStringEncodingUTF8) orelse return null;
    defer cf.CFRelease(k);
    const v = cfString(cf.CFBundleGetValueForInfoDictionaryKey(bundle, k), buf) orelse return null;
    return if (v.len > 0) v else null;
}

fn cfString(s: ?CFTypeRef, buf: []u8) ?[]const u8 {
    const str = s orelse return null;
    if (cf.CFGetTypeID(str) != cf.CFStringGetTypeID()) return null;
    if (cf.CFStringGetCString(str, buf.ptr, @intCast(buf.len), kCFStringEncodingUTF8) == 0) return null;
    return std.mem.sliceTo(buf, 0);
}

// ---- tests ------------------------------------------------------------------------------

test "desktop entry: StartupWMClass wins, Name is the label" {
    const e = try fromDesktopEntry(
        \\# comment
        \\[Desktop Entry]
        \\Type=Application
        \\Name=Visual Studio Code
        \\Name[de]=Visual Studio Code DE
        \\StartupWMClass=Code
        \\[Desktop Action new-window]
        \\Name=New Window
    , "code.desktop");
    try std.testing.expectEqualStrings("Code", e.id.slice());
    try std.testing.expectEqualStrings("Visual Studio Code", e.name.slice());
}

test "desktop entry: no WM class → file id" {
    const e = try fromDesktopEntry("[Desktop Entry]\r\nName = Firefox\r\nExec=firefox %u\r\n", "org.mozilla.firefox.desktop");
    try std.testing.expectEqualStrings("org.mozilla.firefox", e.id.slice());
    try std.testing.expectEqualStrings("Firefox", e.name.slice());
    const n = try fromDesktopEntry("[Desktop Entry]\n", "foot.desktop");
    try std.testing.expectEqualStrings("foot", n.name.slice());
}

test "executables" {
    const e = try fromExecutable(if (builtin.os.tag == .windows) "C:\\Program Files\\Microsoft VS Code\\Code.exe" else "/opt/apps/Code.exe");
    try std.testing.expectEqualStrings("Code.exe", e.id.slice());
    try std.testing.expectEqualStrings("Code", e.name.slice());
    try std.testing.expectError(error.NotAnApp, fromExecutable("/usr/bin/"));
}
