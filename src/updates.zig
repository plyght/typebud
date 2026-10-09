//! Drives the over-the-air updater (updater/) for the app and installs the
//! `update_hook` the settings window and tray talk to.
//!
//! Two modes, chosen by the build:
//!   * no update key compiled in (`-Dupdate-public-key` unset, the default): no
//!     `Updater` is ever created, so there is no network traffic at all. The System
//!     page says "Automatic updates aren't enabled for this build" and its button,
//!     like the tray's "Check for Updates…", opens the GitHub releases page.
//!   * a key compiled in: checks every 6 h (`Updater.msUntilNextCheck`, one-shot main
//!     thread timer, no thread in between) and on "Check Now"; a newer release is
//!     only offered if its manifest verifies against the key; it then downloads in the
//!     background, installs when the app quits, or right away with "Restart to Update".
//!
//! All state is touched on the main thread; the updater's check thread hands its
//! result over under `mutex` and wakes the main thread.

const std = @import("std");
const zpui = @import("zpui");
const updater = @import("updater");
const update_hook = @import("update_hook.zig");

pub const releases_url = "https://github.com/plyght/typebud/releases";

/// What the updates controller needs from the app (injectable for tests).
pub const Env = struct {
    dispatcher: zpui.platform.Dispatcher,
    ctx: ?*anyopaque = null,
    /// Open a URL in the user's browser.
    open_url: *const fn (ctx: ?*anyopaque, url: []const u8) void,
    /// The status changed: redraw the settings window.
    changed: *const fn (ctx: ?*anyopaque) void,
    /// Bring up the settings window's System page (interactive checks from the tray).
    show: *const fn (ctx: ?*anyopaque) void,
    /// An update was installed and the new version started: quit now.
    quit: *const fn (ctx: ?*anyopaque) void,
};

pub const Config = struct {
    current_version: []const u8,
    /// The trusted release key, from the build. Null: updates are off for this build.
    public_key: ?[32]u8 = updater.release_key.public_key,
    environ_map: ?*const std.process.Environ.Map = null,
    // Tests: keep the updater's files out of the user's directories.
    state_dir: ?[]const u8 = null,
    cache_dir: ?[]const u8 = null,
    exe_path: ?[]const u8 = null,
};

pub const Mode = enum {
    /// No key compiled in.
    disabled,
    /// A key, but the updater couldn't start (reason in `reason`).
    unavailable,
    enabled,
};

const poll_ns = 500 * std.time.ns_per_ms;

pub const Updates = struct {
    gpa: std.mem.Allocator,
    env: Env,
    cfg: Config,
    mode: Mode,
    u: ?updater.Updater = null,

    auto: bool = false,
    status: update_hook.Status = .idle,
    percent: u8 = 0,
    manual: update_hook.Manual = .none,
    version: Buf(64) = .{},
    reason: Buf(160) = .{},
    release_url: Buf(256) = .{},
    timers_armed: u32 = 0,
    polling: bool = false,
    show_result: bool = false,

    /// Written by the check thread, read on the main thread.
    mutex: std.Io.Mutex = .init,
    result: ?CheckResult = null,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, env: Env, cfg: Config) !*Updates {
        const self = try gpa.create(Updates);
        self.* = .{ .gpa = gpa, .env = env, .cfg = cfg, .mode = .disabled };
        const key = cfg.public_key orelse {
            std.log.info("updates: no update key in this build; automatic updates are off", .{});
            return self;
        };
        self.u = updater.Updater.init(gpa, io, .{
            .current_version = cfg.current_version,
            .public_key = key,
            .environ_map = cfg.environ_map,
            .state_dir = cfg.state_dir,
            .cache_dir = cfg.cache_dir,
            .exe_path = cfg.exe_path,
        }) catch |e| {
            std.log.info("updates: updater unavailable: {t}", .{e});
            self.mode = .unavailable;
            self.reason.set(switch (e) {
                error.UpdateKeyNotConfigured => "this build's update key is invalid",
                error.StateDirUnknown => "no place to keep update state",
                else => @errorName(e),
            });
            return self;
        };
        self.mode = .enabled;
        self.u.?.cleanupAfterUpdate();
        return self;
    }

    pub fn destroy(self: *Updates) void {
        if (self.u) |*u| u.deinit();
        self.gpa.destroy(self);
    }

    pub fn hook(self: *Updates) update_hook.Hook {
        return .{ .ctx = self, .check_now = hookCheckNow, .set_auto_check = hookSetAuto, .view = hookView, .run_action = hookRunAction };
    }

    /// At quit: installs a downloaded update (never relaunches).
    pub fn onQuit(self: *Updates) void {
        if (self.u) |*u| u.onQuit();
    }

    pub fn view(self: *const Updates) update_hook.View {
        return .{
            .enabled = self.mode != .disabled,
            .status = if (self.mode == .unavailable) .unavailable else self.status,
            .auto_check = self.auto,
            .version = if (self.status == .up_to_date) self.cfg.current_version else self.version.slice(),
            .percent = self.percent,
            .manual = self.manual,
            .reason = self.reason.slice(),
        };
    }

    pub fn setAutoCheck(self: *Updates, on: bool) void {
        self.auto = on;
        if (self.mode != .enabled) return;
        if (on and self.timers_armed == 0) self.arm(self.u.?.msUntilNextCheck());
        self.env.changed(self.env.ctx);
    }

    pub fn checkNow(self: *Updates, interactive: bool) void {
        switch (self.mode) {
            .disabled, .unavailable => if (interactive) self.env.open_url(self.env.ctx, releases_url),
            .enabled => {
                if (interactive) {
                    self.show_result = true;
                    self.env.show(self.env.ctx);
                }
                self.startCheck();
            },
        }
    }

    pub fn runAction(self: *Updates, a: update_hook.Action) void {
        switch (a) {
            .check => self.checkNow(true),
            .view_releases => self.env.open_url(self.env.ctx, if (self.release_url.len > 0) self.release_url.slice() else releases_url),
            .restart => self.restart(),
        }
    }

    // ---- checking -------------------------------------------------------------------

    fn arm(self: *Updates, ms: u64) void {
        self.timers_armed += 1;
        // At least a second, so a clock jump can't spin the loop.
        const delay = @max(ms, 1000) * std.time.ns_per_ms;
        self.env.dispatcher.dispatchAfter(delay, .{ .ctx = self, .run = onTimer });
    }

    fn onTimer(ctx: *anyopaque) void {
        const self: *Updates = @ptrCast(@alignCast(ctx));
        self.timers_armed -= 1;
        if (self.mode != .enabled or !self.auto) return;
        // A download is pending or running: nothing to check until it's installed.
        if (self.status == .checking or self.status == .downloading or self.status == .ready) return;
        const ms = self.u.?.msUntilNextCheck();
        if (ms > 0) {
            if (self.timers_armed == 0) self.arm(ms);
            return;
        }
        self.startCheck();
    }

    fn startCheck(self: *Updates) void {
        if (self.status == .checking or self.status == .downloading or self.status == .ready) return;
        self.status = .checking;
        self.reason.set("");
        self.env.changed(self.env.ctx);
        self.u.?.checkInBackground(self, onCheckResult) catch |e| self.finishCheck(.{ .err = e });
    }

    const CheckResult = struct {
        err: ?anyerror = null,
        available: bool = false,
        version: Buf(64) = .{},
        release_url: Buf(256) = .{},
        manual: update_hook.Manual = .none,
        reason: Buf(160) = .{},
    };

    /// On the updater's check thread: copy what we need (the status slices die with
    /// the next check) and wake the main thread.
    fn onCheckResult(ctx: ?*anyopaque, result: anyerror!updater.Status) void {
        const self: *Updates = @ptrCast(@alignCast(ctx.?));
        var r: CheckResult = .{};
        if (result) |st| switch (st) {
            .up_to_date => {},
            .available => |a| {
                r.available = true;
                r.version.set(a.version);
                r.release_url.set(a.release_url);
                switch (a.support) {
                    .automatic => {},
                    .managed_by_package_manager => r.manual = .package_manager,
                    .needs_manual_update => |why| {
                        r.manual = .manual;
                        r.reason.set(why);
                    },
                }
            },
        } else |e| r.err = e;
        self.mutex.lockUncancelable(self.u.?.io);
        self.result = r;
        self.mutex.unlock(self.u.?.io);
        self.env.dispatcher.dispatchOnMainThread(.{ .ctx = self, .run = onCheckDoneMain }, .low);
    }

    fn onCheckDoneMain(ctx: *anyopaque) void {
        const self: *Updates = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.u.?.io);
        const r = self.result;
        self.result = null;
        self.mutex.unlock(self.u.?.io);
        if (r) |res| self.finishCheck(res);
    }

    fn finishCheck(self: *Updates, r: CheckResult) void {
        defer {
            if (self.auto and self.timers_armed == 0 and self.status != .downloading and self.status != .ready)
                self.arm(self.u.?.msUntilNextCheck());
            self.show_result = false;
            self.env.changed(self.env.ctx);
        }
        if (r.err) |e| {
            std.log.warn("updates: check failed: {t}", .{e});
            self.status = .failed;
            self.reason.set(describeError(e));
            return;
        }
        if (!r.available) {
            self.status = .up_to_date;
            return;
        }
        self.version.set(r.version.slice());
        self.release_url.set(r.release_url.slice());
        self.manual = r.manual;
        self.reason.set(r.reason.slice());
        std.log.info("updates: {s} available", .{r.version.slice()});
        if (r.manual != .none) {
            self.status = .available;
            return;
        }
        self.u.?.download(.{}) catch |e| {
            self.status = .failed;
            self.reason.set(describeError(e));
            return;
        };
        self.status = .downloading;
        self.percent = 0;
        self.startPolling();
    }

    // ---- downloading ----------------------------------------------------------------

    fn startPolling(self: *Updates) void {
        if (self.polling) return;
        self.polling = true;
        self.env.dispatcher.dispatchAfter(poll_ns, .{ .ctx = self, .run = onPoll });
    }

    fn onPoll(ctx: *anyopaque) void {
        const self: *Updates = @ptrCast(@alignCast(ctx));
        self.polling = false;
        const st = self.u.?.downloadState();
        switch (st.phase) {
            .running, .idle => {
                const pct: u8 = if (st.total == 0) 0 else @intCast(@min(100, st.downloaded * 100 / st.total));
                if (pct != self.percent) {
                    self.percent = pct;
                    self.env.changed(self.env.ctx);
                }
                self.startPolling();
                return;
            },
            .ready => {
                self.status = .ready;
                self.u.?.applyOnQuit();
                std.log.info("updates: {s} downloaded and verified; installs on quit", .{self.version.slice()});
            },
            .failed => {
                self.status = .failed;
                self.reason.set(describeError(st.err orelse error.Unexpected));
                if (self.auto and self.timers_armed == 0) self.arm(self.u.?.msUntilNextCheck());
            },
        }
        self.env.changed(self.env.ctx);
    }

    fn restart(self: *Updates) void {
        if (self.mode != .enabled or self.status != .ready) return;
        const r = self.u.?.applyAndRelaunch() catch |e| {
            std.log.warn("updates: install failed: {t}", .{e});
            self.status = .failed;
            self.reason.set(describeError(e));
            self.env.changed(self.env.ctx);
            return;
        };
        switch (r) {
            .relaunched => self.env.quit(self.env.ctx),
            .installed => {
                self.status = .failed;
                self.reason.set("installed; quit and reopen typebud to finish");
                self.env.changed(self.env.ctx);
            },
        }
    }

    // ---- hook trampolines -----------------------------------------------------------

    fn cast(ctx: ?*anyopaque) *Updates {
        return @ptrCast(@alignCast(ctx.?));
    }
    fn hookCheckNow(ctx: ?*anyopaque, interactive: bool) void {
        cast(ctx).checkNow(interactive);
    }
    fn hookSetAuto(ctx: ?*anyopaque, on: bool) void {
        cast(ctx).setAutoCheck(on);
    }
    fn hookView(ctx: ?*anyopaque) update_hook.View {
        return cast(ctx).view();
    }
    fn hookRunAction(ctx: ?*anyopaque, a: update_hook.Action) void {
        cast(ctx).runAction(a);
    }
};

/// A short, user-facing reason for an updater error.
pub fn describeError(e: anyerror) []const u8 {
    return switch (e) {
        error.RateLimited => "GitHub's rate limit; try again later",
        error.SignatureInvalid, error.SignatureMalformed => "the release's signature didn't verify",
        error.ChecksumMismatch => "the download was damaged; it will be fetched again",
        error.NeedsManualUpdate, error.NotSupportedForThisInstall => "this copy can't update itself; use the releases page",
        error.DownloadInProgress => "a download is already running",
        error.HttpStatus => "GitHub returned an error",
        else => "offline or GitHub is unreachable",
    };
}

fn Buf(comptime n: usize) type {
    return struct {
        bytes: [n]u8 = undefined,
        len: usize = 0,
        pub fn set(b: *@This(), s: []const u8) void {
            const k = @min(s.len, n);
            @memcpy(b.bytes[0..k], s[0..k]);
            b.len = k;
        }
        pub fn slice(b: *const @This()) []const u8 {
            return b.bytes[0..b.len];
        }
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// A dispatcher that records timers instead of running them, and a fake app.
const Fake = struct {
    after_calls: u32 = 0,
    main_calls: u32 = 0,
    opened: ?[]const u8 = null,
    changed: u32 = 0,
    shown: u32 = 0,

    const vtable: zpui.platform.Dispatcher.VTable = .{
        .isMainThread = isMain,
        .dispatch = dispatch,
        .dispatchOnMainThread = toMain,
        .dispatchAfter = after,
        .now = now,
    };
    fn isMain(_: *anyopaque) bool {
        return true;
    }
    fn dispatch(_: *anyopaque, _: zpui.platform.Runnable, _: zpui.platform.Priority) void {}
    fn toMain(p: *anyopaque, _: zpui.platform.Runnable, _: zpui.platform.Priority) void {
        const f: *Fake = @ptrCast(@alignCast(p));
        f.main_calls += 1;
    }
    fn after(p: *anyopaque, _: u64, _: zpui.platform.Runnable) void {
        const f: *Fake = @ptrCast(@alignCast(p));
        f.after_calls += 1;
    }
    fn now(_: *anyopaque) u64 {
        return 0;
    }
    fn openUrl(ctx: ?*anyopaque, url: []const u8) void {
        const f: *Fake = @ptrCast(@alignCast(ctx.?));
        f.opened = url;
    }
    fn onChanged(ctx: ?*anyopaque) void {
        const f: *Fake = @ptrCast(@alignCast(ctx.?));
        f.changed += 1;
    }
    fn onShow(ctx: ?*anyopaque) void {
        const f: *Fake = @ptrCast(@alignCast(ctx.?));
        f.shown += 1;
    }
    fn onQuit(_: ?*anyopaque) void {}

    fn env(f: *Fake) Env {
        return .{ .dispatcher = .{ .ptr = f, .vtable = &vtable }, .ctx = f, .open_url = openUrl, .changed = onChanged, .show = onShow, .quit = onQuit };
    }
};

// updater/src/test_keys.zig's public key (TEST ONLY; its private half is public).
const test_public_key = updater.release_key.parseHex("fb1d12a15e0f6d90f4ab2dfda78deee665b0d47276639977e9c29c8570c45f09").?;

test "no key compiled in: updater disabled, no network" {
    var fake: Fake = .{};
    const up = try Updates.create(testing.allocator, testing.io, fake.env(), .{ .current_version = "0.1.0", .public_key = null });
    defer up.destroy();
    try testing.expectEqual(Mode.disabled, up.mode);
    // No Updater exists, so nothing can open a connection.
    try testing.expect(up.u == null);

    up.setAutoCheck(true);
    try testing.expectEqual(@as(u32, 0), fake.after_calls); // no check timer
    up.checkNow(false); // a scheduled check does nothing
    try testing.expect(fake.opened == null);
    up.checkNow(true); // "Check for Updates…" opens the releases page instead
    try testing.expectEqualStrings(releases_url, fake.opened.?);
    try testing.expectEqual(@as(u32, 0), fake.after_calls);
    try testing.expectEqual(@as(u32, 0), fake.main_calls);

    update_hook.install(up.hook());
    defer update_hook.install(null);
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("Automatic updates aren't enabled for this build", update_hook.statusText(&buf));
    try testing.expectEqualStrings("View Releases", update_hook.actionLabel());
    try testing.expect(!update_hook.enabled());
    fake.opened = null;
    update_hook.runAction();
    try testing.expectEqualStrings(releases_url, fake.opened.?);
}

test "key compiled in: updater enabled, checks scheduled" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&pb, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var sb: [std.fs.max_path_bytes]u8 = undefined;
    var cb: [std.fs.max_path_bytes]u8 = undefined;
    var fake: Fake = .{};
    const up = try Updates.create(testing.allocator, testing.io, fake.env(), .{
        .current_version = "0.1.0",
        .public_key = test_public_key,
        .state_dir = try std.fmt.bufPrint(&sb, "{s}/state", .{root}),
        .cache_dir = try std.fmt.bufPrint(&cb, "{s}/cache", .{root}),
        .exe_path = "/opt/typebud-test/typebud",
    });
    defer up.destroy();
    try testing.expectEqual(Mode.enabled, up.mode);
    try testing.expect(up.u != null);

    // Turning automatic checks on arms one timer on the app's loop; it isn't run
    // here, so the test stays offline.
    up.setAutoCheck(true);
    try testing.expectEqual(@as(u32, 1), fake.after_calls);
    up.setAutoCheck(true);
    try testing.expectEqual(@as(u32, 1), fake.after_calls);

    update_hook.install(up.hook());
    defer update_hook.install(null);
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("Checks for updates every few hours", update_hook.statusText(&buf));
    try testing.expectEqualStrings("Check Now", update_hook.actionLabel());
    try testing.expect(update_hook.enabled());
    up.setAutoCheck(false);
    try testing.expectEqualStrings("Automatic checks are off", update_hook.statusText(&buf));
}

test "an invalid compiled-in key leaves updates unavailable" {
    var fake: Fake = .{};
    const up = try Updates.create(testing.allocator, testing.io, fake.env(), .{ .current_version = "0.1.0", .public_key = @splat(0) });
    defer up.destroy();
    try testing.expectEqual(Mode.unavailable, up.mode);
    up.setAutoCheck(true);
    try testing.expectEqual(@as(u32, 0), fake.after_calls);
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("Updates are unavailable: this build's update key is invalid", update_hook.describe(&buf, up.view()));
    try testing.expectEqual(update_hook.Action.view_releases, update_hook.actionFor(up.view()));
}

test describeError {
    try testing.expectEqualStrings("the release's signature didn't verify", describeError(error.SignatureInvalid));
    try testing.expectEqualStrings("offline or GitHub is unreachable", describeError(error.ConnectionRefused));
}
