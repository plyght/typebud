//! `typebud --demo` (TYPEBUD_DEMO=1): a ~1 minute feature tour for the demo video. It runs
//! in real time on the real windows, feeding synthetic key events into the app (never the
//! OS), with a caption window at the bottom of the screen naming each feature. At the end
//! it writes zig-out/demo/timeline.json (feature, start, end in seconds) and
//! zig-out/demo/audio.wav: the exact typing-sound track it played (same samples, gains and
//! timing), re-rendered offline so a machine without a sound device can mux it in.

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const art = @import("art.zig");
const app_mod = @import("app.zig");
const script = @import("script.zig");
const sound = @import("sound.zig");
const settings_view = @import("settings_view.zig");

const Typebud = app_mod.Typebud;
const Window = zpui.Window;
const out_dir = "zig-out/demo";
const ms = std.time.ns_per_ms;

const Mark = struct { name: []const u8, start: f64, end: f64 = 0 };

const State = struct {
    code: *u8 = undefined,
    runner: script.Runner = undefined,
    typist: script.Typist = .{},
    caption: []const u8 = "",
    caption_window: ?zpui.WindowId = null,
    marks: std.ArrayList(Mark) = .empty,
    recorder: ?sound.Recorder = null,
    start_ns: u64 = 0,
    // animated drags
    anim_step: u32 = 0,
    anim_from: f32 = 0,
    anim_to: f32 = 0,
    animal_step: usize = 0,
};
var st: State = .{};

// ---- caption window -------------------------------------------------------------------

const caption_size: zpui.Size(zpui.Pixels) = .{ .width = 1000, .height = 64 };

pub const CaptionView = struct {
    pub fn init(_: *Window, _: *zpui.Context(CaptionView)) CaptionView {
        return .{};
    }
    pub fn render(_: *CaptionView, _: *Window, _: *zpui.Context(CaptionView)) zpui.Div {
        const pill = zpui.div().flex().itemsCenter().justifyCenter().px(zpui.px(26)).h(zpui.px(48)).rounded(zpui.px(24))
            .bg(zpui.rgba(0x16161ce0).toHsla()).border1().borderColor(zpui.rgba(0xffffff30).toHsla())
            .textColor(zpui.rgb(0xffffff).toHsla()).textSize(zpui.px(21)).fontWeight(600)
            .child(st.caption);
        return zpui.div().size(zpui.relative(1)).flex().itemsCenter().justifyCenter().child(pill);
    }
};

fn openCaption(tb: *Typebud) void {
    var displays: [8]zpui.platform.Display = undefined;
    const n = tb.displays(&displays);
    var margin_x: f32 = 40;
    if (n > 0) margin_x = @max(16, (displays[0].visible_bounds.size.width - caption_size.width) / 2);
    const h = tb.app.openWindow(.{
        .bounds = .{ .origin = .zero, .size = caption_size },
        .titlebar = null,
        .kind = .overlay,
        .background = .transparent,
        .focus = false,
        .mouse_passthrough = true,
        .anchor = .{ .corner = .bottom_left, .margin = .{ .x = margin_x, .y = 28 } },
        .app_id = "typebud-demo-caption",
    }, CaptionView, CaptionView.init, .{}) catch |e| {
        std.log.warn("demo: caption window: {t}", .{e});
        return;
    };
    st.caption_window = h.id;
    if (h.window(tb.app)) |w| w.setInputRegion(&.{});
}

fn caption(tb: *Typebud, text: []const u8) void {
    const t = @as(f64, @floatFromInt(tb.now() - st.start_ns)) / std.time.ns_per_s;
    if (st.marks.items.len > 0) st.marks.items[st.marks.items.len - 1].end = t;
    st.marks.append(tb.gpa, .{ .name = text, .start = t }) catch {};
    st.caption = text;
    std.debug.print("demo {d:6.2}s  {s}\n", .{ t, text });
    if (st.caption_window) |id| if (tb.app.windowById(id)) |w| w.refresh();
}

// ---- tour steps -------------------------------------------------------------------------

fn sLaunch(tb: *Typebud) void {
    const s = &tb.settings;
    s.* = .{};
    s.size = 256;
    s.sound = true;
    s.pack.set("holy-panda");
    s.volume = 0.8;
    s.head = .none;
    s.sleep_after = 0;
    tb.launch();
    st.start_ns = tb.now();
    if (tb.player.audio != null) {
        st.recorder = .{ .gpa = tb.gpa, .clock = nowCb, .clock_ctx = tb };
        tb.player.recorder = &st.recorder.?;
    }
    openCaption(tb);
    caption(tb, "typebud — a typing buddy that lives in a corner of your screen");
    // A peek soon, so the idle look shows its blink.
    tb.state.peek_at = tb.now() + 1500 * ms;
    tb.rearm();
}

fn nowCb(ctx: ?*anyopaque) u64 {
    const tb: *Typebud = @ptrCast(@alignCast(ctx.?));
    return tb.now();
}

fn set(tb: *Typebud) void {
    tb.settingsChanged();
}

fn sTypeLR(tb: *Typebud) void {
    caption(tb, "It types along with you — left paw, right paw");
    st.typist.start(tb, .alternate, 17, 190);
}
fn sHeadphones(tb: *Typebud) void {
    caption(tb, "Headphones: music notes while you type · real switch sounds");
    tb.settings.head = .headphones;
    set(tb);
    st.typist.start(tb, .prose, 21, 150);
}
fn sFast(tb: *Typebud) void {
    caption(tb, "Type fast: both paws… then it gets excited!");
    tb.settings.sensitivity = .eager;
    set(tb);
    st.typist.start(tb, .alternate, 62, 80);
}
fn sStop(tb: *Typebud) void {
    st.typist.stop();
    caption(tb, "Stop typing and it naps (after a minute; 2 s here)");
    tb.settings.sleep_after = 2;
    set(tb);
}
fn sWake(tb: *Typebud) void {
    caption(tb, "Start typing again to wake it up");
    st.typist.start(tb, .prose, 10, 170);
}
fn sAnimals(tb: *Typebud) void {
    tb.settings.sleep_after = 60;
    caption(tb, "Four friends: cat, capybara, penguin and shiba");
    st.animal_step = 0;
    nextAnimal(tb);
}
fn nextAnimal(tb: *Typebud) void {
    const order = [_][]const u8{ "capybara", "penguin", "shiba", "cat" };
    if (st.animal_step >= order.len) return;
    tb.settings.animal.set(order[st.animal_step]);
    set(tb);
    st.typist.start(tb, .prose, 9, 150);
    st.animal_step += 1;
}
fn sAnimalNext(tb: *Typebud) void {
    nextAnimal(tb);
}
fn sVibes(tb: *Typebud) void {
    caption(tb, "Three vibes: dark, bright and pink");
    tb.settings.vibe = .bright;
    set(tb);
}
fn sPink(tb: *Typebud) void {
    tb.settings.vibe = .pink;
    set(tb);
    st.typist.start(tb, .alternate, 6, 160);
}
fn sDark(tb: *Typebud) void {
    tb.settings.vibe = .dark;
    set(tb);
}
fn sKeyboardOff(tb: *Typebud) void {
    caption(tb, "Accessories: the keyboard can go…");
    tb.settings.keyboard = false;
    set(tb);
}
fn sKeyboardOn(tb: *Typebud) void {
    tb.settings.keyboard = true;
    set(tb);
}
fn sHeadItems(tb: *Typebud) void {
    caption(tb, "…and hats: beanie, party hat, bow, glasses");
    tb.settings.head = .beanie;
    set(tb);
}
fn sParty(tb: *Typebud) void {
    tb.settings.head = .party_hat;
    set(tb);
}
fn sBow(tb: *Typebud) void {
    tb.settings.head = .bow;
    set(tb);
}
fn sGlasses(tb: *Typebud) void {
    tb.settings.head = .glasses;
    set(tb);
    st.typist.start(tb, .prose, 6, 150);
}
fn sYuzu(tb: *Typebud) void {
    caption(tb, "The capybara has its own: a yuzu");
    tb.settings.animal.set("capybara");
    tb.settings.head = .yuzu;
    set(tb);
}
fn sHeld(tb: *Typebud) void {
    caption(tb, "Held items: it sips its coffee while you rest…");
    tb.settings.animal.set("cat");
    tb.settings.head = .headphones;
    tb.settings.held = .coffee;
    set(tb);
    tb.state.sip_at = tb.now() + 900 * ms;
    tb.rearm();
}
fn sHeldTyping(tb: *Typebud) void {
    caption(tb, "…and sets it on the desk while you type");
    st.typist.start(tb, .prose, 14, 150);
}
fn sBoba(tb: *Typebud) void {
    caption(tb, "Boba, a book, desk plant, lamp and sparkles");
    tb.settings.held = .boba;
    tb.settings.desk_plant = true;
    set(tb);
    tb.state.sip_at = tb.now() + 700 * ms;
    tb.rearm();
}
fn sBook(tb: *Typebud) void {
    tb.settings.held = .book;
    tb.settings.desk_lamp = true;
    tb.settings.sparkles = true;
    set(tb);
}
fn sResize(tb: *Typebud) void {
    caption(tb, "Hover to show the grip, drag to resize — the corner stays put");
    tb.settings.held = .none;
    tb.settings.desk_lamp = false;
    set(tb);
    tb.hovered = true;
    tb.drag = .resize;
    tb.live_size = tb.settings.size;
    st.anim_from = tb.settings.size;
    st.anim_to = 360;
    st.anim_step = 0;
    animateResize(tb);
}
fn animateResize(tb: *Typebud) void {
    const n_steps: u32 = 40;
    const w = tb.petWindow() orelse return;
    const t = @as(f32, @floatFromInt(st.anim_step)) / n_steps;
    const e = t * t * (3 - 2 * t);
    const size = @round(st.anim_from + (st.anim_to - st.anim_from) * e);
    tb.live_size = size;
    w.resize(.{ .width = size, .height = size });
    w.refresh();
    st.anim_step += 1;
    if (st.anim_step <= n_steps) {
        tb.app.platform.dispatcher().dispatchAfter(25 * ms, .{ .ctx = tb, .run = animResizeTick });
    } else {
        tb.drag = .none;
        tb.settings.size = st.anim_to;
        set(tb);
    }
}
fn animResizeTick(ctx: *anyopaque) void {
    animateResize(@ptrCast(@alignCast(ctx)));
}
fn sShrink(tb: *Typebud) void {
    tb.drag = .resize;
    st.anim_from = tb.settings.size;
    st.anim_to = 220;
    st.anim_step = 0;
    animateResize(tb);
}
fn sMove(tb: *Typebud) void {
    caption(tb, "Drag the pet anywhere — it snaps to the nearest corner");
    tb.hovered = false;
    tb.drag = .move;
    st.anim_step = 0;
    animateMove(tb);
}
fn animateMove(tb: *Typebud) void {
    const n_steps: u32 = 36;
    const w = tb.petWindow() orelse return;
    var displays: [8]zpui.platform.Display = undefined;
    const n = tb.displays(&displays);
    const dw: f32 = if (n > 0) displays[0].visible_bounds.size.width else 1280;
    const t = @as(f32, @floatFromInt(st.anim_step)) / n_steps;
    const e = t * t * (3 - 2 * t);
    // Bottom-right anchor: grow the right margin to slide left across the screen.
    tb.anchor.margin = .{ .x = 16 + (dw * 0.62) * e, .y = 16 + 40 * @sin(e * std.math.pi) };
    w.setAnchor(tb.anchor, tb.display_id);
    st.anim_step += 1;
    if (st.anim_step <= n_steps) {
        tb.app.platform.dispatcher().dispatchAfter(28 * ms, .{ .ctx = tb, .run = animMoveTick });
    } else {
        tb.drag = .none;
        tb.settings.corner = .bottom_left;
        tb.settings.margin_x = 16;
        tb.settings.margin_y = 16;
        set(tb);
    }
}
fn animMoveTick(ctx: *anyopaque) void {
    animateMove(@ptrCast(@alignCast(ctx)));
}
fn sBackRight(tb: *Typebud) void {
    tb.settings.corner = .bottom_right;
    set(tb);
}
fn sSettings(tb: *Typebud) void {
    caption(tb, "Settings — native controls on macOS, GNOME and KDE");
    // A few apps in the visibility list, as a user would have.
    _ = tb.settings.addApp("org.mozilla.firefox", "Firefox");
    _ = tb.settings.addApp("com.microsoft.VSCode", "Visual Studio Code");
    _ = tb.settings.addApp("org.gnome.Terminal", "Terminal");
    tb.settings_section = .character;
    tb.openSettings();
    set(tb);
}
fn section(tb: *Typebud, s: settings_view.Section, text: []const u8) void {
    caption(tb, text);
    tb.settings_section = s;
    tb.redrawSettings();
}
fn sSecAccessories(tb: *Typebud) void {
    section(tb, .accessories, "Accessories: keyboard, head and held items, desk props");
}
fn sSecBehavior(tb: *Typebud) void {
    section(tb, .behavior, "Behavior: size, corner, display, sleep, excitement, reduce motion");
}
fn sSecSounds(tb: *Typebud) void {
    section(tb, .sounds, "Sounds: 9 switch packs, key-ups, auto-mute, Mechvibes import");
}
fn sSecVisibility(tb: *Typebud) void {
    section(tb, .visibility, "Visibility: everywhere, only in some apps, or hidden in some");
}
fn sSecSystem(tb: *Typebud) void {
    section(tb, .system, "System: launch at login, precise typing detection, updates");
}
fn sSecCredits(tb: *Typebud) void {
    section(tb, .credits, "Credits for every sound pack, the font and the framework");
}
fn sTray(tb: *Typebud) void {
    if (tb.settingsWindow()) |w| w.removeWindow();
    caption(tb, if (tb.tray_ok) "Menu bar / tray: show or hide, pause reactions, settings, updates" else "Tray menu: show / hide, pause reactions, settings, updates");
}
fn sOutro(tb: *Typebud) void {
    caption(tb, "typebud · macOS, Windows and Linux");
    st.typist.start(tb, .prose, 12, 160);
}

fn done(tb: *Typebud) void {
    const end_ns = tb.now();
    const t = @as(f64, @floatFromInt(end_ns - st.start_ns)) / std.time.ns_per_s;
    if (st.marks.items.len > 0) st.marks.items[st.marks.items.len - 1].end = t;
    std.Io.Dir.cwd().createDirPath(tb.io, out_dir) catch {};
    writeTimeline(tb, t) catch |e| std.log.err("demo: timeline.json: {t}", .{e});
    if (st.recorder) |*rec| {
        tb.player.recorder = null;
        const wav = rec.renderWav(tb.io, st.start_ns, end_ns, tb.settings.volume) catch |e| blk: {
            std.log.err("demo: audio render: {t}", .{e});
            break :blk null;
        };
        if (wav) |bytes| {
            defer tb.gpa.free(bytes);
            std.Io.Dir.cwd().writeFile(tb.io, .{ .sub_path = out_dir ++ "/audio.wav", .data = bytes }) catch |e| std.log.err("demo: audio.wav: {t}", .{e});
            std.debug.print("demo: wrote {s}/audio.wav ({d} key sounds, {d:.1} s)\n", .{ out_dir, rec.events.items.len, t });
        }
        rec.deinit();
    } else std.debug.print("demo: no audio engine; audio.wav not written\n", .{});
    std.debug.print("demo: done in {d:.1} s, {d} pet frames drawn\n", .{ t, tb.frames_drawn });
    st.code.* = 0;
    tb.app.quit();
}

fn writeTimeline(tb: *Typebud, total: f64) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(tb.gpa);
    try out.print(tb.gpa, "{{\n  \"duration\": {d:.2},\n  \"features\": [\n", .{total});
    for (st.marks.items, 0..) |m, i| {
        try out.print(tb.gpa, "    {{ \"feature\": \"{s}\", \"start\": {d:.2}, \"end\": {d:.2} }}{s}\n", .{ m.name, m.start, m.end, if (i + 1 < st.marks.items.len) "," else "" });
    }
    try out.appendSlice(tb.gpa, "  ]\n}\n");
    try std.Io.Dir.cwd().writeFile(tb.io, .{ .sub_path = out_dir ++ "/timeline.json", .data = out.items });
}

const steps = [_]script.Step{
    .{ .run = sLaunch },
    .{ .wait_ms = 2600, .run = sTypeLR },
    .{ .wait_ms = 3400, .run = sHeadphones },
    .{ .wait_ms = 3400, .run = sFast },
    .{ .wait_ms = 5000, .run = sStop },
    .{ .wait_ms = 3400, .run = sWake },
    .{ .wait_ms = 2100, .run = sAnimals },
    .{ .wait_ms = 1500, .run = sAnimalNext },
    .{ .wait_ms = 1500, .run = sAnimalNext },
    .{ .wait_ms = 1500, .run = sAnimalNext },
    .{ .wait_ms = 1500, .run = sVibes },
    .{ .wait_ms = 1100, .run = sPink },
    .{ .wait_ms = 1100, .run = sDark },
    .{ .wait_ms = 700, .run = sKeyboardOff },
    .{ .wait_ms = 1100, .run = sKeyboardOn },
    .{ .wait_ms = 400, .run = sHeadItems },
    .{ .wait_ms = 700, .run = sParty },
    .{ .wait_ms = 700, .run = sBow },
    .{ .wait_ms = 700, .run = sGlasses },
    .{ .wait_ms = 1000, .run = sYuzu },
    .{ .wait_ms = 1500, .run = sHeld },
    .{ .wait_ms = 2300, .run = sHeldTyping },
    .{ .wait_ms = 2000, .run = sBoba },
    .{ .wait_ms = 1500, .run = sBook },
    .{ .wait_ms = 1300, .run = sResize },
    .{ .wait_ms = 1500, .run = sShrink },
    .{ .wait_ms = 1500, .run = sMove },
    .{ .wait_ms = 1900, .run = sBackRight },
    .{ .wait_ms = 400, .run = sSettings },
    .{ .wait_ms = 1700, .run = sSecAccessories },
    .{ .wait_ms = 1300, .run = sSecBehavior },
    .{ .wait_ms = 1300, .run = sSecSounds },
    .{ .wait_ms = 1300, .run = sSecVisibility },
    .{ .wait_ms = 1300, .run = sSecSystem },
    .{ .wait_ms = 1200, .run = sSecCredits },
    .{ .wait_ms = 1200, .run = sTray },
    .{ .wait_ms = 1800, .run = sOutro },
    .{ .wait_ms = 2200, .run = sEnd },
};

fn sEnd(_: *Typebud) void {}

pub fn start(tb: *Typebud, code: *u8) void {
    st = .{ .code = code };
    st.runner = .{ .tb = tb, .steps = &steps, .done = done };
    st.runner.start();
}
