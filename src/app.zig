//! typebud's controller: owns the settings, art catalog, pet state, sounds, tray and
//! windows, and wires zpui's desktop features (global input, foreground app, tray, launch
//! at login) to them. Everything runs on the main thread.
//!
//! Performance contract: when nothing changes nothing runs — no frame is drawn, no timer
//! is armed except the pet's next scheduled state change (peek, sleep), and the global
//! input callback only updates a few integers and marks the pet window dirty, so a burst
//! of keys between two frames costs one frame.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const zpui = @import("zpui");
const build_options = @import("build_options");

const art = @import("art.zig");
const assets = @import("assets.zig");
const raster = @import("raster.zig");
const legends = @import("legends.zig");
const render = @import("render.zig");
const settings_mod = @import("settings.zig");
const pet_state = @import("pet_state.zig");
const sound = @import("sound.zig");
const visibility = @import("visibility.zig");
const update_hook = @import("update_hook.zig");
const pet_view = @import("pet_view.zig");
const settings_view = @import("settings_view.zig");
const clock = @import("clock.zig");
const pack_import = @import("pack_import.zig");
const placement = @import("placement.zig");

const App = zpui.App;
const Window = zpui.Window;
const platform = zpui.platform;
const Settings = settings_mod.Settings;

pub const bundle_id = "lol.peril.typebud";
pub const app_id = "typebud";

// Tray / menu actions.
pub const ToggleVisible = zpui.action("typebud::ToggleVisible");
pub const TogglePause = zpui.action("typebud::TogglePause");
pub const OpenSettings = zpui.action("typebud::OpenSettings");
pub const CheckUpdates = zpui.action("typebud::CheckUpdates");
pub const Quit = zpui.action("typebud::Quit");

pub const Options = struct {
    open_settings: bool = false,
    /// Do not read or write the user's settings file (smoke / demo runs).
    ephemeral: bool = false,
    /// Audio backend override (smoke / demo: `.null` renders offline).
    audio_backend: zpui.audio.Preference = .auto,
    /// Don't install the tray item or start the global input monitor (scripted runs that
    /// must not react to the real keyboard).
    scripted: bool = false,
};

pub const Drag = enum { none, resize, move };

const KeyUpSlot = struct { tb: *Typebud, pool: sound.Pool, busy: bool = false };

pub var instance: *Typebud = undefined;

pub const Typebud = struct {
    gpa: Allocator,
    io: std.Io,
    app: *App,
    options: Options,
    config_dir: []u8,
    catalog: *art.Catalog,
    keys_arena: std.heap.ArenaAllocator,
    keys: legends.Keys = .{},
    font_id: ?zpui.text.FontId = null,

    settings: Settings = .{},
    /// What the windows / audio / tray currently reflect.
    applied: ?Settings = null,
    animal: usize = 0,

    // pet
    pet_window: ?zpui.WindowId = null,
    state: pet_state.PetState = .{},
    cache: raster.LayerCache,
    layout: legends.Layout = .{},
    anchor: platform.OverlayAnchor = .{},
    display_id: ?u32 = null,
    /// Window edge while a resize drag is live (else settings.size).
    live_size: f32 = 0,
    raster_px: u32 = 0,
    drag: Drag = .none,
    drag_start_mouse: platform.Point = .zero,
    drag_start_size: f32 = 0,
    drag_start_margin: platform.Point = .zero,
    hovered: bool = false,
    region: [6]zpui.Bounds(zpui.Pixels) = undefined,
    region_len: usize = 0,
    region_key: u64 = 0,
    frames_drawn: u64 = 0,

    // visibility
    user_visible: bool = true,
    rule_visible: bool = true,
    paused: bool = false,
    fg_id_buf: [128]u8 = undefined,
    fg_name_buf: [128]u8 = undefined,
    fg_id: ?[]const u8 = null,
    fg_name: ?[]const u8 = null,
    recent: [8]settings_mod.AppEntry = @splat(.{}),
    recent_len: usize = 0,

    // sound
    library: sound.Library,
    player: sound.Player,
    audio: ?*zpui.audio.Audio = null,
    monitor: ?*zpui.audio.ActivityMonitor = null,
    keyup_slots: [16]KeyUpSlot = undefined,
    /// macOS without Input Monitoring: the input backend counts keys and can't see
    /// releases at the right time, so key-up sounds are synthesized 70–90 ms later.
    synth_key_up: bool = false,
    input_status: platform.InputMonitorStatus = .unsupported,
    import_message: settings_mod.Str(160) = .{},

    // timers
    armed_at: ?u64 = null,
    save_armed: bool = false,
    rng: std.Random.DefaultPrng = .init(0xb0d),

    // windows
    settings_window: ?zpui.WindowId = null,
    settings_section: settings_view.Section = .character,
    tray_ok: bool = false,
    tray_animal: usize = std.math.maxInt(usize),
    tray_state: u8 = 0xff,

    /// Called after each pet frame is drawn (scripted runs).
    frame_hook: ?*const fn (*Typebud) void = null,

    pub fn create(gpa: Allocator, io: std.Io, env: *const std.process.Environ.Map, app: *App, options: Options) !*Typebud {
        const self = try gpa.create(Typebud);
        errdefer gpa.destroy(self);
        const catalog = try art.Catalog.init(gpa);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .app = app,
            .options = options,
            .config_dir = settings_mod.configDir(gpa, env) catch try gpa.dupe(u8, "typebud-config"),
            .catalog = catalog,
            .keys_arena = .init(gpa),
            .cache = .init(gpa, catalog),
            .library = .init(gpa),
            .player = .init(gpa, io, null),
        };
        for (&self.keyup_slots) |*s| s.* = .{ .tb = self, .pool = .generic };
        instance = self;
        if (!options.ephemeral) self.settings = settings_mod.load(gpa, io, self.config_dir);
        self.settings.sanitize();
        self.user_visible = if (self.settings.remember_visible) self.settings.visible else true;
        self.keys = legends.Keys.parse(self.keys_arena.allocator(), assets.get("art/_shared/keyboard_keys.json") orelse "{}", legends.os_name) catch .{};
        app.addFont(assets.get("assets/fonts/Nunito-ExtraBold.ttf").?) catch |e| std.log.warn("legend font: {t}", .{e});
        self.font_id = app.textSystem().resolveFont(.{ .family = "Nunito" }) catch null;
        self.library.loadBundled();
        self.library.loadFolder(io, self.userPackDir() catch "");
        return self;
    }

    pub fn destroy(self: *Typebud) void {
        const gpa = self.gpa;
        self.flushSave();
        self.cache.deinit();
        self.player.deinit();
        if (self.monitor) |m| m.deinit();
        if (self.audio) |a| a.deinit();
        self.library.deinit();
        self.keys_arena.deinit();
        self.catalog.deinit(gpa);
        gpa.free(self.config_dir);
        gpa.destroy(self);
    }

    pub fn userPackDir(self: *Typebud) ![]const u8 {
        const S = struct {
            var buf: [1024]u8 = undefined;
        };
        return std.fmt.bufPrint(&S.buf, "{s}{c}packs", .{ self.config_dir, std.fs.path.sep });
    }

    pub fn now(self: *Typebud) u64 {
        return self.app.platform.dispatcher().now();
    }

    // ---- launch -----------------------------------------------------------------------

    pub fn launch(self: *Typebud) void {
        const app = self.app;
        app.onAction(ToggleVisible, self, onToggleVisible) catch {};
        app.onAction(TogglePause, self, onTogglePause) catch {};
        app.onAction(OpenSettings, self, onOpenSettings) catch {};
        app.onAction(CheckUpdates, self, onCheckUpdates) catch {};
        app.onAction(Quit, self, onQuit) catch {};
        // ⌘, opens (or raises) Settings from any typebud window, as in every Mac app.
        if (builtin.os.tag == .macos) app.bindKeys(&.{.init("cmd-,", OpenSettings{}, null)}) catch {};

        self.animal = self.catalog.indexOf(self.settings.animal.slice()) orelse 0;
        self.state = pet_state.PetState.init(self.now(), self.stateConfig());
        self.anchor = .{ .corner = toCorner(self.settings.corner), .margin = .{ .x = self.settings.margin_x, .y = self.settings.margin_y } };
        self.display_id = self.displayIdFor(self.settings.display);
        self.live_size = self.settings.size;
        self.openPetWindow() catch |e| {
            std.log.err("typebud: cannot open the pet window: {t}", .{e});
            app.quit();
            return;
        };
        self.apply();
        if (!self.options.scripted) {
            app.onForegroundAppChange(self, onForegroundChanged) catch {};
            self.refreshForeground();
            app.setPreciseInput(self.settings.precise_input);
            self.input_status = app.startGlobalInputMonitor(self, onGlobalInput);
            std.log.info("typebud {s}: global input {t} (permission {t})", .{ build_options.version, self.input_status, app.inputPermission() });
        }
        self.updateSynthKeyUp();
        self.rearm();
        if (self.options.open_settings or (!self.tray_ok and !self.options.scripted)) self.openSettings();
    }

    fn openPetWindow(self: *Typebud) !void {
        const size = self.settings.size;
        const handle = try self.app.openWindow(.{
            .bounds = .{ .origin = .zero, .size = .{ .width = size, .height = size } },
            .titlebar = null,
            .kind = .overlay,
            .background = .transparent,
            .focus = false,
            .show = self.isShown(),
            .anchor = self.anchor,
            .display_id = self.display_id,
            .app_id = if (builtin.os.tag == .macos) bundle_id else app_id,
        }, pet_view.PetView, pet_view.PetView.init, .{});
        self.pet_window = handle.id;
    }

    pub fn petWindow(self: *Typebud) ?*Window {
        const id = self.pet_window orelse return null;
        return self.app.windowById(id);
    }

    pub fn settingsWindow(self: *Typebud) ?*Window {
        const id = self.settings_window orelse return null;
        const w = self.app.windowById(id) orelse {
            self.settings_window = null;
            return null;
        };
        return w;
    }

    pub fn redrawPet(self: *Typebud) void {
        if (self.petWindow()) |w| w.refresh();
    }

    pub fn redrawSettings(self: *Typebud) void {
        if (self.settingsWindow()) |w| w.refresh();
    }

    // ---- settings ---------------------------------------------------------------------

    pub fn stateConfig(self: *Typebud) pet_state.Config {
        const s = &self.settings;
        return .{
            .animations = s.animations,
            .sleep_after = @as(u64, s.sleep_after) * std.time.ns_per_s,
            .excited_wpm = s.sensitivity.wpm(),
            .holding = s.held != .none,
        };
    }

    /// The outfit actually drawn: a held drink rests on the desk (mug) while typing.
    pub fn outfit(self: *Typebud, frame: art.Frame) art.Outfit {
        var o = self.settings.outfit();
        if (o.held == .coffee or o.held == .boba) {
            if (frame != .hold and frame != .sip and frame != .sleep and frame != .wake) o.desk.mug = true;
        }
        if (!self.catalog.animals[self.animal].hasHeadItem(o.head)) o.head = .none;
        return o;
    }

    /// Settings changed (from the UI, tray or a script): apply what differs and save soon.
    pub fn settingsChanged(self: *Typebud) void {
        self.settings.sanitize();
        self.apply();
        self.scheduleSave();
        self.redrawSettings();
    }

    fn apply(self: *Typebud) void {
        const s = &self.settings;
        const prev = self.applied;
        const changed = struct {
            fn f(p: ?Settings, comptime field: []const u8, cur: anytype) bool {
                const old = p orelse return true;
                return !std.meta.eql(@field(old, field), cur);
            }
        }.f;
        const now_ns = self.now();
        if (changed(prev, "animal", s.animal)) {
            if (self.catalog.indexOf(s.animal.slice())) |i| self.animal = i else {
                self.animal = 0;
                s.animal.set(self.catalog.animals[0].name);
            }
        }
        if (prev == null or !std.meta.eql(self.stateConfig(), self.state.config)) self.state.setConfig(now_ns, self.stateConfig());
        if (changed(prev, "size", s.size) and self.drag == .none) {
            self.live_size = s.size;
            if (self.petWindow()) |w| {
                w.resize(.{ .width = s.size, .height = s.size });
            }
        }
        if (changed(prev, "corner", s.corner) or changed(prev, "margin_x", s.margin_x) or changed(prev, "margin_y", s.margin_y) or changed(prev, "display", s.display)) {
            self.anchor = .{ .corner = toCorner(s.corner), .margin = .{ .x = s.margin_x, .y = s.margin_y } };
            self.display_id = self.displayIdFor(s.display);
            if (prev != null) if (self.petWindow()) |w| w.setAnchor(self.anchor, self.display_id);
        }
        // Sounds.
        if (changed(prev, "sound", s.sound) or changed(prev, "pack", s.pack) or changed(prev, "volume", s.volume) or
            changed(prev, "mute_other_audio", s.mute_other_audio) or changed(prev, "mute_mic", s.mute_mic))
            self.applySound();
        if (prev != null and changed(prev, "precise_input", s.precise_input) and !self.options.scripted) {
            self.app.setPreciseInput(s.precise_input);
            self.input_status = self.app.startGlobalInputMonitor(self, onGlobalInput);
            self.updateSynthKeyUp();
        }
        if (prev != null and changed(prev, "launch_at_login", s.launch_at_login)) self.applyLaunchAtLogin();
        if (changed(prev, "auto_update", s.auto_update)) update_hook.setAutoCheck(s.auto_update);
        if (changed(prev, "visibility", s.visibility) or changed(prev, "apps", s.apps) or changed(prev, "app_count", s.app_count)) self.evaluateRule();
        self.applied = s.*;
        self.updateTray();
        self.updateVisibility();
        self.rearm();
        self.redrawPet();
    }

    fn applySound(self: *Typebud) void {
        const s = &self.settings;
        if (s.sound and self.audio == null) {
            self.audio = zpui.audio.Audio.init(self.gpa, .{ .app_name = "typebud", .backend = self.options.audio_backend }) catch null;
            self.player.audio = self.audio;
        }
        self.player.setVolume(s.volume);
        if (s.sound) {
            const info = self.library.find(s.pack.slice()) orelse self.library.find("nk-cream") orelse
                (if (self.library.packs.items.len > 0) &self.library.packs.items[0] else null);
            if (info) |i| self.player.select(i) catch |e| std.log.warn("sound pack {s}: {t}", .{ i.id, e });
        }
        const want_monitor = s.sound and (s.mute_other_audio or s.mute_mic) and !self.options.scripted;
        if (want_monitor and self.monitor == null) {
            self.monitor = zpui.audio.ActivityMonitor.init(self.gpa, .{
                .policy = .{ .mute_when_other_audio = s.mute_other_audio, .mute_when_mic_in_use = s.mute_mic },
                .notify = onMonitorNotify,
                .notify_ctx = self,
                .audio = self.audio,
            }) catch null;
        }
        if (self.monitor) |m| {
            m.setPolicy(.{ .mute_when_other_audio = s.mute_other_audio, .mute_when_mic_in_use = s.mute_mic });
            m.setEnabled(want_monitor);
        }
    }

    fn onMonitorNotify(ctx: ?*anyopaque) void {
        const self: *Typebud = @ptrCast(@alignCast(ctx.?));
        self.app.platform.dispatcher().dispatchOnMainThread(.{ .ctx = self, .run = onMonitorDispatch }, .low);
    }

    fn onMonitorDispatch(ctx: *anyopaque) void {
        const self: *Typebud = @ptrCast(@alignCast(ctx));
        if (self.monitor) |m| if (m.dispatch()) self.redrawSettings();
    }

    pub fn soundMuted(self: *Typebud) bool {
        if (!self.settings.sound or self.paused) return true;
        if (self.monitor) |m| return m.shouldMute();
        return false;
    }

    fn updateSynthKeyUp(self: *Typebud) void {
        self.synth_key_up = builtin.os.tag == .macos and !self.settings.precise_input;
    }

    fn applyLaunchAtLogin(self: *Typebud) void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = std.process.executablePath(self.io, &buf) catch return;
        self.app.setLaunchAtLogin(if (builtin.os.tag == .macos) bundle_id else app_id, buf[0..n], self.settings.launch_at_login) catch |e|
            std.log.warn("launch at login: {t}", .{e});
    }

    pub fn scheduleSave(self: *Typebud) void {
        if (self.options.ephemeral or self.save_armed) return;
        self.save_armed = true;
        self.app.platform.dispatcher().dispatchAfter(600 * std.time.ns_per_ms, .{ .ctx = self, .run = onSaveTimer });
    }

    fn onSaveTimer(ctx: *anyopaque) void {
        const self: *Typebud = @ptrCast(@alignCast(ctx));
        self.flushSave();
    }

    fn flushSave(self: *Typebud) void {
        if (!self.save_armed) return;
        self.save_armed = false;
        self.settings.visible = self.user_visible;
        settings_mod.save(self.gpa, self.io, self.config_dir, &self.settings) catch |e| std.log.warn("settings: save failed: {t}", .{e});
    }

    // ---- displays -----------------------------------------------------------------------

    pub fn displays(self: *Typebud, out: []platform.Display) usize {
        return self.app.displays(out);
    }

    fn displayIdFor(self: *Typebud, index: u32) ?u32 {
        var buf: [8]platform.Display = undefined;
        const n = self.displays(&buf);
        if (n == 0) return null;
        return buf[@min(index, n - 1)].id;
    }

    // ---- visibility ---------------------------------------------------------------------

    pub fn isShown(self: *const Typebud) bool {
        return self.user_visible and self.rule_visible;
    }

    pub fn updateVisibility(self: *Typebud) void {
        const w = self.petWindow() orelse return;
        const shown = self.isShown();
        w.setVisible(shown);
    }

    fn onForegroundChanged(self: *Typebud, _: *App) void {
        self.refreshForeground();
    }

    fn refreshForeground(self: *Typebud) void {
        var buf: [512]u8 = undefined;
        const fg = self.app.foregroundApp(&buf) orelse {
            self.fg_id = null;
            self.fg_name = null;
            self.evaluateRule();
            return;
        };
        // Our own settings window in front: keep the previous decision.
        if (std.ascii.eqlIgnoreCase(fg.id, bundle_id) or std.ascii.eqlIgnoreCase(fg.id, app_id)) return;
        const il = @min(fg.id.len, self.fg_id_buf.len);
        @memcpy(self.fg_id_buf[0..il], fg.id[0..il]);
        const nl = @min(fg.name.len, self.fg_name_buf.len);
        @memcpy(self.fg_name_buf[0..nl], fg.name[0..nl]);
        self.fg_id = self.fg_id_buf[0..il];
        self.fg_name = self.fg_name_buf[0..nl];
        self.noteRecent(self.fg_id.?, self.fg_name.?);
        self.evaluateRule();
    }

    fn noteRecent(self: *Typebud, id: []const u8, name: []const u8) void {
        if (id.len == 0) return;
        var found: ?usize = null;
        for (self.recent[0..self.recent_len], 0..) |r, i| if (r.id.eql(id)) {
            found = i;
            break;
        };
        const end = found orelse blk: {
            self.recent_len = @min(self.recent_len + 1, self.recent.len);
            break :blk self.recent_len - 1;
        };
        var j = end;
        while (j > 0) : (j -= 1) self.recent[j] = self.recent[j - 1];
        self.recent[0] = .{ .id = .init(id), .name = .init(if (name.len > 0) name else id) };
        self.redrawSettings();
    }

    /// Most recent foreground app not yet in the list (for the list's + button).
    pub fn recentCandidate(self: *const Typebud) ?settings_mod.AppEntry {
        for (self.recent[0..self.recent_len]) |r| if (!self.settings.hasApp(r.id.slice())) return r;
        return null;
    }

    fn evaluateRule(self: *Typebud) void {
        self.rule_visible = visibility.allows(self.settings.visibility, self.settings.appList(), self.fg_id, self.fg_name);
        self.updateVisibility();
    }

    pub fn setUserVisible(self: *Typebud, on: bool) void {
        self.user_visible = on;
        self.updateVisibility();
        self.updateTray();
        if (on) self.redrawPet();
        if (self.settings.remember_visible) self.scheduleSave();
    }

    pub fn setPaused(self: *Typebud, on: bool) void {
        self.paused = on;
        self.updateTray();
        self.redrawSettings();
    }

    // ---- input --------------------------------------------------------------------------

    fn onGlobalInput(self: *Typebud, e: platform.GlobalInputEvent, _: *App) void {
        self.handleInput(e);
    }

    /// One global input event (also the entry point for synthetic events in scripted runs).
    pub fn handleInput(self: *Typebud, e: platform.GlobalInputEvent) void {
        if (self.paused) return;
        switch (e.kind) {
            .key_down => {
                const now_ns = self.now();
                // key_x 0.5 is the backends' "unknown"; the macOS counter alternates itself.
                const kx: ?f32 = if (e.key_x == 0.5 and e.key == .other) null else e.key_x;
                self.state.onKey(.{ .key = @enumFromInt(@intFromEnum(e.key)), .key_x = kx, .t = now_ns });
                const pool = sound.poolForClass(e.key);
                if (!self.soundMuted()) {
                    self.player.play(.down, pool);
                    if (self.synth_key_up and self.settings.key_up) self.scheduleKeyUp(pool);
                }
                self.rearm();
                if (self.isShown()) self.redrawPet();
            },
            .key_up => {
                if (!self.synth_key_up and self.settings.key_up and !self.soundMuted()) self.player.play(.up, sound.poolForClass(e.key));
            },
            else => {},
        }
    }

    fn scheduleKeyUp(self: *Typebud, pool: sound.Pool) void {
        for (&self.keyup_slots) |*slot| if (!slot.busy) {
            slot.busy = true;
            slot.pool = pool;
            const delay = (70 + self.rng.random().uintLessThan(u64, 21)) * std.time.ns_per_ms;
            self.app.platform.dispatcher().dispatchAfter(delay, .{ .ctx = slot, .run = onKeyUpTimer });
            return;
        };
    }

    fn onKeyUpTimer(ctx: *anyopaque) void {
        const slot: *KeyUpSlot = @ptrCast(@alignCast(ctx));
        slot.busy = false;
        if (!slot.tb.soundMuted()) slot.tb.player.play(.up, slot.pool);
    }

    /// Arm the single pet timer for the state machine's next deadline (if sooner than one
    /// already armed). Nothing is armed while the pet sleeps or with reduced motion.
    pub fn rearm(self: *Typebud) void {
        const now_ns = self.now();
        const d = self.state.nextDeadline(now_ns) orelse return;
        if (self.armed_at) |a| if (a <= d and a > now_ns) return;
        self.armed_at = d;
        self.app.platform.dispatcher().dispatchAfter(d - now_ns, .{ .ctx = self, .run = onPetTimer });
    }

    fn onPetTimer(ctx: *anyopaque) void {
        const self: *Typebud = @ptrCast(@alignCast(ctx));
        const now_ns = self.now();
        if (self.armed_at) |a| if (now_ns + std.time.ns_per_ms >= a) {
            self.armed_at = null;
        };
        if (self.state.update(now_ns) and self.isShown()) self.redrawPet();
        self.rearm();
    }

    // ---- pet geometry / drags (called by the pet view) ------------------------------------

    pub fn petSize(self: *const Typebud) f32 {
        return if (self.drag == .resize) self.live_size else self.settings.size;
    }

    pub fn beginDrag(self: *Typebud, kind: Drag, w: *Window) void {
        const p = w.screenMousePosition() orelse return;
        self.drag = kind;
        self.drag_start_mouse = p;
        self.drag_start_size = self.settings.size;
        self.drag_start_margin = self.anchor.margin;
        self.live_size = self.settings.size;
    }

    pub fn dragTo(self: *Typebud, w: *Window, p: platform.Point) void {
        const delta: platform.Point = .{ .x = p.x - self.drag_start_mouse.x, .y = p.y - self.drag_start_mouse.y };
        switch (self.drag) {
            .resize => {
                const sz = platform.desktop.aspectResize(self.anchor.corner, .{ .width = self.drag_start_size, .height = self.drag_start_size }, delta, settings_mod.min_size, settings_mod.max_size);
                const edge = @round(sz.width);
                if (edge != self.live_size) {
                    self.live_size = edge;
                    w.resize(.{ .width = edge, .height = edge });
                    w.refresh();
                }
            },
            .move => {
                const m = placement.dragMargin(fromCorner(self.anchor.corner), .{ .x = self.drag_start_margin.x, .y = self.drag_start_margin.y }, .{ .x = delta.x, .y = delta.y });
                self.anchor.margin = .{ .x = m.x, .y = m.y };
                w.setAnchor(self.anchor, self.display_id);
            },
            .none => {},
        }
    }

    pub fn endDrag(self: *Typebud, w: *Window) void {
        switch (self.drag) {
            .resize => {
                self.drag = .none;
                self.settings.size = self.live_size;
                self.settingsChanged(); // re-rasterizes at the final size on the next frame
            },
            .move => {
                self.drag = .none;
                self.snapToCorner(w);
            },
            .none => {},
        }
        w.refresh();
    }

    /// After a move: pin to the corner (of the display) nearest to the pet's centre.
    fn snapToCorner(self: *Typebud, w: *Window) void {
        var buf: [8]platform.Display = undefined;
        const n = self.displays(&buf);
        const pointer = w.screenMousePosition();
        if (n == 0 or pointer == null) {
            self.settings.margin_x = self.anchor.margin.x;
            self.settings.margin_y = self.anchor.margin.y;
            self.settingsChanged();
            return;
        }
        var rects: [8]placement.Rect = undefined;
        for (buf[0..n], 0..) |d, i| rects[i] = .{ .x = d.visible_bounds.origin.x, .y = d.visible_bounds.origin.y, .w = d.visible_bounds.size.width, .h = d.visible_bounds.size.height };
        const s = placement.snap(.{ .x = pointer.?.x, .y = pointer.?.y }, rects[0..n]).?;
        self.settings.corner = s.corner;
        self.settings.display = @intCast(s.display);
        self.settings.margin_x = 16;
        self.settings.margin_y = 16;
        self.settingsChanged();
    }

    // ---- tray ---------------------------------------------------------------------------

    fn updateTray(self: *Typebud) void {
        if (self.options.scripted and !self.tray_ok and self.tray_state != 0xff) return;
        const st: u8 = @as(u8, @intFromBool(self.user_visible)) | (@as(u8, @intFromBool(self.paused)) << 1);
        if (self.tray_animal == self.animal and self.tray_state == st) return;
        self.tray_animal = self.animal;
        self.tray_state = st;
        const icon = self.trayIcon() catch |e| {
            std.log.warn("tray icon: {t}", .{e});
            return;
        };
        defer self.gpa.free(icon);
        const items = [_]zpui.MenuItem{
            .action(if (self.user_visible) "Hide typebud" else "Show typebud", ToggleVisible{}),
            zpui.MenuItem.action("Pause Reactions", TogglePause{}).checkedIf(self.paused),
            .separator,
            .action("Settings…", OpenSettings{}),
            .action("Check for Updates…", CheckUpdates{}),
            .separator,
            .action("Quit typebud", Quit{}),
        };
        self.app.setTray(.{ .icon_png = icon, .template = builtin.os.tag == .macos, .tooltip = "typebud", .items = &items }) catch |e| {
            if (self.tray_ok or self.tray_state == st) std.log.info("tray: {t} (no tray host; double-click the pet for settings)", .{e});
            self.tray_ok = false;
            return;
        };
        self.tray_ok = true;
    }

    /// PNG of the current animal's tray icon: the black template on macOS (the menu bar
    /// tints it), the coloured face elsewhere.
    pub fn trayIcon(self: *Typebud) ![]u8 {
        const a = &self.catalog.animals[self.animal];
        var pb: [96]u8 = undefined;
        const name = if (builtin.os.tag == .macos) "icon_template" else "icon";
        const path = try std.fmt.bufPrint(&pb, "art/{s}/{s}.svg", .{ a.name, name });
        return iconPng(self.gpa, self.catalog, self.animal, path, 44);
    }

    // ---- settings window ------------------------------------------------------------------

    pub fn openSettings(self: *Typebud) void {
        const mac = builtin.os.tag == .macos;
        // An accessory (LSUIElement) app is never active on its own: bring it forward so
        // the settings window becomes key in front of the app the user was in.
        if (mac) self.app.activate(true);
        if (self.settingsWindow()) |w| {
            w.activateWindow();
            return;
        }
        // macOS: System Settings' window: full-size content under a transparent, hidden
        // title and an empty unified toolbar (traffic lights centred in the toolbar band
        // over the sidebar), no separator, non-opaque for the sidebar material, frame
        // remembered across launches.
        const handle = self.app.openWindow(.{
            .bounds = .{ .origin = .{ .x = 120, .y = 120 }, .size = if (mac) settings_view.mac_window_size else settings_view.window_size },
            .titlebar = if (mac) .{ .title = "typebud Settings", .appears_transparent = true, .toolbar = .unified, .separator = .none } else null,
            .app_id = if (mac) bundle_id else app_id,
            .min_size = if (mac) settings_view.mac_min_size else settings_view.window_size,
            .background = if (mac) .transparent else .opaque_,
            .frame_autosave_name = if (mac and !self.options.ephemeral) "typebud.settings" else null,
        }, settings_view.SettingsView, settings_view.SettingsView.init, .{}) catch |e| {
            std.log.err("settings window: {t}", .{e});
            return;
        };
        self.settings_window = handle.id;
        if (handle.window(self.app)) |w| w.activateWindow();
    }

    pub fn importPack(self: *Typebud) void {
        self.app.platform.promptForPaths(.{ .files = false, .directories = true, .prompt = "Import", .title = "Import a Mechvibes, MechvibesDX or Thock sound pack" }, .{ .ctx = self, .func = onImportPicked });
    }

    fn onImportPicked(ctx: ?*anyopaque, paths: ?[]const []const u8) void {
        const self: *Typebud = @ptrCast(@alignCast(ctx.?));
        const list = paths orelse return;
        if (list.len == 0) return;
        self.importFrom(list[0]);
    }

    pub fn importFrom(self: *Typebud, path: []const u8) void {
        const root = self.userPackDir() catch return;
        var msg_buf: [160]u8 = undefined;
        const id = pack_import.importPack(self.gpa, self.io, path, root) catch |e| {
            self.import_message.set(std.fmt.bufPrint(&msg_buf, "Import failed: {s}", .{pack_import.describe(e)}) catch "Import failed");
            self.redrawSettings();
            return;
        };
        defer self.gpa.free(id);
        _ = self.library.loadUserPack(self.io, root, id) catch |e| {
            self.import_message.set(std.fmt.bufPrint(&msg_buf, "Imported pack is invalid: {t}", .{e}) catch "Import failed");
            self.redrawSettings();
            return;
        };
        self.import_message.set(std.fmt.bufPrint(&msg_buf, "Imported “{s}”", .{id}) catch "Imported");
        self.settings.pack.set(id);
        self.settingsChanged();
    }

    /// Play a short typing phrase with the selected pack (the Sounds page's Preview).
    pub fn previewPack(self: *Typebud) void {
        if (!self.settings.sound) return;
        const pattern = [_]sound.Pool{ .letter, .letter, .letter, .space, .letter, .letter, .enter };
        const S = struct {
            var step: usize = 0;
            fn tick(ctx: *anyopaque) void {
                const tb: *Typebud = @ptrCast(@alignCast(ctx));
                if (step >= pattern.len) return;
                tb.player.play(.down, pattern[step]);
                if (tb.settings.key_up) tb.scheduleKeyUp(pattern[step]);
                step += 1;
                if (step < pattern.len) tb.app.platform.dispatcher().dispatchAfter(130 * std.time.ns_per_ms, .{ .ctx = tb, .run = tick });
            }
        };
        S.step = 0;
        S.tick(self);
    }

    // ---- actions ---------------------------------------------------------------------------

    fn onToggleVisible(self: *Typebud, _: *const ToggleVisible, _: *App) void {
        self.setUserVisible(!self.user_visible);
    }
    fn onTogglePause(self: *Typebud, _: *const TogglePause, _: *App) void {
        self.setPaused(!self.paused);
    }
    fn onOpenSettings(self: *Typebud, _: *const OpenSettings, _: *App) void {
        self.openSettings();
    }
    fn onCheckUpdates(_: *Typebud, _: *const CheckUpdates, _: *App) void {
        update_hook.checkNow(true);
    }
    fn onQuit(self: *Typebud, _: *const Quit, app: *App) void {
        self.flushSave();
        app.quit();
    }
};

pub fn toCorner(c: settings_mod.Corner) platform.OverlayCorner {
    return switch (c) {
        .top_left => .top_left,
        .top_right => .top_right,
        .bottom_left => .bottom_left,
        .bottom_right => .bottom_right,
    };
}

pub fn fromCorner(c: platform.OverlayCorner) settings_mod.Corner {
    return switch (c) {
        .top_left => .top_left,
        .top_right => .top_right,
        .bottom_left => .bottom_left,
        .bottom_right => .bottom_right,
    };
}

/// Rasterize an icon SVG (recoloured with the animal's fur) to a square PNG.
pub fn iconPng(gpa: Allocator, catalog: *const art.Catalog, animal: usize, path: []const u8, px: u32) ![]u8 {
    const src = assets.get(path) orelse return error.MissingIcon;
    const cmap = catalog.colorMap(animal, .bright);
    const buf = try gpa.alloc(u8, src.len);
    defer gpa.free(buf);
    art.recolorInto(buf, src, &cmap);
    var pm = try zpui.image.svg.rasterizeBgra(gpa, buf, .{ .size = .{ .width = @intCast(px), .height = @intCast(px) } }, 0xFF000000);
    defer pm.deinit(gpa);
    return zpui.image.encodePng(gpa, pm.bytes, pm.width, pm.height, .bgra);
}
