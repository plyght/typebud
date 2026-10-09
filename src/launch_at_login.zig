//! Launch at Login: the settings switch shows what the OS will actually do, not only what
//! typebud last wrote. An installer task ("Launch typebud when I sign in"), the user
//! (System Settings > Login Items, Task Manager > Startup apps, a deleted autostart file)
//! or the OS can change the registration behind typebud's back; when the platform can
//! report the real state it wins over the saved setting. Reading never writes the
//! registration — only flipping the switch does (`Typebud.applyLaunchAtLogin`).

const std = @import("std");

pub const Sync = enum {
    /// The setting already matched the OS.
    unchanged,
    /// The setting was changed to the OS's state.
    updated,
    /// The platform cannot tell: the setting is left as is.
    unsupported,
};

/// Reads the real state from `os` (anything with `launchAtLoginEnabled(id) anyerror!bool`,
/// e.g. `*zpui.App`) and adopts it into `setting` when they differ. A failed query leaves
/// `setting` alone and returns the error.
pub fn syncFromOs(os: anytype, id: []const u8, setting: *bool) anyerror!Sync {
    const real = os.launchAtLoginEnabled(id) catch |e| {
        if (e == error.Unsupported) return .unsupported;
        return e;
    };
    if (real == setting.*) return .unchanged;
    setting.* = real;
    return .updated;
}

const testing = std.testing;

const FakePlatform = struct {
    /// Null = the backend has no query.
    registered: ?bool,
    fail: bool = false,
    queries: usize = 0,
    writes: usize = 0,

    pub fn launchAtLoginEnabled(self: *FakePlatform, id: []const u8) anyerror!bool {
        try testing.expectEqualStrings("typebud", id);
        self.queries += 1;
        if (self.fail) return error.AccessDenied;
        return self.registered orelse error.Unsupported;
    }
    pub fn setLaunchAtLogin(self: *FakePlatform, _: []const u8, _: []const u8, on: bool) anyerror!void {
        self.writes += 1;
        self.registered = on;
    }
};

test "installer-created registration turns the switch on without writing" {
    var os: FakePlatform = .{ .registered = true };
    var setting = false;
    try testing.expectEqual(Sync.updated, try syncFromOs(&os, "typebud", &setting));
    try testing.expect(setting);
    try testing.expectEqual(@as(usize, 0), os.writes);
    // Opening Settings again: nothing to do.
    try testing.expectEqual(Sync.unchanged, try syncFromOs(&os, "typebud", &setting));
    try testing.expectEqual(@as(usize, 2), os.queries);
}

test "registration removed outside typebud turns the switch off" {
    var os: FakePlatform = .{ .registered = false };
    var setting = true;
    try testing.expectEqual(Sync.updated, try syncFromOs(&os, "typebud", &setting));
    try testing.expect(!setting);
    try testing.expectEqual(@as(usize, 0), os.writes);
}

test "user flips the switch: the write is read back as the new state" {
    var os: FakePlatform = .{ .registered = false };
    var setting = false;
    try testing.expectEqual(Sync.unchanged, try syncFromOs(&os, "typebud", &setting));
    setting = true;
    try os.setLaunchAtLogin("typebud", "/usr/bin/typebud", setting);
    try testing.expectEqual(Sync.unchanged, try syncFromOs(&os, "typebud", &setting));
    try testing.expect(setting);
}

test "unsupported or failing query keeps the saved setting" {
    var os: FakePlatform = .{ .registered = null };
    var setting = true;
    try testing.expectEqual(Sync.unsupported, try syncFromOs(&os, "typebud", &setting));
    try testing.expect(setting);
    os = .{ .registered = false, .fail = true };
    try testing.expectError(error.AccessDenied, syncFromOs(&os, "typebud", &setting));
    try testing.expect(setting);
    try testing.expectEqual(@as(usize, 0), os.writes);
}
