//! The seam between the app and the over-the-air updater (updater/, built separately).
//! The app only calls through `Hook`; whoever links the updater installs one with
//! `install`. Without one, "Check for updates" reports that updates are unavailable.

const std = @import("std");

pub const Status = enum { idle, checking, up_to_date, available, downloading, ready, failed, unavailable };

pub const Hook = struct {
    ctx: ?*anyopaque = null,
    /// Check now; `interactive` = the user asked (show the result even when up to date).
    check_now: *const fn (ctx: ?*anyopaque, interactive: bool) void,
    /// Turn periodic background checks on / off.
    set_auto_check: *const fn (ctx: ?*anyopaque, on: bool) void,
    /// Short status line for the settings window ("Up to date", "0.2.0 available").
    status_text: *const fn (ctx: ?*anyopaque, buf: []u8) []const u8,
};

var installed: ?Hook = null;

pub fn install(h: ?Hook) void {
    installed = h;
}

pub fn available() bool {
    return installed != null;
}

pub fn checkNow(interactive: bool) void {
    if (installed) |h| h.check_now(h.ctx, interactive) else std.log.info("updates: no updater linked into this build", .{});
}

pub fn setAutoCheck(on: bool) void {
    if (installed) |h| h.set_auto_check(h.ctx, on);
}

pub fn statusText(buf: []u8) []const u8 {
    if (installed) |h| return h.status_text(h.ctx, buf);
    return "Updates are not available in this build";
}
