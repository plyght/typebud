//! `typebud --smoke` (TYPEBUD_SMOKE=1): the CI run. Opens the pet and settings windows,
//! drives the state machine with synthetic key events, writes screenshots to
//! zig-out/smoke/ (live pet states, every animal × vibe with accessories, each animal's
//! frame sheet, every settings section), checks that an idle (asleep) second draws no
//! frames, and exits 0 — or 1 with the failures listed.

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const art = @import("art.zig");
const app_mod = @import("app.zig");
const script = @import("script.zig");
const snapshot = @import("snapshot.zig");
const pet_view = @import("pet_view.zig");
const settings_view = @import("settings_view.zig");
const capture = @import("capture.zig");
const clock = @import("clock.zig");

const Typebud = app_mod.Typebud;
const out_dir = "zig-out/smoke";

const State = struct {
    code: *u8 = undefined,
    runner: script.Runner = undefined,
    typist: script.Typist = .{},
    snap: ?snapshot.Snapshotter = null,
    failures: u32 = 0,
    idle_frames0: u64 = 0,
    idle_cpu0: u64 = 0,
    idle_frames: u64 = 0,
    idle_cpu_ms: u64 = 0,
    awake_frames0: u64 = 0,
    report: std.ArrayList(u8) = .empty,
    section: usize = 0,
    look: usize = 0,
};
var st: State = .{};

fn note(tb: *Typebud, comptime fmt: []const u8, args: anytype) void {
    std.debug.print("smoke: " ++ fmt ++ "\n", args);
    st.report.print(tb.gpa, fmt ++ "\n", args) catch {};
}

fn fail(tb: *Typebud, comptime fmt: []const u8, args: anytype) void {
    st.failures += 1;
    note(tb, "FAIL: " ++ fmt, args);
}

fn snapper(tb: *Typebud) *snapshot.Snapshotter {
    if (st.snap == null) st.snap = snapshot.Snapshotter.init(tb.gpa, tb.catalog, tb.app.textSystem(), tb.font_id orelse @fromBackingInt(0), &tb.keys);
    return &st.snap.?;
}

/// Offscreen render of the live pet (current state, outfit, vibe) at 256 px.
fn snapLive(tb: *Typebud, name: []const u8) void {
    const s = snapper(tb);
    const pet = pet_view.currentPet(tb, tb.now(), .{ 0, 0 }, 256, 256, 256);
    const rgba = s.renderRgba(pet) catch |e| return fail(tb, "render {s}: {t}", .{ name, e });
    defer tb.gpa.free(rgba);
    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, out_dir ++ "/pet_{s}.png", .{name}) catch return;
    snapshot.writeRgbaPng(tb.gpa, tb.io, path, rgba, 256, 256) catch |e| return fail(tb, "write {s}: {t}", .{ path, e });
    var opaque_px: usize = 0;
    var i: usize = 3;
    while (i < rgba.len) : (i += 4) opaque_px += @intFromBool(rgba[i] > 200);
    if (opaque_px < 256 * 256 / 20) fail(tb, "{s}: pet nearly empty ({d} px)", .{ name, opaque_px });
    note(tb, "wrote {s} (frame {t})", .{ path, pet.frame });
}

fn expectFrame(tb: *Typebud, want: []const art.Frame, what: []const u8) void {
    const f = tb.state.frame(tb.now());
    for (want) |w| if (w == f) return;
    fail(tb, "{s}: expected {any}, got {t} (mode {t}, {d:.0} wpm)", .{ what, want, f, tb.state.mode, tb.state.wpm(tb.now()) });
}

// ---- steps ----------------------------------------------------------------------------

fn sLaunch(tb: *Typebud) void {
    tb.settings.sound = true;
    tb.settings.head = .headphones;
    tb.launch();
    tb.openSettings();
    note(tb, "typebud smoke on {t}; {d} animals, {d} sound packs, audio {t}", .{ builtin.os.tag, tb.catalog.count, tb.library.packs.items.len, if (tb.audio) |a| a.status().backend else .none });
}

fn sIdle(tb: *Typebud) void {
    if (tb.frames_drawn == 0) fail(tb, "pet window drew no frame", .{});
    expectFrame(tb, &.{ .idle, .peek }, "idle");
    snapLive(tb, "1_idle");
}

fn sType(tb: *Typebud) void {
    st.typist.start(tb, .alternate, 10, 140);
}

fn sTyping(tb: *Typebud) void {
    expectFrame(tb, &.{ .type_left, .type_right, .type_both }, "typing");
    snapLive(tb, "2_typing");
}

fn sFast(tb: *Typebud) void {
    tb.settings.sensitivity = .eager;
    tb.settingsChanged();
    st.typist.start(tb, .alternate, 60, 85); // ~140 WPM for ~5 s
}

fn sExcited(tb: *Typebud) void {
    const t = &st.typist;
    note(tb, "fast burst: {d} keys, longest gap {d} ms, fell idle {d}x between keys", .{ t.n, t.max_gap_ns / std.time.ns_per_ms, t.idle_drops });
    expectFrame(tb, &.{.excited}, "fast typing");
    snapLive(tb, "3_excited");
}

fn sStopped(_: *Typebud) void {
    st.typist.stop();
}

fn sAfter(tb: *Typebud) void {
    expectFrame(tb, &.{ .idle, .peek }, "after typing");
    st.awake_frames0 = tb.frames_drawn;
    tb.settings.sleep_after = 1;
    tb.settingsChanged();
}

fn sAsleep(tb: *Typebud) void {
    expectFrame(tb, &.{.sleep}, "after 1 s idle");
    snapLive(tb, "4_sleep");
    st.idle_frames0 = tb.frames_drawn;
    st.idle_cpu0 = clock.cpuNs();
}

fn sIdleEnd(tb: *Typebud) void {
    st.idle_frames = tb.frames_drawn - st.idle_frames0;
    st.idle_cpu_ms = (clock.cpuNs() -| st.idle_cpu0) / std.time.ns_per_ms;
    note(tb, "idle second (asleep): {d} frames drawn, {d} ms CPU", .{ st.idle_frames, st.idle_cpu_ms });
    if (st.idle_frames > 0) fail(tb, "frames were drawn while idle", .{});
    tb.handleInput(.{ .kind = .key_down, .key = .letter, .key_x = 0.3, .timestamp_ns = tb.now() });
    expectFrame(tb, &.{.wake}, "key while asleep");
    snapLive(tb, "5_wake");
    tb.settings.sleep_after = 60;
    tb.settingsChanged();
}

fn sHold(tb: *Typebud) void {
    tb.settings.held = .coffee;
    tb.settings.desk_plant = true;
    tb.settings.sparkles = true;
    tb.settings.vibe = .pink;
    tb.settingsChanged();
}

fn sHoldShot(tb: *Typebud) void {
    expectFrame(tb, &.{ .hold, .sip, .wake }, "held item");
    snapLive(tb, "6_hold_pink");
    // Resize + move the window through the same paths as the UI.
    tb.settings.size = 256;
    tb.settings.corner = .top_left;
    tb.settingsChanged();
}

fn sResized(tb: *Typebud) void {
    if (tb.petWindow()) |w| {
        const sz = w.viewportSize();
        note(tb, "pet window after resize: {d}x{d} (raster {d} px, {d} cached layers, {d} KiB)", .{ sz.width, sz.height, tb.raster_px, tb.cache.count(), tb.cache.stats.bytes / 1024 });
        if (@abs(sz.width - 256) > 1) fail(tb, "resize to 256 did not apply ({d})", .{sz.width});
    }
    tb.settings.size = 176;
    tb.settings.corner = .bottom_right;
    tb.settings.held = .none;
    tb.settings.vibe = .dark;
    tb.settingsChanged();
}

/// Every animal × vibe, idle with accessories, into one sheet; plus each animal's frames.
fn sMatrix(tb: *Typebud) void {
    const s = snapper(tb);
    const cell: u32 = 256;
    const n: u32 = @intCast(tb.catalog.count);
    var sheet = snapshot.Sheet.init(tb.gpa, cell * 3 * 2, cell * n, .{ 255, 255, 255, 255 }) catch return;
    defer sheet.deinit(tb.gpa);
    for (tb.catalog.list(), 0..) |a, ai| {
        for (std.meta.tags(art.Vibe), 0..) |v, vi| for (0..2) |variant| {
            const x: u32 = @intCast((vi * 2 + variant) * cell);
            const y: u32 = @intCast(ai * cell);
            sheet.fill(x, y, cell, cell, snapshot.backdrops[vi]);
            const head: art.HeadItem = if (variant == 0) .headphones else if (a.hasHeadItem(.yuzu)) .yuzu else .party_hat;
            const outfit: art.Outfit = if (variant == 0)
                .{ .head = head }
            else
                .{ .head = head, .held = .boba, .desk = .{ .plant = true, .lamp = true }, .sparkles = true };
            const frame: art.Frame = if (variant == 0) .type_left else .hold;
            const rgba = s.renderRgba(.{ .animal = ai, .vibe = v, .frame = frame, .outfit = outfit, .origin = .{ 0, 0 }, .size = 256, .raster_px = 256, .legend_size = 256 }) catch |e| {
                fail(tb, "matrix {s}: {t}", .{ a.name, e });
                continue;
            };
            defer tb.gpa.free(rgba);
            sheet.blit(x, y, rgba, cell, cell);
        };
        var pb: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, out_dir ++ "/frames_{s}.png", .{a.name}) catch continue;
        snapshot.animalSheet(s, tb.io, ai, 192, path) catch |e| fail(tb, "{s}: {t}", .{ path, e });
        var miss_buf: [256]u8 = undefined;
        var miss: std.Io.Writer = .fixed(&miss_buf);
        for (std.meta.tags(art.Frame)) |f| if (!a.hasFrame(f)) miss.print(" {t}", .{f}) catch {};
        if (miss.buffered().len > 0) note(tb, "{s}: missing frames:{s} (skipped)", .{ a.name, miss.buffered() });
    }
    sheet.writePng(tb.gpa, tb.io, out_dir ++ "/matrix.png") catch |e| fail(tb, "matrix.png: {t}", .{e});
    note(tb, "wrote {s}/matrix.png and frames_<animal>.png", .{out_dir});
}

const looks = [_]struct { name: []const u8, style: zpui.platform.DesktopStyle, dark: bool }{
    .{ .name = "light", .style = .none, .dark = false },
    .{ .name = "dark", .style = .none, .dark = true },
    .{ .name = "kde", .style = .breeze, .dark = false },
};

fn sSettingsSection(tb: *Typebud) void {
    const w = tb.settingsWindow() orelse return fail(tb, "settings window is not open", .{});
    tb.settings_section = @enumFromInt(st.section);
    // Linux: libadwaita by default, also Breeze and dark; macOS: system light / dark.
    const lk = looks[st.look];
    var t = w.desktopTheme();
    if (builtin.os.tag == .linux) t.style = if (lk.style == .none) .adwaita else lk.style;
    t.dark = lk.dark;
    w.setDesktopTheme(t);
    if (builtin.os.tag == .macos) w.glass_dark = lk.dark;
    w.refresh();
}

fn sSettingsShot(tb: *Typebud) void {
    const w = tb.settingsWindow() orelse return;
    const name = settings_view.Section.labels[st.section];
    var pb: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, out_dir ++ "/settings_{s}_{d}_{s}.png", .{ looks[st.look].name, st.section + 1, name }) catch return;
    for (path) |*c| if (c.* == ' ') {
        c.* = '_';
    };
    const img = capture.captureWindow(tb.gpa, tb.io, w) catch |e| {
        note(tb, "settings capture unavailable here: {t}", .{e});
        return;
    };
    defer tb.gpa.free(img.pixels);
    snapshot.writeRgbaPng(tb.gpa, tb.io, path, img.pixels, img.width, img.height) catch |e| return fail(tb, "{s}: {t}", .{ path, e });
    note(tb, "wrote {s} ({d}x{d})", .{ path, img.width, img.height });
    st.section += 1;
    if (st.section == settings_view.Section.labels.len) {
        st.section = 0;
        st.look += 1;
    }
}

fn sDesktop(tb: *Typebud) void {
    if (builtin.os.tag != .linux) return;
    const res = std.process.run(tb.gpa, tb.io, .{ .argv = &.{ "import", "-window", "root", out_dir ++ "/desktop.png" } }) catch return;
    tb.gpa.free(res.stdout);
    tb.gpa.free(res.stderr);
}

fn done(tb: *Typebud) void {
    note(tb, "pet frames drawn in total: {d}; layer cache: {d} images, {d} KiB, {d} rasterized in {d} ms", .{
        tb.frames_drawn, tb.cache.count(), tb.cache.stats.bytes / 1024, tb.cache.stats.rasterized, tb.cache.stats.raster_ns / std.time.ns_per_ms,
    });
    if (st.failures == 0) note(tb, "PASS", .{}) else note(tb, "{d} failure(s)", .{st.failures});
    std.Io.Dir.cwd().createDirPath(tb.io, out_dir) catch {};
    std.Io.Dir.cwd().writeFile(tb.io, .{ .sub_path = out_dir ++ "/report.txt", .data = st.report.items }) catch {};
    if (st.snap) |*s| s.deinit();
    st.snap = null;
    st.code.* = if (st.failures == 0) 0 else 1;
    tb.app.quit();
}

fn sWatchdogArm(tb: *Typebud) void {
    tb.app.platform.dispatcher().dispatchAfter(120 * std.time.ns_per_s, .{ .ctx = tb, .run = watchdog });
}

fn watchdog(ctx: *anyopaque) void {
    const tb: *Typebud = @ptrCast(@alignCast(ctx));
    fail(tb, "watchdog: smoke run stuck at step {d}", .{st.runner.index});
    done(tb);
}

const section_steps = blk: {
    var list: [settings_view.Section.labels.len * looks.len * 2]script.Step = undefined;
    for (0..settings_view.Section.labels.len * looks.len) |i| {
        list[i * 2] = .{ .wait_ms = 100, .run = sSettingsSection };
        list[i * 2 + 1] = .{ .wait_ms = 500, .run = sSettingsShot };
    }
    break :blk list;
};

const steps = [_]script.Step{
    .{ .run = sWatchdogArm },
    .{ .run = sLaunch },
    .{ .wait_ms = 1200, .run = sIdle },
    .{ .run = sType },
    .{ .wait_ms = 700, .run = sTyping },
    .{ .wait_ms = 1200, .run = sFast },
    .{ .wait_ms = 5200, .run = sExcited },
    .{ .run = sStopped },
    .{ .wait_ms = 900, .run = sAfter },
    .{ .wait_ms = 1600, .run = sAsleep },
    .{ .wait_ms = 1000, .run = sIdleEnd },
    .{ .wait_ms = 800, .run = sHold },
    .{ .wait_ms = 400, .run = sHoldShot },
    .{ .wait_ms = 800, .run = sResized },
    .{ .wait_ms = 300, .run = sDesktop },
    .{ .run = sMatrix },
} ++ section_steps;

pub fn start(tb: *Typebud, code: *u8) void {
    st = .{ .code = code };
    std.Io.Dir.cwd().createDirPath(tb.io, out_dir) catch {};
    st.runner = .{ .tb = tb, .steps = &steps, .done = done };
    st.runner.start();
}
