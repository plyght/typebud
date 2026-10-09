//! The seam between the app and the over-the-air updater (src/updates.zig drives
//! updater/). The app only calls through `Hook`; main.zig installs one with `install`.
//! Without one (tests), "Check for updates" reports that updates are unavailable.
//!
//! The status line and the System page's button come from a plain `View` through
//! `describe` / `actionFor`, so the wording is unit-tested without a network.

const std = @import("std");

pub const Status = enum { idle, checking, up_to_date, available, downloading, ready, failed, unavailable };

/// What the System page's button does (and the tray's "Check for Updates…").
pub const Action = enum {
    check,
    /// Open the GitHub releases page in the browser.
    view_releases,
    /// Install the downloaded update and restart.
    restart,

    pub fn label(a: Action) []const u8 {
        return switch (a) {
            .check => "Check Now",
            .view_releases => "View Releases",
            .restart => "Restart to Update",
        };
    }
};

/// Why an update can't be installed in place (`available` without automatic support).
pub const Manual = enum { none, package_manager, manual };

/// Everything the status line depends on.
pub const View = struct {
    /// False: this build has no update key compiled in, so it never checks.
    enabled: bool = true,
    status: Status = .idle,
    auto_check: bool = true,
    /// Running version (up_to_date) or the offered one (available / downloading / ready).
    version: []const u8 = "",
    /// Download progress 0...100.
    percent: u8 = 0,
    manual: Manual = .none,
    /// Extra detail for `failed` / `unavailable` / `manual` (may be empty).
    reason: []const u8 = "",
};

pub const disabled_text = "Automatic updates aren't enabled for this build";

/// The settings window's status line for `v`.
pub fn describe(buf: []u8, v: View) []const u8 {
    if (!v.enabled) return disabled_text;
    const r = switch (v.status) {
        .idle => if (v.auto_check) std.fmt.bufPrint(buf, "Checks for updates every few hours", .{}) else std.fmt.bufPrint(buf, "Automatic checks are off", .{}),
        .checking => std.fmt.bufPrint(buf, "Checking for updates…", .{}),
        .up_to_date => std.fmt.bufPrint(buf, "typebud {s} is up to date", .{v.version}),
        .available => switch (v.manual) {
            .none => std.fmt.bufPrint(buf, "Version {s} is available", .{v.version}),
            .package_manager => std.fmt.bufPrint(buf, "Version {s} is available from your package manager", .{v.version}),
            .manual => if (v.reason.len > 0)
                std.fmt.bufPrint(buf, "Version {s} is available; install it from the releases page ({s})", .{ v.version, v.reason })
            else
                std.fmt.bufPrint(buf, "Version {s} is available; install it from the releases page", .{v.version}),
        },
        .downloading => std.fmt.bufPrint(buf, "Downloading {s}… {d}%", .{ v.version, v.percent }),
        .ready => std.fmt.bufPrint(buf, "Version {s} is ready: restart to update (or it installs when you quit)", .{v.version}),
        .failed => if (v.reason.len > 0) std.fmt.bufPrint(buf, "Couldn't update: {s}", .{v.reason}) else std.fmt.bufPrint(buf, "Couldn't check for updates", .{}),
        .unavailable => if (v.reason.len > 0) std.fmt.bufPrint(buf, "Updates are unavailable: {s}", .{v.reason}) else std.fmt.bufPrint(buf, "Updates are unavailable", .{}),
    };
    return r catch "Updates";
}

/// The button for `v`.
pub fn actionFor(v: View) Action {
    if (!v.enabled) return .view_releases;
    return switch (v.status) {
        .ready => .restart,
        .unavailable => .view_releases,
        .available => if (v.manual == .none) .check else .view_releases,
        else => .check,
    };
}

pub const Hook = struct {
    ctx: ?*anyopaque = null,
    /// Check now; `interactive` = the user asked (show the result even when up to date).
    /// Without an update key this opens the releases page instead.
    check_now: *const fn (ctx: ?*anyopaque, interactive: bool) void,
    /// Turn periodic background checks on / off.
    set_auto_check: *const fn (ctx: ?*anyopaque, on: bool) void,
    /// Current state, for `describe` / `actionFor`.
    view: *const fn (ctx: ?*anyopaque) View,
    /// Run `actionFor(view)` (the settings button).
    run_action: *const fn (ctx: ?*anyopaque, a: Action) void,
};

var installed: ?Hook = null;

pub fn install(h: ?Hook) void {
    installed = h;
}

pub fn available() bool {
    return installed != null;
}

pub fn currentView() View {
    if (installed) |h| return h.view(h.ctx);
    return .{ .status = .unavailable, .reason = "no updater in this build" };
}

/// Whether the build checks for updates at all (the "Check Automatically" switch).
pub fn enabled() bool {
    const v = currentView();
    return v.enabled and v.status != .unavailable;
}

pub fn checkNow(interactive: bool) void {
    if (installed) |h| h.check_now(h.ctx, interactive) else std.log.info("updates: no updater linked into this build", .{});
}

pub fn setAutoCheck(on: bool) void {
    if (installed) |h| h.set_auto_check(h.ctx, on);
}

pub fn statusText(buf: []u8) []const u8 {
    return describe(buf, currentView());
}

pub fn action() Action {
    return actionFor(currentView());
}

pub fn actionLabel() []const u8 {
    return action().label();
}

/// The settings button.
pub fn runAction() void {
    const a = action();
    if (installed) |h| h.run_action(h.ctx, a);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn expectText(expected: []const u8, v: View) !void {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(expected, describe(&buf, v));
}

test "status strings" {
    try expectText("Automatic updates aren't enabled for this build", .{ .enabled = false });
    try expectText("Automatic updates aren't enabled for this build", .{ .enabled = false, .status = .failed, .reason = "x" });
    try expectText("Checks for updates every few hours", .{});
    try expectText("Automatic checks are off", .{ .auto_check = false });
    try expectText("Checking for updates…", .{ .status = .checking });
    try expectText("typebud 0.1.0 is up to date", .{ .status = .up_to_date, .version = "0.1.0" });
    try expectText("Version 0.2.0 is available", .{ .status = .available, .version = "0.2.0" });
    try expectText("Version 0.2.0 is available from your package manager", .{ .status = .available, .version = "0.2.0", .manual = .package_manager });
    try expectText("Version 0.2.0 is available; install it from the releases page (running from a disk image)", .{ .status = .available, .version = "0.2.0", .manual = .manual, .reason = "running from a disk image" });
    try expectText("Downloading 0.2.0… 42%", .{ .status = .downloading, .version = "0.2.0", .percent = 42 });
    try expectText("Version 0.2.0 is ready: restart to update (or it installs when you quit)", .{ .status = .ready, .version = "0.2.0" });
    try expectText("Couldn't check for updates", .{ .status = .failed });
    try expectText("Couldn't update: offline", .{ .status = .failed, .reason = "offline" });
    try expectText("Updates are unavailable: no state directory", .{ .status = .unavailable, .reason = "no state directory" });
}

test "status text never overflows a small buffer" {
    var buf: [8]u8 = undefined;
    _ = describe(&buf, .{ .status = .available, .version = "0.2.0", .manual = .manual, .reason = "a very long reason" });
}

test "button per state" {
    try testing.expectEqual(Action.view_releases, actionFor(.{ .enabled = false }));
    try testing.expectEqual(Action.check, actionFor(.{}));
    try testing.expectEqual(Action.check, actionFor(.{ .status = .up_to_date }));
    try testing.expectEqual(Action.check, actionFor(.{ .status = .failed }));
    try testing.expectEqual(Action.restart, actionFor(.{ .status = .ready }));
    try testing.expectEqual(Action.view_releases, actionFor(.{ .status = .available, .manual = .manual }));
    try testing.expectEqual(Action.view_releases, actionFor(.{ .status = .unavailable }));
    try testing.expectEqualStrings("View Releases", Action.view_releases.label());
    try testing.expectEqualStrings("Check Now", Action.check.label());
}

test "no hook installed" {
    install(null);
    defer install(null);
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("Updates are unavailable: no updater in this build", statusText(&buf));
    try testing.expect(!enabled());
    checkNow(true); // logs only
}
