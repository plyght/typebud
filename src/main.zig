//! typebud: a cozy typing companion. A small animal sits in a transparent always-on-top
//! window behind a little keyboard and types along with you.
//!
//!   typebud              run (tray / menu bar item; double-click the pet for settings)
//!   typebud --settings   also open the settings window
//!   typebud --smoke      scripted CI run: screenshots to zig-out/smoke/ (TYPEBUD_SMOKE=1)
//!   typebud --demo       ~1 minute feature tour for the demo video (TYPEBUD_DEMO=1)
//!   typebud --import-pack <folder>   import a Mechvibes / MechvibesDX / Thock pack

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const app_mod = @import("app.zig");
const clock = @import("clock.zig");
const smoke = @import("smoke.zig");
const demo = @import("demo.zig");

pub const std_options: std.Options = .{ .log_level = .info };

const Mode = enum { normal, smoke, demo };

const Launch = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    mode: Mode,
    open_settings: bool,
    tb: ?*app_mod.Typebud = null,
    exit_code: u8 = 0,
};

fn onLaunch(l: *Launch, app: *zpui.App) void {
    const scripted = l.mode != .normal;
    const tb = app_mod.Typebud.create(l.gpa, l.io, l.env, app, .{
        .open_settings = l.open_settings,
        .ephemeral = scripted,
        .audio_backend = if (l.mode == .smoke) .null else .auto,
        .scripted = scripted,
    }) catch |e| {
        std.log.err("typebud: startup failed: {t}", .{e});
        l.exit_code = 1;
        app.quit();
        return;
    };
    l.tb = tb;
    switch (l.mode) {
        .normal => tb.launch(),
        .smoke => smoke.start(tb, &l.exit_code),
        .demo => demo.start(tb, &l.exit_code),
    }
}

fn createPlatform(gpa: std.mem.Allocator, io: std.Io) !zpui.platform.Platform {
    return switch (builtin.os.tag) {
        .macos => zpui.mac_platform.create(gpa),
        .linux => zpui.linux_platform.create(gpa, .{ .io = io }),
        .windows => if (@hasDecl(zpui, "windows_platform")) zpui.windows_platform.create(gpa, .{}) else error.WindowsBackendMissing,
        else => error.Unsupported,
    };
}

pub fn main(init: std.process.Init) !void {
    // c_allocator: thread-safe (zpui tasks may free on workers) and fast.
    const gpa = std.heap.c_allocator;
    clock.init(init.io);
    const env = init.environ_map;
    var mode: Mode = .normal;
    var open_settings = false;
    if (env.get("TYPEBUD_SMOKE")) |v| if (v.len > 0 and !std.mem.eql(u8, v, "0")) {
        mode = .smoke;
    };
    if (env.get("TYPEBUD_DEMO")) |v| if (v.len > 0 and !std.mem.eql(u8, v, "0")) {
        mode = .demo;
    };
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--smoke")) mode = .smoke else if (std.mem.eql(u8, a, "--demo")) mode = .demo else if (std.mem.eql(u8, a, "--settings")) open_settings = true else if (std.mem.eql(u8, a, "--version")) {
            std.debug.print("typebud {s}\n", .{@import("build_options").version});
            return;
        } else if (std.mem.eql(u8, a, "--write-icons")) {
            const dir = args.next() orelse "packaging/icons";
            try @import("icons.zig").writeAll(gpa, init.io, dir);
            return;
        } else if (std.mem.eql(u8, a, "--import-pack")) {
            const src = args.next() orelse {
                std.debug.print("usage: typebud --import-pack <pack folder>\n", .{});
                std.process.exit(2);
            };
            const cfg = try @import("settings.zig").configDir(gpa, env);
            defer gpa.free(cfg);
            const dest = try std.fs.path.join(gpa, &.{ cfg, "packs" });
            defer gpa.free(dest);
            const id = @import("pack_import.zig").importPack(gpa, init.io, src, dest) catch |e| {
                std.debug.print("import failed: {s}\n", .{@import("pack_import.zig").describe(e)});
                std.process.exit(1);
            };
            std.debug.print("imported {s} into {s}\n", .{ id, dest });
            return;
        } else if (std.mem.startsWith(u8, a, "--typebud-updated-from=")) {} else {
            std.debug.print("usage: typebud [--settings] [--smoke] [--demo] [--version]\n", .{});
            std.process.exit(2);
        }
    }
    const plat = createPlatform(gpa, init.io) catch |e| {
        std.log.err("typebud: no platform backend: {t}", .{e});
        std.process.exit(1);
    };
    const app = try zpui.App.init(gpa, plat);
    app.quit_when_last_window_closes = false;
    var l: Launch = .{ .gpa = gpa, .io = init.io, .env = env, .mode = mode, .open_settings = open_settings };
    app.run(&l, onLaunch);
    if (l.tb) |tb| tb.destroy();
    if (l.exit_code != 0) std.process.exit(l.exit_code);
    // Windows may still hold platform resources; process exit cleans up.
    std.process.exit(0);
}

test {
    _ = @import("assets.zig");
    _ = @import("art.zig");
    _ = @import("raster.zig");
    _ = @import("legends.zig");
    _ = @import("pet_state.zig");
    _ = @import("settings.zig");
    _ = @import("sound.zig");
    _ = @import("visibility.zig");
    _ = @import("pack_import.zig");
    _ = @import("placement.zig");
}
