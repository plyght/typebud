//! First-run welcome: a small window that says hi, lets you pick an animal, a vibe and
//! sounds, and lets you try typing at a live preview pet, all in under a minute. Every
//! choice writes straight into the real settings; Esc, Skip or closing the window keeps
//! whatever is set so far. Shown once (`Settings.onboarding_done`), again from the tray
//! menu or Settings → System.
//!
//! Performance: like the pet, nothing runs while nothing changes. The preview pet has its
//! own `PetState` (the real state machine) with one timer for its next deadline; frames
//! are requested only while something moves (a step slide, a squash, a hop, the excited
//! bob, a sparkle burst). Layer images are cached per size; nothing is allocated per
//! frame beyond zpui's frame arena.

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const art = @import("art.zig");
const raster = @import("raster.zig");
const render_mod = @import("render.zig");
const legends = @import("legends.zig");
const settings_mod = @import("settings.zig");
const pet_state = @import("pet_state.zig");
const app_mod = @import("app.zig");

const Window = zpui.Window;
const App = zpui.App;
const Context = zpui.Context;
const div = zpui.div;
const px = zpui.px;
const prefs = zpui.prefs;
const sb = zpui.StyleBuilder.init;
const Bounds = zpui.Bounds(zpui.Pixels);
const Hsla = zpui.Hsla;
const Settings = settings_mod.Settings;
const Typebud = app_mod.Typebud;
const ms = std.time.ns_per_ms;

/// Bump when the welcome changes enough to be worth showing again (stored, not yet used
/// to re-show).
pub const version: u32 = 1;

pub const window_size: zpui.Size(zpui.Pixels) = .{ .width = 560, .height = 440 };

// ---- model (pure; unit-tested) ----------------------------------------------------------

pub const Step = enum(u8) {
    hello,
    buddy,
    vibe,
    sounds,
    typing,
    done,

    pub const count = @typeInfo(Step).@"enum".field_names.len;
    /// File-name slugs for the smoke screenshots.
    pub const slugs = [_][]const u8{ "hello", "buddy", "vibe", "sounds", "typing", "done" };

    pub fn next(s: Step) Step {
        return if (s == .done) .done else @enumFromInt(@intFromEnum(s) + 1);
    }
    pub fn prev(s: Step) Step {
        return if (s == .hello) .hello else @enumFromInt(@intFromEnum(s) - 1);
    }
    /// The step-dot row covers the five setup steps; `done` fills them all.
    pub fn dots(s: Step) u8 {
        return @intFromEnum(s);
    }
};

pub const Reason = enum { first_run, again };

/// The welcome should open at launch.
pub fn shouldShow(s: *const Settings) bool {
    return !s.onboarding_done;
}

/// Opening the welcome: on the very first run sounds start off (the step offers them).
pub fn begin(s: *Settings, why: Reason) void {
    if (why == .first_run) s.sound = false;
}

/// Finished or skipped: don't show again.
pub fn markDone(s: *Settings) void {
    s.onboarding_done = true;
    s.onboarding_version = version;
}

/// Settings → "Show Welcome Again" / the tray item.
pub fn resetForShowAgain(s: *Settings) void {
    s.onboarding_done = false;
}

pub fn chooseAnimal(s: *Settings, name: []const u8, has_head_item: bool) void {
    s.animal.set(name);
    if (!has_head_item) s.head = .none;
}

pub fn chooseVibe(s: *Settings, v: art.Vibe) void {
    s.vibe = v;
}

pub const Accessory = enum(u8) {
    headphones,
    beanie,
    coffee,

    pub const labels = [_][]const u8{ "Headphones", "Beanie", "Coffee" };

    pub fn isOn(a: Accessory, s: *const Settings) bool {
        return switch (a) {
            .headphones => s.head == .headphones,
            .beanie => s.head == .beanie,
            .coffee => s.held == .coffee,
        };
    }
};

/// Tap an accessory chip: head items replace each other; tapping the worn one takes it off.
pub fn toggleAccessory(s: *Settings, a: Accessory) void {
    const on = a.isOn(s);
    switch (a) {
        .headphones => s.head = if (on) .none else .headphones,
        .beanie => s.head = if (on) .none else .beanie,
        .coffee => s.held = if (on) .none else .coffee,
    }
}

pub fn setSound(s: *Settings, on: bool) void {
    s.sound = on;
}

/// A key name (zpui spelling) as the pet's key class and board position (QWERTY halves).
pub fn classify(key: []const u8) pet_state.KeyEvent {
    const eq = std.mem.eql;
    if (eq(u8, key, "space")) return .{ .key = .space, .t = 0 };
    if (eq(u8, key, "enter")) return .{ .key = .enter, .t = 0 };
    if (eq(u8, key, "backspace") or eq(u8, key, "delete")) return .{ .key = .backspace, .key_x = 0.9, .t = 0 };
    if (eq(u8, key, "tab")) return .{ .key = .tab, .key_x = 0.05, .t = 0 };
    if (eq(u8, key, "left") or eq(u8, key, "right") or eq(u8, key, "up") or eq(u8, key, "down")) return .{ .key = .arrow, .key_x = 0.85, .t = 0 };
    if (key.len == 1) {
        const c = std.ascii.toLower(key[0]);
        const left = "`12345qwertasdfgzxcvb";
        const x: f32 = if (std.mem.indexOfScalar(u8, left, c) != null) 0.25 else 0.75;
        return .{ .key = if (std.ascii.isDigit(c)) .digit else .letter, .key_x = x, .t = 0 };
    }
    return .{ .key = .other, .t = 0 };
}

// ---- state ------------------------------------------------------------------------------

const text_cap = 120;

const State = struct {
    window: ?zpui.WindowId = null,
    /// The pet window stays hidden while the welcome is open.
    active: bool = false,
    finished: bool = false,
    step: Step = .hello,
    /// +1 forward, -1 back (slide direction).
    dir: i8 = 1,
    pet: pet_state.PetState = .{},
    armed_at: ?u64 = null,
    prev_mode: pet_state.Mode = .idle,
    burst_at: u64 = 0,
    hover_card: ?u8 = null,
    pick_at: u64 = 0,
    picked: u8 = 0,
    text: [text_cap]u8 = undefined,
    text_len: usize = 0,
    last_keydown: u64 = 0,
    keys: u32 = 0,
    names: [art.max_animals][16]u8 = undefined,
    pack_names: [32][]const u8 = undefined,
    pack_count: usize = 0,
    // scripted typing (smoke / demo)
    script_text: []const u8 = "",
    script_i: usize = 0,
    script_gap: u64 = 0,
    script_id: u32 = 0,
};
var ob: State = .{};

/// The welcome window hides the pet.
pub fn hidesPet() bool {
    return ob.active;
}

pub fn currentStep() Step {
    return ob.step;
}

/// Keys the preview pet has seen and the try-it text (smoke checks).
pub fn keysSeen() u32 {
    return ob.keys;
}
pub fn typedText() []const u8 {
    return ob.text[0..ob.text_len];
}
pub fn clearText() void {
    ob.text_len = 0;
}
pub fn previewMode() pet_state.Mode {
    return ob.pet.mode;
}

pub fn window(tb: *Typebud) ?*Window {
    const id = ob.window orelse return null;
    return tb.app.windowById(id) orelse {
        ob.window = null;
        return null;
    };
}

fn previewConfig(tb: *Typebud) pet_state.Config {
    var c = tb.stateConfig();
    c.sleep_after = 0; // no naps during the welcome
    return c;
}

/// Open (or raise) the welcome window.
pub fn open(tb: *Typebud, why: Reason) void {
    const mac = builtin.os.tag == .macos;
    if (mac) tb.app.activate(true);
    if (window(tb)) |w| {
        w.activateWindow();
        return;
    }
    if (why == .again) resetForShowAgain(&tb.settings);
    begin(&tb.settings, why);
    tb.settingsChanged();
    const now = tb.now();
    ob = .{ .active = true };
    ob.pet = pet_state.PetState.init(now, previewConfig(tb));
    // Say hi: a hop as the window appears, then a peek.
    ob.pet.hop(now + 150 * ms);
    ob.pet.peek_at = now + 1100 * ms;
    for (tb.catalog.list(), 0..) |a, i| {
        const n = @min(a.name.len, ob.names[i].len);
        @memcpy(ob.names[i][0..n], a.name[0..n]);
        if (n > 0) ob.names[i][0] = std.ascii.toUpper(ob.names[i][0]);
    }
    ob.pack_count = @min(tb.library.packs.items.len, ob.pack_names.len);
    for (tb.library.packs.items[0..ob.pack_count], 0..) |p, i| ob.pack_names[i] = p.name;

    // Centered on the main display.
    var displays: [8]zpui.platform.Display = undefined;
    const nd = tb.displays(&displays);
    var origin: zpui.Point(zpui.Pixels) = .{ .x = 200, .y = 160 };
    if (nd > 0) {
        var d = displays[0];
        for (displays[0..nd]) |x| if (x.primary) {
            d = x;
        };
        const vb = d.visible_bounds;
        origin = .{ .x = @round((vb.size.width - window_size.width) / 2), .y = @round((vb.size.height - window_size.height) / 2.4) };
    }
    const title = "Welcome to typebud";
    const handle = tb.app.openWindow(.{
        .bounds = .{ .origin = origin, .size = window_size },
        // macOS: full-size content under a hidden, transparent title; traffic lights in
        // our own header band. Windows: the system caption over Mica. Linux: drawn.
        .titlebar = switch (builtin.os.tag) {
            .macos => .{ .title = title, .appears_transparent = true, .traffic_light_position = .{ .x = 14, .y = 13 } },
            .windows => .{ .title = title },
            else => null,
        },
        .app_id = if (mac) app_mod.bundle_id else app_mod.app_id,
        .min_size = window_size,
        .background = if (builtin.os.tag == .windows) .blurred else .opaque_,
        .display_id = if (nd > 0) displays[0].id else null,
    }, OnboardingView, OnboardingView.init, .{}) catch |e| {
        std.log.err("welcome window: {t}", .{e});
        ob.active = false;
        markDone(&tb.settings);
        tb.settingsChanged();
        return;
    };
    ob.window = handle.id;
    tb.updateVisibility();
    if (handle.window(tb.app)) |w| w.activateWindow();
    rearm(tb);
}

/// Finish (Done) or skip (Esc, Skip, close): remember, close, and let the pet hop in.
pub fn finish(tb: *Typebud) void {
    if (ob.finished or !ob.active) return;
    ob.finished = true;
    ob.active = false;
    ob.script_id +%= 1;
    markDone(&tb.settings);
    tb.settingsChanged();
    if (window(tb)) |w| w.removeWindow();
    ob.window = null;
    tb.updateVisibility();
    tb.redrawPet();
    // Hop once the window is on screen.
    tb.app.platform.dispatcher().dispatchAfter(260 * ms, .{ .ctx = tb, .run = petHop });
}

fn petHop(ctx: *anyopaque) void {
    const tb: *Typebud = @ptrCast(@alignCast(ctx));
    tb.state.hop(tb.now());
    tb.rearm();
    tb.redrawPet();
}

pub fn goTo(tb: *Typebud, s: Step) void {
    if (s == ob.step) return;
    ob.dir = if (@intFromEnum(s) > @intFromEnum(ob.step)) 1 else -1;
    ob.step = s;
    ob.hover_card = null;
    const now = tb.now();
    // A little hop to greet each step (the done step gets a bigger cheer: sparkles).
    if (s == .done) ob.burst_at = now + 120 * ms;
    ob.pet.hop(now + 80 * ms);
    rearm(tb);
    refresh(tb);
}

pub fn refresh(tb: *Typebud) void {
    if (window(tb)) |w| w.refresh();
}

// ---- preview pet ------------------------------------------------------------------------

/// A key went down in the welcome window (or a scripted one): the preview pet reacts.
pub fn feedKey(tb: *Typebud, key: []const u8) void {
    const now = tb.now();
    var e = classify(key);
    e.t = now;
    ob.last_keydown = now;
    ob.keys += 1;
    ob.pet.onKey(e);
    if (ob.pet.mode == .excited and ob.prev_mode != .excited) ob.burst_at = now;
    ob.prev_mode = ob.pet.mode;
    rearm(tb);
    refresh(tb);
}

fn insertText(text: []const u8) void {
    for (text) |c| {
        if (c < 0x20 and c != '\t') continue;
        if (ob.text_len == text_cap) {
            // Keep the tail (what is visible).
            std.mem.copyForwards(u8, ob.text[0 .. text_cap - 40], ob.text[40..text_cap]);
            ob.text_len = text_cap - 40;
        }
        ob.text[ob.text_len] = if (c == '\t') ' ' else c;
        ob.text_len += 1;
    }
}

fn deleteBack() void {
    if (ob.text_len == 0) return;
    ob.text_len -= 1;
    while (ob.text_len > 0 and (ob.text[ob.text_len] & 0xC0) == 0x80) ob.text_len -= 1;
}

fn rearm(tb: *Typebud) void {
    const now = tb.now();
    const d = ob.pet.nextDeadline(now) orelse return;
    if (ob.armed_at) |a| if (a <= d and a > now) return;
    ob.armed_at = d;
    tb.app.platform.dispatcher().dispatchAfter(d - now, .{ .ctx = tb, .run = onTimer });
}

fn onTimer(ctx: *anyopaque) void {
    const tb: *Typebud = @ptrCast(@alignCast(ctx));
    if (!ob.active) return;
    const now = tb.now();
    if (ob.armed_at) |a| if (now + ms >= a) {
        ob.armed_at = null;
    };
    if (ob.pet.update(now)) {
        if (ob.pet.mode == .excited and ob.prev_mode != .excited) ob.burst_at = now;
        ob.prev_mode = ob.pet.mode;
        refresh(tb);
    }
    rearm(tb);
}

/// Scripted typing into the try-it field (smoke / demo): one character every `gap_ms`.
pub fn scriptType(tb: *Typebud, text: []const u8, gap_ms: u32) void {
    ob.script_id +%= 1;
    ob.script_text = text;
    ob.script_i = 0;
    ob.script_gap = @as(u64, gap_ms) * ms;
    scriptTick(tb);
}

const ScriptTick = struct {
    var ctx: struct { tb: *Typebud, id: u32 } = undefined;
};

fn scriptTick(tb: *Typebud) void {
    if (!ob.active or ob.script_i >= ob.script_text.len) return;
    const c = ob.script_text[ob.script_i];
    ob.script_i += 1;
    var kb: [1]u8 = .{c};
    feedKey(tb, if (c == ' ') "space" else kb[0..1]);
    insertText(kb[0..1]);
    refresh(tb);
    ScriptTick.ctx = .{ .tb = tb, .id = ob.script_id };
    tb.app.platform.dispatcher().dispatchAfter(ob.script_gap, .{ .ctx = &ScriptTick.ctx, .run = onScriptTimer });
}

fn onScriptTimer(ctx: *anyopaque) void {
    const c: *@TypeOf(ScriptTick.ctx) = @ptrCast(@alignCast(ctx));
    if (c.id != ob.script_id) return;
    scriptTick(c.tb);
}

// ---- view -------------------------------------------------------------------------------

const star_svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 40"><path d="M20 3 Q22.6 17.4 37 20 Q22.6 22.6 20 37 Q17.4 22.6 3 20 Q17.4 17.4 20 3 Z" fill="#FBE3A0" stroke="#3B2A1E" stroke-width="3" stroke-linejoin="round"/></svg>
;
const star_logical: f32 = 40;
const burst_len: u64 = 900 * ms;
const pick_len: u64 = 380 * ms;

const content_w: f32 = window_size.width - 2 * 28;
const card_w: f32 = 114;
const card_h: f32 = 158;
const card_pet: f32 = 112;

pub const OnboardingView = struct {
    focus: zpui.FocusHandle,
    stage_cache: raster.LayerCache,
    card_cache: raster.LayerCache,
    layout: legends.Layout = .{},
    star: ?raster.Image = null,
    star_px: u32 = 0,
    card_px: u32 = 0,
    focused_typing: bool = false,

    pub fn init(window_: *Window, cx: *Context(OnboardingView)) OnboardingView {
        window_.setDesktopControls(true);
        const focus = cx.focusHandle();
        window_.focus(focus);
        const tb = app_mod.instance;
        return .{ .focus = focus, .stage_cache = .init(tb.gpa, tb.catalog), .card_cache = .init(tb.gpa, tb.catalog) };
    }

    pub fn deinit(self: *OnboardingView, app: *App) void {
        self.focus.release(app);
        if (self.star) |s| s.img.release();
        self.star = null;
        self.stage_cache.atlas = null;
        self.stage_cache.deinit();
        self.card_cache.atlas = null;
        self.card_cache.deinit();
        // Closed by the window's close button: same as skipping.
        if (ob.active and !ob.finished) {
            ob.window = null;
            finish(app_mod.instance);
        }
    }

    pub fn render(self: *OnboardingView, w: *Window, cx: *Context(OnboardingView)) zpui.StatefulDiv {
        const tb = app_mod.instance;
        const look = lookOf(w);
        const family = zpui.desktop_controls.fontFamily(w, look);
        const step = ob.step;
        if (step == .typing and !self.focused_typing) {
            w.focus(self.focus);
            self.focused_typing = true;
        } else if (step != .typing) self.focused_typing = false;

        const bg: Hsla = if (builtin.os.tag == .windows) zpui.color.transparent_black else look.window_bg;
        var root = div().id("welcome").relative().size(zpui.relative(1)).flex().flexCol().overflowHidden()
            .bg(bg).fontFamily(family).textSize(px(13)).textColor(look.fg)
            .trackFocus(self.focus)
            .onKeyDown(cx.listener(OnboardingView.onKey))
            .role(.group).ariaLabel("Welcome to typebud");
        root = root.child(self.header(w, look, cx));

        const body = div().id(.{ "ob-step", @intFromEnum(step) }).relative().flex1().minH(px(0)).flex().flexCol().itemsCenter().px(px(28))
            .child(self.stepBody(w, look, cx, tb));
        root = root.child(zpui.withAnimationCtx(body, .{ "ob-slide", @intFromEnum(step) }, zpui.Animation.ms(200).withEasing(zpui.easing.ease_out_expo), ob.dir, slide));
        return root.child(self.footer(look, cx));
    }

    fn slide(dir: i8, el: zpui.StatefulDiv, t: f32) zpui.StatefulDiv {
        return el.opacity(t).left(px(@as(f32, @floatFromInt(dir)) * 22 * (1 - t)));
    }

    // ---- header: step dots, Skip ----------------------------------------------------------

    fn header(_: *OnboardingView, w: *Window, look: prefs.Look, cx: *Context(OnboardingView)) zpui.StatefulDiv {
        const h: f32 = switch (builtin.os.tag) {
            .macos => 40,
            .windows => 34,
            else => 44,
        };
        var dots = div().id("ob-dots").flex().flexRow().itemsCenter().gap(px(7)).role(.progress_indicator).ariaLabel("Setup progress");
        const filled = ob.step.dots();
        for (0..5) |i| {
            const on = i < filled or (i == filled and ob.step != .done);
            const current = i == filled;
            dots = dots.child(div().h(px(7)).w(px(if (current) 20 else 7)).roundedFull()
                .bg(if (on) look.accent else look.fg_dim.alpha(0.28)));
        }
        var bar = div().id("ob-header").relative().flex().flexNone().itemsCenter().justifyCenter().h(px(h)).wFull().child(dots);
        if (builtin.os.tag == .linux) bar = bar.onMouseDown(.left, cx.listener(OnboardingView.onHeaderDown));
        if (ob.step != .done) {
            bar = bar.child(div().id("ob-skip").absolute().right(px(14)).top(px((h - 24) / 2)).h(px(24)).px(px(10)).flex().itemsCenter()
                .rounded(px(12)).textColor(look.fg_dim).textSize(px(12.5)).cursorPointer()
                .hover(sb.bg(look.button_hover).textColor(look.fg))
                .role(.button).ariaLabel("Skip setup")
                .onClick(cx.listener(OnboardingView.onSkip))
                .child("Skip"));
        }
        _ = w;
        return bar;
    }

    // ---- footer: Back, primary ------------------------------------------------------------

    fn footer(_: *OnboardingView, look: prefs.Look, cx: *Context(OnboardingView)) zpui.Div {
        const step = ob.step;
        const label: []const u8 = switch (step) {
            .hello => "Let's go",
            .typing => "Looks good",
            .done => "Done",
            else => "Next",
        };
        var row = div().flex().flexNone().flexRow().itemsCenter().h(px(64)).px(px(28)).pb(px(6)).wFull();
        if (step != .hello and step != .done) {
            row = row.child(pushButton(look, .back, "Back", true, cx));
        }
        row = row.child(div().flex1());
        return row.child(primaryButton(look, "ob-next", label, cx.listener(OnboardingView.onNext)));
    }

    // ---- steps -----------------------------------------------------------------------------

    fn stepBody(self: *OnboardingView, w: *Window, look: prefs.Look, cx: *Context(OnboardingView), tb: *Typebud) zpui.Div {
        const s = &tb.settings;
        return switch (ob.step) {
            .hello => stack(self.stage(look, 226), "Hi, I'm your typebud!", "I'll sit in a corner of your screen and tap along on my little keyboard whenever you type.", look, null),
            .buddy => stack(self.cards(w, look, cx, tb), "Who's your buddy?", "Pick a friend to keep you company. You can always swap later in Settings.", look, null),
            .vibe => stack(self.stage(look, 176), "Pick a vibe", "Choose the colors for my keyboard, and add a little extra if you like.", look, zpui.intoAnyElement(vibeRow(look, cx, tb))),
            .sounds => stack(self.stage(look, 168), "Want clicky sounds?", "I can play soft mechanical clicks as you type, and I'll hush on my own while you're on a call.", look, zpui.intoAnyElement(soundRow(look, cx, tb, s))),
            .typing => stack(self.stage(look, 146), "Try typing!", "Type anything below and watch me tap along. Type really fast and I get excited!", look, zpui.intoAnyElement(self.typingBox(w, look, cx.entity(), tb))),
            .done => stack(self.stage(look, 226), "All set! I'll be waiting in the corner.", doneText(tb), look, null),
        };
    }

    fn doneText(tb: *Typebud) []const u8 {
        if (!tb.tray_ok and !tb.options.scripted) return "Double-click me whenever you'd like to open Settings, or drag me to any corner you like.";
        return switch (builtin.os.tag) {
            .macos => "Click my little face in the menu bar whenever you'd like to open Settings.",
            else => "You'll find Settings behind my little face in the system tray whenever you need it.",
        };
    }

    fn stack(visual: anytype, title: []const u8, text: []const u8, look: prefs.Look, extra: ?zpui.AnyElement) zpui.Div {
        var col = div().flex().flexCol().itemsCenter().wFull()
            .child(visual)
            .child(div().id("ob-title").mt(px(16)).fontFamily("Nunito").fontWeight(800).textSize(px(22)).textColor(look.fg).textCenter().role(.heading).child(title))
            .child(div().mt(px(5)).maxW(px(430)).textSize(px(13.5)).lineHeight(px(19)).textColor(look.fg_dim).textCenter().child(text));
        if (extra) |e| col = col.child(div().mt(px(14)).flex().justifyCenter().wFull().child(e));
        return col;
    }

    fn stage(self: *OnboardingView, look: prefs.Look, h: f32) zpui.Div {
        const tb = app_mod.instance;
        const vibe: art.Vibe = if (ob.step == .hello) .bright else tb.settings.vibe;
        const c = stageColors(vibe, look.dark);
        const grad = zpui.color.linearGradient(160, zpui.color.linearColorStop(c[0], 0), zpui.color.linearColorStop(c[1], 1));
        var st = div().relative().wFull().h(px(h)).flexNone().rounded(px(18)).bg(grad).overflowHidden()
            .border1().borderColor(look.fg.alpha(0.06))
            .child(zpui.canvas(self, paintStage).absolute().inset0());
        const say: ?[]const u8 = switch (ob.step) {
            .hello => "hi!",
            .done => "yay!",
            .typing => if (ob.pet.mode == .excited) "so fast!" else null,
            else => null,
        };
        if (say) |text| {
            // Next to the head, as the stage canvas centers the pet.
            const a = &tb.catalog.animals[tb.animal];
            const unit = (h - 2) / 256;
            const x = content_w / 2 + (a.anchors.head.cx - 128 + a.anchors.head.rx + 6) * unit;
            const y = @max(8, (a.anchors.head.cy - a.anchors.head.ry - 18) * unit);
            const ink = zpui.rgb(0x3b2a1e).toHsla();
            const paper = zpui.rgb(0xfffdf8).toHsla();
            const bubble = div().id(.{ "ob-say", @intFromEnum(ob.step) }).absolute().left(px(x)).top(px(y)).flex().flexCol().itemsStart()
                .child(div().px(px(10)).py(px(2)).rounded(px(12)).bg(paper).border2().borderColor(ink)
                .fontFamily("Nunito").fontWeight(800).textSize(px(14)).textColor(ink).child(text))
                .child(div().ml(px(5)).mt(px(2)).w(px(7)).h(px(7)).roundedFull().bg(paper).border2().borderColor(ink))
                .child(div().ml(px(1)).mt(px(1)).w(px(4)).h(px(4)).roundedFull().bg(ink));
            st = st.child(zpui.withAnimation(bubble, .{ "ob-say-in", @as(usize, @intFromEnum(ob.step)) * 8 + @intFromEnum(ob.pet.mode) }, zpui.Animation.ms(260).withEasing(zpui.easing.ease_out_expo), popIn));
        }
        return st;
    }

    fn popIn(el: zpui.StatefulDiv, t: f32) zpui.StatefulDiv {
        return el.opacity(t).mt(px(8 * (1 - t)));
    }

    fn cards(self: *OnboardingView, w: *Window, look: prefs.Look, cx: *Context(OnboardingView), tb: *Typebud) zpui.StatefulDiv {
        _ = w;
        var row = div().id("ob-animals").flex().flexRow().gap(px(10)).h(px(206)).itemsCenter().justifyCenter().role(.group).ariaLabel("Animals");
        const c = stageColors(tb.settings.vibe, look.dark);
        for (0..tb.catalog.count) |i| {
            const on = i == tb.animal;
            const ctx = CardCtx{ .view = self, .index = @intCast(i) };
            const label_len = @min(tb.catalog.animals[i].name.len, ob.names[i].len);
            var card = div().id(.{ "ob-animal", i }).relative().flex().flexCol().itemsCenter().w(px(card_w)).h(px(card_h)).rounded(px(16))
                .bg(if (on) zpui.color.linearGradient(180, zpui.color.linearColorStop(c[0], 0), zpui.color.linearColorStop(c[1], 1)) else zpui.color.solidBackground(look.card_bg))
                .border2().borderColor(if (on) look.accent else look.fg.alpha(0.07))
                .cursorPointer().hover(sb.borderColor(if (on) look.accent else look.accent.alpha(0.45)))
                .role(.radio_button).ariaLabel(tb.catalog.animals[i].name).ariaToggled(on)
                .onHover(cx.listenerWith(@as(u8, @intCast(i)), OnboardingView.onCardHover))
                .onClick(cx.listenerWith(@as(u8, @intCast(i)), OnboardingView.onAnimal));
            if (!on) card = card.shadowSm();
            card = card.child(zpui.canvas(ctx, paintCard).w(px(card_pet)).h(px(card_pet)).mt(px(8)))
                .child(div().mt(px(6)).fontFamily("Nunito").fontWeight(800).textSize(px(14)).textColor(look.fg).child(ob.names[i][0..label_len]));
            row = row.child(card);
        }
        return row;
    }

    fn typingBox(self: *OnboardingView, w: *Window, look: prefs.Look, entity: zpui.Entity(OnboardingView), tb: *Typebud) zpui.Div {
        const focused = self.focus.isFocused(w);
        // The visible tail of what was typed.
        var start: usize = ob.text_len -| 46;
        while (start > 0 and start < ob.text_len and (ob.text[start] & 0xC0) == 0x80) start += 1;
        const shown = ob.text[start..ob.text_len];
        const field_bg = if (look.dark) look.fg.alpha(0.07) else zpui.rgb(0xffffff).toHsla();
        var line = div().flex().flexRow().itemsCenter().overflowHidden().whitespaceNowrap().h(px(20));
        if (shown.len == 0) {
            line = line.child(caret(look, focused)).child(div().textColor(look.fg_dim.alpha(0.8)).child("Type anything here…"));
        } else line = line.child(div().textColor(look.fg).child(shown)).child(caret(look, focused));
        const field = div().id("ob-field").relative().flex().itemsCenter().w(px(380)).h(px(36)).px(px(12)).rounded(px(look.button_radius + 2))
            .bg(field_bg).border1().borderColor(if (focused) look.accent else look.outline.alpha(0.9)).cursor(.ibeam)
            .role(.text_input).ariaLabel("Try typing")
            .child(zpui.canvas(InputCtx{ .focus = self.focus, .entity = entity }, registerInput).absolute().inset0())
            .child(line);
        var col = div().flex().flexCol().itemsCenter().gap(px(8)).child(field)
            .child(div().maxW(px(500)).textSize(px(11.5)).lineHeight(px(15)).textColor(look.fg_dim).textCenter()
            .child("Out in your other apps, I only notice that a key was pressed, never what you typed."));
        if (platformNote(tb)) |note| col = col.child(note.render(look));
        return col;
    }

    // ---- painting ----------------------------------------------------------------------------

    fn ensureStar(self: *OnboardingView, scale: f32) void {
        const tb = app_mod.instance;
        const want: u32 = @intFromFloat(@round(star_logical * scale));
        if (want == self.star_px) return;
        if (self.star) |s| s.img.release();
        self.star = null;
        self.star_px = want;
        var pm = zpui.image.svg.rasterizeBgra(tb.gpa, star_svg, .{ .size = .{ .width = @intCast(want), .height = @intCast(want) } }, 0xFF000000) catch return;
        defer pm.deinit(tb.gpa);
        self.star = raster.cropToImage(tb.gpa, pm.bytes, pm.width, pm.height, want) catch null;
    }

    fn paintStar(self: *OnboardingView, w: *Window, cx_: f32, cy: f32, size: f32, alpha: f32) void {
        const img = self.star orelse return;
        if (alpha <= 0.01 or size <= 0.5) return;
        const s = size / @as(f32, @floatFromInt(img.px));
        const b: Bounds = .{
            .origin = .{ .x = cx_ - size / 2 + @as(f32, @floatFromInt(img.x)) * s, .y = cy - size / 2 + @as(f32, @floatFromInt(img.y)) * s },
            .size = .{ .width = @as(f32, @floatFromInt(img.w)) * s, .height = @as(f32, @floatFromInt(img.h)) * s },
        };
        const prev = w.pushOpacity(alpha);
        defer w.popOpacity(prev);
        w.paintImage(b, .all(0), img.img, 0, false);
    }

    fn paintStage(self: *OnboardingView, b: Bounds, w: *Window, _: *App) void {
        const tb = app_mod.instance;
        const now = tb.now();
        _ = ob.pet.update(now);
        if (ob.pet.mode == .excited and ob.prev_mode != .excited) ob.burst_at = now;
        ob.prev_mode = ob.pet.mode;
        const scale = w.scaleFactor();
        self.ensureStar(scale);
        // Background twinkles.
        const twinkles = [_][4]f32{ .{ 0.11, 0.26, 16, 0.9 }, .{ 0.88, 0.2, 12, 0.75 }, .{ 0.8, 0.78, 18, 0.85 }, .{ 0.17, 0.8, 11, 0.6 }, .{ 0.95, 0.52, 8, 0.5 }, .{ 0.05, 0.55, 8, 0.45 } };
        for (twinkles) |t| self.paintStar(w, b.origin.x + t[0] * b.size.width, b.origin.y + t[1] * b.size.height, t[2], t[3]);

        const size = b.size.height - 2;
        const ox = b.origin.x + (b.size.width - size) / 2;
        const oy = b.origin.y + (b.size.height - size) / 2 + 3;
        const rp: u32 = @intFromFloat(@round(size * scale));
        self.stage_cache.atlas = w.sprite_atlas;
        self.stage_cache.retainOnly(tb.animal, tb.settings.vibe, rp);
        const kb = art.Affine.keyboard(tb.catalog.animals[tb.animal].anchors.keyboard);
        if (tb.font_id) |fid| if (!self.layout.matches(size, scale, kb)) legends.layout(&self.layout, tb.app.textSystem(), fid, &tb.keys, size, scale, kb);
        const frame = ob.pet.frame(now);
        const m = ob.pet.motion(now);
        const head = tb.catalog.animals[tb.animal].anchors.head;
        var outfit = tb.outfit(frame);
        if (ob.step == .hello or ob.step == .done) outfit.sparkles = true;
        const pet: render_mod.Pet = .{
            .animal = tb.animal,
            .vibe = tb.settings.vibe,
            .frame = frame,
            .outfit = outfit,
            .motion = .{ .dy = m.dy, .squash = m.squash, .pivot = .{ head.cx, 236 } },
            .origin = .{ ox, oy },
            .size = size,
            .raster_px = rp,
            .legend_size = size,
        };
        var wp: render_mod.WindowPainter = .{ .window = w };
        render_mod.paint(pet, .{ .catalog = tb.catalog, .cache = &self.stage_cache, .legend_layout = if (tb.font_id != null) &self.layout else null, .legend_colors = render_mod.legendColors(tb.catalog) }, wp.painter());

        // Sparkle burst around the head (excited, or the done cheer).
        var bursting = false;
        if (ob.burst_at != 0 and now >= ob.burst_at and now - ob.burst_at < burst_len and tb.settings.animations) {
            bursting = true;
            const t = @as(f32, @floatFromInt(now - ob.burst_at)) / @as(f32, @floatFromInt(burst_len));
            const e = 1 - (1 - t) * (1 - t) * (1 - t);
            const unit = size / 256;
            const hx = ox + head.cx * unit;
            const hy = oy + head.cy * unit;
            for (0..7) |i| {
                const ang = (@as(f32, @floatFromInt(i)) / 7.0) * std.math.tau - std.math.pi / 2.0 + 0.3;
                const r = (52 + 70 * e) * unit;
                const sz = (20 - 8 * t) * unit * (if (i % 2 == 0) @as(f32, 1.0) else 0.7);
                self.paintStar(w, hx + @cos(ang) * r * 1.25, hy + @sin(ang) * r, sz, 1 - t * t);
            }
        } else if (ob.burst_at != 0 and now < ob.burst_at) bursting = true;
        if (bursting or ob.pet.animating(now)) w.requestAnimationFrame();
    }

    const CardCtx = struct { view: *OnboardingView, index: u8 };

    fn paintCard(c: CardCtx, b: Bounds, w: *Window, _: *App) void {
        const tb = app_mod.instance;
        const self = c.view;
        const i: usize = c.index;
        const now = tb.now();
        const scale = w.scaleFactor();
        const rp: u32 = @intFromFloat(@round(b.size.width * scale));
        self.card_cache.atlas = w.sprite_atlas;
        if (rp != self.card_px) {
            self.card_cache.clear();
            self.card_px = rp;
        }
        const on = i == tb.animal;
        const hovered = ob.hover_card != null and ob.hover_card.? == c.index;
        const frame: art.Frame = if (on) .type_left else if (hovered) .peek else .idle;
        var outfit = tb.settings.outfit();
        outfit.held = .none;
        outfit.desk = .{};
        outfit.sparkles = false;
        if (!tb.catalog.animals[i].hasHeadItem(outfit.head)) outfit.head = .none;
        var dy: f32 = 0;
        var animating = false;
        if (on and ob.pick_at != 0 and now - ob.pick_at < pick_len and tb.settings.animations) {
            const t = @as(f32, @floatFromInt(now - ob.pick_at)) / @as(f32, @floatFromInt(pick_len));
            dy = pet_state.hopOffset(t) * 0.8;
            animating = true;
        }
        const head = tb.catalog.animals[i].anchors.head;
        const pet: render_mod.Pet = .{
            .animal = i,
            .vibe = tb.settings.vibe,
            .frame = frame,
            .outfit = outfit,
            .motion = .{ .dy = dy, .pivot = .{ head.cx, 236 } },
            .origin = .{ b.origin.x, b.origin.y },
            .size = b.size.width,
            .raster_px = rp,
            .legend_size = b.size.width,
        };
        var wp: render_mod.WindowPainter = .{ .window = w };
        render_mod.paint(pet, .{ .catalog = tb.catalog, .cache = &self.card_cache, .legend_layout = null, .legend_colors = render_mod.legendColors(tb.catalog) }, wp.painter());
        if (animating) w.requestAnimationFrame();
    }

    // ---- input ------------------------------------------------------------------------------

    pub fn replaceTextInRange(_: *OnboardingView, _: ?zpui.platform.InputHandler.Range, text: []const u8, _: *Window, _: *Context(OnboardingView)) void {
        if (ob.step != .typing) return;
        const tb = app_mod.instance;
        // Keys that arrive only as text (IME, some layouts) still make the pet tap.
        if (tb.now() -| ob.last_keydown > 40 * ms) feedKey(tb, if (text.len == 1) text else "x");
        insertText(text);
        refresh(tb);
    }

    pub fn acceptsTextInput(_: *OnboardingView, _: *Window, _: *Context(OnboardingView)) bool {
        return ob.step == .typing;
    }

    fn onKey(_: *OnboardingView, ev: *const zpui.input.KeyDownEvent, w: *Window, cx: *Context(OnboardingView)) void {
        const tb = app_mod.instance;
        const ks = ev.keystroke;
        const m = ks.modifiers;
        const eq = std.mem.eql;
        if (eq(u8, ks.key, "escape")) return finish(tb);
        if (m.platform and !m.control and !m.alt and eq(u8, ks.key, "w")) return finish(tb);
        if (m.platform or m.control) return;
        if (ob.step == .typing) {
            if (ev.is_held and !eq(u8, ks.key, "backspace")) return;
            feedKey(tb, ks.key);
            if (eq(u8, ks.key, "backspace")) deleteBack();
            if (eq(u8, ks.key, "enter") and m.alt) goTo(tb, ob.step.next());
            cx.notify();
            return;
        }
        if (eq(u8, ks.key, "enter")) {
            next(tb);
            cx.notify();
        } else if (eq(u8, ks.key, "right") and ob.step != .done) {
            goTo(tb, ob.step.next());
        } else if (eq(u8, ks.key, "left")) {
            goTo(tb, ob.step.prev());
        } else if (ob.step == .buddy and ks.key.len == 1 and ks.key[0] >= '1' and ks.key[0] <= '9') {
            const i: usize = ks.key[0] - '1';
            if (i < tb.catalog.count) pickAnimal(tb, @intCast(i));
        }
        _ = w;
    }

    fn onHeaderDown(_: *OnboardingView, ev: *const zpui.input.MouseDownEvent, w: *Window, _: *Context(OnboardingView)) void {
        if (ev.position.x > w.viewportSize().width - 90) return; // Skip takes its own clicks
        w.startWindowMove();
    }

    fn onSkip(_: *OnboardingView, _: *const zpui.ClickEvent, _: *Window, _: *Context(OnboardingView)) void {
        finish(app_mod.instance);
    }

    fn onNext(_: *OnboardingView, _: *const zpui.ClickEvent, _: *Window, cx: *Context(OnboardingView)) void {
        next(app_mod.instance);
        cx.notify();
    }

    fn onButton(_: *OnboardingView, b: Btn, cx: *Context(OnboardingView)) void {
        const tb = app_mod.instance;
        switch (b) {
            .back => goTo(tb, ob.step.prev()),
            .play => {
                tb.previewPack();
                scriptKeysOnly(tb); // paws along with the sample
            },
        }
        cx.notify();
    }
    fn onButtonClick(self: *OnboardingView, b: Btn, _: *const zpui.ClickEvent, cx: *Context(OnboardingView)) void {
        self.onButton(b, cx);
    }
    fn onButtonPress(self: *OnboardingView, b: Btn, _: *const zpui.NativeControlEvent, cx: *Context(OnboardingView)) void {
        self.onButton(b, cx);
    }

    fn onCardHover(_: *OnboardingView, i: u8, hovered: *const bool, _: *Window, cx: *Context(OnboardingView)) void {
        if (hovered.*) ob.hover_card = i else if (ob.hover_card != null and ob.hover_card.? == i) ob.hover_card = null;
        cx.notify();
    }

    fn onAnimal(_: *OnboardingView, i: u8, _: *const zpui.ClickEvent, _: *Window, cx: *Context(OnboardingView)) void {
        pickAnimal(app_mod.instance, i);
        cx.notify();
    }

    fn onVibe(_: *OnboardingView, i: u8, _: *const zpui.ClickEvent, _: *Window, cx: *Context(OnboardingView)) void {
        const tb = app_mod.instance;
        chooseVibe(&tb.settings, @enumFromInt(@min(i, 2)));
        tb.settingsChanged();
        ob.pet.hop(tb.now());
        rearm(tb);
        cx.notify();
    }

    fn onAccessory(_: *OnboardingView, i: u8, _: *const zpui.ClickEvent, _: *Window, cx: *Context(OnboardingView)) void {
        const tb = app_mod.instance;
        toggleAccessory(&tb.settings, @enumFromInt(@min(i, 2)));
        // Holding coffee changes the idle pose; the preview follows the real config.
        tb.settingsChanged();
        ob.pet.setConfig(tb.now(), previewConfig(tb));
        ob.pet.hop(tb.now());
        rearm(tb);
        cx.notify();
    }

    fn onSound(_: *OnboardingView, ev: *const zpui.NativeControlEvent, _: *Window, cx: *Context(OnboardingView)) void {
        const tb = app_mod.instance;
        setSound(&tb.settings, ev.on);
        tb.settingsChanged();
        if (ev.on) tb.previewPack();
        cx.notify();
    }

    fn onPack(_: *OnboardingView, ev: *const zpui.NativeControlEvent, _: *Window, cx: *Context(OnboardingView)) void {
        const tb = app_mod.instance;
        if (ev.index < tb.library.packs.items.len) tb.settings.pack.set(tb.library.packs.items[ev.index].id);
        tb.settingsChanged();
        tb.previewPack();
        cx.notify();
    }

};

const InputCtx = struct { focus: zpui.FocusHandle, entity: zpui.Entity(OnboardingView) };

fn registerInput(c: InputCtx, b: Bounds, w: *Window, _: *App) void {
    w.handleInput(c.focus, zpui.ElementInputHandler.init(c.entity, b));
}

fn next(tb: *Typebud) void {
    if (ob.step == .done) return finish(tb);
    goTo(tb, ob.step.next());
}

fn pickAnimal(tb: *Typebud, i: u8) void {
    const a = &tb.catalog.animals[i];
    chooseAnimal(&tb.settings, a.name, a.hasHeadItem(tb.settings.head));
    tb.settingsChanged();
    ob.pick_at = tb.now();
    ob.picked = i;
    refresh(tb);
}

/// The sound sample's rhythm on the paws (no text).
const sample_keys = [_][]const u8{ "f", "j", "d", "space", "k", "s", "enter" };

fn scriptKeysOnly(tb: *Typebud) void {
    ob.script_id +%= 1;
    ob.script_i = 0;
    ob.script_gap = 130 * ms;
    keysOnlyTick(tb);
}

fn keysOnlyTick(tb: *Typebud) void {
    if (!ob.active or ob.script_i >= sample_keys.len) return;
    feedKey(tb, sample_keys[ob.script_i]);
    ob.script_i += 1;
    ScriptTick.ctx = .{ .tb = tb, .id = ob.script_id };
    tb.app.platform.dispatcher().dispatchAfter(ob.script_gap, .{ .ctx = &ScriptTick.ctx, .run = onKeysOnlyTimer });
}

fn onKeysOnlyTimer(ctx: *anyopaque) void {
    const c: *@TypeOf(ScriptTick.ctx) = @ptrCast(@alignCast(ctx));
    if (c.id != ob.script_id) return;
    keysOnlyTick(c.tb);
}

// ---- step pieces ------------------------------------------------------------------------

fn vibeRow(look: prefs.Look, cx: *Context(OnboardingView), tb: *Typebud) zpui.Div {
    const s = &tb.settings;
    var swatches = div().id("ob-vibes").flex().flexRow().gap(px(5)).role(.group).ariaLabel("Vibe");
    for (std.meta.tags(art.Vibe), 0..) |v, i| {
        const on = s.vibe == v;
        const case = tb.catalog.themes.gear(v, "kb_case") orelse art.parseHex("#3A3F4B").?;
        const cap = tb.catalog.themes.gear(v, "keycap") orelse case;
        const ring = if (look.dark and v == .dark) zpui.rgb(0x8a90a0).toHsla() else zpui.rgb(art.hexRgb(case)).toHsla();
        const dot = div().w(px(20)).h(px(20)).roundedFull().border2().borderColor(ring)
            .bg(zpui.rgb(art.hexRgb(cap)).toHsla()).shadowSm();
        swatches = swatches.child(div().id(.{ "ob-vibe", i }).flex().flexRow().itemsCenter().gap(px(6)).h(px(32)).pl(px(6)).pr(px(11)).rounded(px(16)).textSize(px(12.5))
            .bg(if (on) look.accent.alpha(0.14) else look.card_bg)
            .border1().borderColor(if (on) look.accent else look.fg.alpha(0.1))
            .cursorPointer().hover(sb.borderColor(look.accent.alpha(0.6)))
            .role(.radio_button).ariaLabel(art.Vibe.labels[i]).ariaToggled(on)
            .onClick(cx.listenerWith(@as(u8, @intCast(i)), OnboardingView.onVibe))
            .child(dot).child(div().fontWeight(if (on) 600 else 400).child(art.Vibe.labels[i])));
    }
    var extras = div().id("ob-extras").flex().flexRow().gap(px(5)).role(.group).ariaLabel("Accessories");
    const a = &tb.catalog.animals[tb.animal];
    for (std.meta.tags(Accessory), 0..) |acc, i| {
        const on = acc.isOn(s);
        const available = switch (acc) {
            .headphones => a.hasHeadItem(.headphones),
            .beanie => a.hasHeadItem(.beanie),
            .coffee => true,
        };
        var chip = div().id(.{ "ob-acc", i }).flex().itemsCenter().h(px(32)).px(px(11)).rounded(px(16)).textSize(px(12.5))
            .bg(if (on) look.accent else look.card_bg).textColor(if (on) look.accent_fg else look.fg)
            .border1().borderColor(if (on) look.accent else look.fg.alpha(0.1))
            .role(.check_box).ariaLabel(Accessory.labels[i]).ariaToggled(on)
            .child(Accessory.labels[i]);
        if (available) {
            chip = chip.cursorPointer().hover(sb.borderColor(look.accent.alpha(0.6))).onClick(cx.listenerWith(@as(u8, @intCast(i)), OnboardingView.onAccessory));
        } else chip = chip.opacity(look.disabled_opacity);
        extras = extras.child(chip);
    }
    return div().flex().flexRow().itemsCenter().gap(px(9))
        .child(swatches)
        .child(div().w(px(1)).h(px(22)).bg(look.separator))
        .child(extras);
}

fn soundRow(look: prefs.Look, cx: *Context(OnboardingView), tb: *Typebud, s: *const Settings) zpui.Div {
    const sel: ?u32 = if (tb.library.indexOf(s.pack.slice())) |i| (if (i < ob.pack_count) @intCast(i) else null) else null;
    return div().flex().flexRow().itemsCenter().gap(px(10)).h(px(36)).px(px(14)).rounded(px(look.card_radius)).bg(look.card_bg)
        .border1().borderColor(look.fg.alpha(0.07))
        .child(div().fontWeight(600).child("Clicky sounds"))
        .child(zpui.nativeSwitch("ob-sound", .{ .on = s.sound, .label = "Clicky sounds" }, cx.listener(OnboardingView.onSound), null))
        .child(div().w(px(1)).h(px(20)).bg(look.separator))
        .child(zpui.nativePopup("ob-pack", .{ .items = ob.pack_names[0..ob.pack_count], .selected = sel, .label = "Sound Pack", .width = px(178), .enabled = s.sound }, cx.listener(OnboardingView.onPack), null))
        .child(pushButton(look, .play, "Play", s.sound, cx));
}

const linux_input_command = "sudo usermod -aG input $USER";

const Note = struct {
    text: []const u8,
    command: ?[]const u8 = null,

    fn render(n: Note, look: prefs.Look) zpui.Div {
        var col = div().flex().flexCol().itemsCenter().gap(px(5)).maxW(px(450))
            .child(div().textSize(px(11.5)).lineHeight(px(15)).textColor(look.fg_dim).textCenter().child(n.text));
        if (n.command) |c| col = col.child(div().px(px(10)).py(px(4)).rounded(px(6)).bg(look.fg.alpha(0.08)).fontFamily(monoFont()).textSize(px(12)).textColor(look.fg).child(c));
        return col;
    }
};

fn monoFont() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "Menlo",
        .windows => "Consolas",
        else => "DejaVu Sans Mono",
    };
}

/// Only when there is something to do (macOS: an optional later toggle; Linux Wayland
/// without /dev/input access: one command). X11 / Windows: nothing.
fn platformNote(tb: *Typebud) ?Note {
    switch (builtin.os.tag) {
        .macos => if (!tb.settings.precise_input) return .{ .text = "No permissions needed. For paw-perfect left and right taps, you can turn on Precise Typing Detection in Settings later." },
        .linux => if (tb.input_status == .needs_permission) return .{ .text = "On Wayland I read your keyboard directly, so run this once and then log out and back in:", .command = linux_input_command },
        else => {},
    }
    return null;
}

// ---- look -------------------------------------------------------------------------------

/// The desktop's look; on macOS with the system's semantic colors (as in Settings).
fn lookOf(w: *Window) prefs.Look {
    var look = prefs.lookFor(w);
    if (builtin.os.tag != .macos) return look;
    if (w.systemColors(w.desktopTheme().dark orelse w.glass_dark)) |c| {
        look.fg = zpui.rgba(c.label).toHsla();
        look.fg_dim = zpui.rgba(c.secondary_label).toHsla();
        look.separator = zpui.rgba(c.separator).toHsla();
        look.window_bg = zpui.rgba(c.window_background).toHsla();
        look.accent = zpui.rgba(c.control_accent).toHsla();
        look.focus_ring = look.accent.alpha(0.5);
    }
    return look;
}

const Btn = enum(u8) { back, play };

/// A push button: an NSButton on macOS where zpui has native buttons, else drawn in the
/// desktop's style (the same look as the Settings window's buttons).
fn pushButton(look: prefs.Look, b: Btn, label: []const u8, enabled: bool, cx: *Context(OnboardingView)) zpui.AnyElement {
    const id = switch (b) {
        .back => "ob-back",
        .play => "ob-play",
    };
    const mac = look.family == .macos;
    var d = div().id(id).flex().itemsCenter().justifyCenter().h(px(if (mac) 24 else look.control_height)).px(px(if (mac) 12 else 16))
        .rounded(px(look.button_radius)).bg(look.button_bg).textColor(look.fg).role(.button).ariaLabel(label)
        .fontWeight(if (look.family == .adwaita) 700 else 400);
    if (look.family != .adwaita) d = d.border1().borderColor(look.outline);
    if (mac) d = d.shadowSm();
    if (enabled) {
        d = d.cursorPointer().hover(sb.bg(look.button_hover)).active(sb.bg(look.button_active)).onClick(cx.listenerWith(b, OnboardingView.onButtonClick));
    } else d = d.opacity(look.disabled_opacity);
    d = d.child(label);
    if (comptime @hasDecl(zpui, "nativeButton")) {
        if (mac) return zpui.intoAnyElement(zpui.nativeButton(id, .{ .title = label, .enabled = enabled, .bezel = .glass }, cx.listenerWith(b, OnboardingView.onButtonPress), d));
    }
    return zpui.intoAnyElement(d);
}

/// Soft pastel stage behind the pet, per vibe (dimmed for dark mode).
fn stageColors(v: art.Vibe, dark: bool) [2]Hsla {
    const c: [2]u32 = if (dark) switch (v) {
        .bright => .{ 0x3a322e, 0x2c2624 },
        .dark => .{ 0x302c48, 0x232136 },
        .pink => .{ 0x47293b, 0x34202d },
    } else switch (v) {
        .bright => .{ 0xfff6e8, 0xfde4d6 },
        .dark => .{ 0xeeeafb, 0xd9d3f2 },
        .pink => .{ 0xffeef4, 0xffd8e6 },
    };
    return .{ zpui.rgb(c[0]).toHsla(), zpui.rgb(c[1]).toHsla() };
}

fn caret(look: prefs.Look, focused: bool) zpui.Div {
    return div().w(px(2)).h(px(17)).mx(px(1)).rounded(px(1)).bg(if (focused) look.accent else look.fg_dim.alpha(0.4));
}

/// The step's main action: an accent pill.
fn primaryButton(look: prefs.Look, id: []const u8, label: []const u8, listener: anytype) zpui.StatefulDiv {
    const h: f32 = if (look.family == .macos) 30 else @max(look.control_height, 34);
    return div().id(id).flex().itemsCenter().justifyCenter().h(px(h)).minW(px(104)).px(px(20)).roundedFull()
        .bg(look.accent).textColor(look.accent_fg).fontWeight(600).textSize(px(13.5)).shadowSm().cursorPointer()
        .hover(sb.opacity(0.92)).active(sb.opacity(0.8))
        .role(.button).ariaLabel(label)
        .onClick(listener)
        .child(label);
}

// ---- tests ------------------------------------------------------------------------------

const testing = std.testing;

test "welcome: step navigation" {
    try testing.expectEqual(Step.buddy, Step.hello.next());
    try testing.expectEqual(Step.done, Step.typing.next());
    try testing.expectEqual(Step.done, Step.done.next());
    try testing.expectEqual(Step.hello, Step.hello.prev());
    try testing.expectEqual(Step.vibe, Step.sounds.prev());
    var s: Step = .hello;
    var n: usize = 0;
    while (s != .done) : (n += 1) s = s.next();
    try testing.expectEqual(@as(usize, Step.count - 1), n);
    try testing.expectEqual(@as(u8, 5), Step.done.dots());
    try testing.expectEqual(Step.count, Step.slugs.len);
}

test "welcome: first launch shows, done hides, show again resets" {
    var s: Settings = .{};
    try testing.expect(shouldShow(&s));
    begin(&s, .first_run);
    try testing.expect(!s.sound); // sounds start off on the first run
    markDone(&s);
    try testing.expect(!shouldShow(&s));
    try testing.expectEqual(version, s.onboarding_version);
    // Persisted.
    const gpa = testing.allocator;
    const json = try settings_mod.toJson(gpa, &s);
    defer gpa.free(json);
    const r = try settings_mod.fromJson(gpa, json);
    try testing.expect(!shouldShow(&r));
    try testing.expectEqual(version, r.onboarding_version);
    // A settings file from before the welcome existed: an existing user, not shown.
    const legacy = try settings_mod.fromJson(gpa, "{\"animal\": \"shiba\"}");
    try testing.expect(!shouldShow(&legacy));
    // Show again: shown, and the user's sound choice is kept.
    var again = r;
    again.sound = true;
    resetForShowAgain(&again);
    begin(&again, .again);
    try testing.expect(shouldShow(&again));
    try testing.expect(again.sound);
    // A fresh file written mid-welcome keeps it pending.
    var fresh: Settings = .{};
    const fj = try settings_mod.toJson(gpa, &fresh);
    defer gpa.free(fj);
    const fr = try settings_mod.fromJson(gpa, fj);
    try testing.expect(shouldShow(&fr));
    fresh.sound = false;
}

test "welcome: choices map to settings" {
    var s: Settings = .{};
    s.head = .yuzu;
    chooseAnimal(&s, "shiba", false);
    try testing.expectEqualStrings("shiba", s.animal.slice());
    try testing.expectEqual(art.HeadItem.none, s.head);
    s.head = .headphones;
    chooseAnimal(&s, "penguin", true);
    try testing.expectEqual(art.HeadItem.headphones, s.head);
    chooseVibe(&s, .pink);
    try testing.expectEqual(art.Vibe.pink, s.vibe);
    toggleAccessory(&s, .beanie);
    try testing.expectEqual(art.HeadItem.beanie, s.head);
    try testing.expect(Accessory.beanie.isOn(&s) and !Accessory.headphones.isOn(&s));
    toggleAccessory(&s, .beanie);
    try testing.expectEqual(art.HeadItem.none, s.head);
    toggleAccessory(&s, .coffee);
    try testing.expectEqual(art.HeldItem.coffee, s.held);
    toggleAccessory(&s, .headphones);
    try testing.expect(Accessory.coffee.isOn(&s) and Accessory.headphones.isOn(&s));
    setSound(&s, true);
    try testing.expect(s.sound);
    setSound(&s, false);
    try testing.expect(!s.sound);
}

test "welcome: key classification for the preview paws" {
    try testing.expectEqual(pet_state.KeyClass.space, classify("space").key);
    try testing.expect(classify("a").key_x.? < 0.5);
    try testing.expect(classify("k").key_x.? > 0.5);
    try testing.expectEqual(pet_state.KeyClass.digit, classify("7").key);
    try testing.expectEqual(pet_state.KeyClass.backspace, classify("backspace").key);
    try testing.expectEqual(pet_state.KeyClass.other, classify("f5").key);
}
