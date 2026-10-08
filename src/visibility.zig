//! "Show everywhere / only in these apps / hide in these apps" against the foreground app.

const std = @import("std");
const settings = @import("settings.zig");

/// Whether the pet may show while `fg` (null = unknown) is in front.
pub fn allows(mode: settings.VisibilityMode, apps: []const settings.AppEntry, fg_id: ?[]const u8, fg_name: ?[]const u8) bool {
    if (mode == .everywhere) return true;
    // Unknown foreground (Wayland without foreign-toplevel, GNOME): never hide for it.
    const id = fg_id orelse return true;
    const listed = matches(apps, id, fg_name orelse "");
    return switch (mode) {
        .everywhere => true,
        .only_in => listed,
        .hide_in => !listed,
    };
}

pub fn matches(apps: []const settings.AppEntry, id: []const u8, name: []const u8) bool {
    for (apps) |a| {
        if (std.ascii.eqlIgnoreCase(a.id.slice(), id)) return true;
        if (name.len > 0 and std.ascii.eqlIgnoreCase(a.name.slice(), name)) return true;
    }
    return false;
}

test "visibility modes" {
    var s: settings.Settings = .{};
    _ = s.addApp("org.mozilla.firefox", "Firefox");
    const apps = s.appList();
    try std.testing.expect(allows(.everywhere, apps, "x", "X"));
    try std.testing.expect(allows(.only_in, apps, "org.mozilla.firefox", "Firefox"));
    try std.testing.expect(allows(.only_in, apps, "ORG.MOZILLA.FIREFOX", ""));
    try std.testing.expect(!allows(.only_in, apps, "code", "Code"));
    try std.testing.expect(!allows(.hide_in, apps, "firefox-esr", "firefox"));
    try std.testing.expect(allows(.hide_in, apps, "code", "Code"));
    try std.testing.expect(allows(.only_in, apps, null, null));
}
