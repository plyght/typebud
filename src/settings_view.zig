//! The settings window: a section sidebar and one `zpui.prefs` page per section, so each
//! desktop gets its own look — real AppKit controls in a System Settings grouped form on
//! macOS (Liquid Glass sidebar on macOS 26+), libadwaita / Breeze drawn controls on Linux
//! (`Window.setDesktopControls(true)`), Windows native controls once that backend lands.

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const build_options = @import("build_options");
const art = @import("art.zig");
const assets = @import("assets.zig");
const raster = @import("raster.zig");
const render_mod = @import("render.zig");
const legends = @import("legends.zig");
const settings_mod = @import("settings.zig");
const update_hook = @import("update_hook.zig");
const pet_view = @import("pet_view.zig");
const app_mod = @import("app.zig");

const Window = zpui.Window;
const App = zpui.App;
const Context = zpui.Context;
const div = zpui.div;
const px = zpui.px;
const prefs = zpui.prefs;
const sb = zpui.StyleBuilder.init;
const Ev = zpui.NativeControlEvent;
const Typebud = app_mod.Typebud;
const Bounds = zpui.Bounds(zpui.Pixels);

pub const window_size: zpui.Size(zpui.Pixels) = .{ .width = 760, .height = 600 };
/// macOS: the whole window (the toolbar band is part of the content).
pub const mac_window_size: zpui.Size(zpui.Pixels) = .{ .width = 780, .height = 620 };
pub const mac_min_size: zpui.Size(zpui.Pixels) = .{ .width = 680, .height = 460 };

pub const Section = enum {
    character,
    accessories,
    behavior,
    sounds,
    visibility,
    system,
    credits,

    pub const labels = [_][]const u8{ "Character", "Accessories", "Behavior", "Sounds", "Visibility", "System", "Credits" };
    /// macOS sidebar: SF Symbol and badge color (System Settings' palette).
    pub const symbols = [_][]const u8{ "pawprint.fill", "headphones", "slider.horizontal.3", "speaker.wave.2.fill", "eye.fill", "gearshape.fill", "heart.fill" };
    pub const badges = [_]u32{ 0xff9500, 0xaf52de, 0x007aff, 0xff3b30, 0x30b0c7, 0x8e8e93, 0xff2d55 };
};

const Toggle = enum(u8) { keyboard, desk_plant, desk_lamp, desk_mug, sparkles, animations, sound, key_up, mute_other_audio, mute_mic, remember_visible, launch_at_login, precise_input, auto_update };
const Choice = enum(u8) { vibe, head, held, corner, display, sleep, sensitivity, pack, visibility, size_preset };
const Value = enum(u8) { size, volume };

const sleep_choices = [_]u32{ 0, 30, 60, 120, 300, 600 };
const sleep_labels = [_][]const u8{ "Never", "30 seconds", "1 minute", "2 minutes", "5 minutes", "10 minutes" };
const corner_labels = [_][]const u8{ "Top Left", "Top Right", "Bottom Left", "Bottom Right" };
const size_labels = [_][]const u8{ "S", "M", "L" };

pub const SettingsView = struct {
    selected_app: ?u32 = null,
    preview_cache: raster.LayerCache,
    preview_layout: legends.Layout = .{},
    icons: [art.max_animals]?raster.Image = @splat(null),
    icon_px: u32 = 0,
    app_items: [settings_mod.max_apps]prefs.ListItem = undefined,

    pub fn init(window: *Window, _: *Context(SettingsView)) SettingsView {
        window.setDesktopControls(true);
        const tb = app_mod.instance;
        return .{ .preview_cache = .init(tb.gpa, tb.catalog) };
    }

    pub fn deinit(self: *SettingsView, _: *App) void {
        for (&self.icons) |*i| if (i.*) |img| {
            img.img.release();
            i.* = null;
        };
        self.preview_cache.atlas = null;
        self.preview_cache.deinit();
    }

    pub fn render(self: *SettingsView, window: *Window, cx: *Context(SettingsView)) zpui.Div {
        if (builtin.os.tag == .macos) return self.renderMac(window, cx);
        const tb = app_mod.instance;
        const look = prefs.lookFor(window);
        const sec = tb.settings_section;
        const body = div().flex().flexRow().flex1().minH(px(0))
            .child(self.sidebar(window, look, cx, sec))
            .child(div().flex1().minW(px(0)).h(zpui.relative(1)).child(self.page(window, look, cx, sec)));
        return div().size(zpui.relative(1)).flex().flexCol().bg(look.window_bg)
            .child(prefs.headerBar(window, look, "typebud Settings"))
            .child(body);
    }

    // ---- macOS: System Settings window ----------------------------------------------------
    //
    // The window has a transparent, hidden title and an empty unified NSToolbar
    // (app.zig), so the traffic lights sit centred in a 52 pt toolbar band that is part of
    // the content. The sidebar runs the full window height under them: on macOS 26+ a
    // floating Liquid Glass pane inset from the window edges (NSGlassEffectView over the
    // behind-window `.sidebar` material), on older macOS the flush `.sidebar` vibrancy
    // column. zpui paints everything else opaque (alpha 0 only under the sidebar). The
    // detail column shows the page title in the toolbar band, aligned with the traffic
    // lights, over a scrolling grouped form.

    const band_h: f32 = 52;
    const sidebar_w: f32 = 220;

    fn renderMac(self: *SettingsView, window: *Window, cx: *Context(SettingsView)) zpui.Div {
        const tb = app_mod.instance;
        const look = macLook(window);
        const sec = tb.settings_section;
        const glass = window.supportsLiquidGlass();
        const vp = window.viewportSize();
        const inset: f32 = if (glass) 8 else 0;
        const radius: f32 = if (glass) 18 else 0;
        const pane: Bounds = .{ .origin = .{ .x = inset, .y = inset }, .size = .{ .width = sidebar_w - 2 * inset, .height = @max(vp.height - 2 * inset, 0) } };
        const family = zpui.desktop_controls.fontFamily(window, look);

        // Opaque window background everywhere but the sidebar pane.
        var root = div().relative().size(zpui.relative(1)).overflowHidden()
            .fontFamily(family).textSize(px(13)).textColor(look.fg)
            .onKeyDown(cx.listener(SettingsView.onKey));
        root = root.child(div().absolute().top(px(0)).bottom(px(0)).left(px(sidebar_w)).right(px(0)).bg(look.window_bg));
        var column = div().absolute().top(px(0)).bottom(px(0)).left(px(0)).w(px(sidebar_w)).overflowHidden();
        if (glass) {
            // A ring of window background whose inner edge is the pane's rounded rect.
            const ring: f32 = 48;
            column = column.child(div().absolute().left(px(pane.origin.x - ring)).top(px(pane.origin.y - ring))
                .w(px(pane.size.width + 2 * ring)).h(px(pane.size.height + 2 * ring))
                .border(px(ring)).borderColor(look.window_bg).rounded(px(radius + ring)));
        } else {
            column = column.child(div().absolute().top(px(0)).bottom(px(0)).right(px(0)).w(px(1)).bg(look.separator));
        }
        root = root.child(column);

        const rows = self.macSidebarRows(window, look, cx, sec, glass);
        var pane_div = div().absolute().left(px(pane.origin.x)).top(px(pane.origin.y)).w(px(pane.size.width)).h(px(pane.size.height))
            .child(zpui.sidebarMaterial("sidebar-material", .{ .corner_radius = radius, .without_glass = true }, div().absolute().inset0()));
        if (glass) {
            pane_div = pane_div.child(zpui.liquidGlass("sidebar-glass", .{ .shape = .{ .rounded = radius } }, div().size(zpui.relative(1)).child(rows)));
        } else pane_div = pane_div.child(rows);
        root = root.child(pane_div);

        // Detail: the page title in the toolbar band, then the scrolling form.
        const title = div().id("page-title").flex().flexNone().itemsCenter().h(px(band_h)).px(px(20))
            .textSize(px(15)).fontWeight(700).textColor(look.fg).role(.heading).child(Section.labels[@intFromEnum(sec)]);
        const detail = div().absolute().top(px(0)).bottom(px(0)).left(px(sidebar_w)).right(px(0)).flex().flexCol()
            .child(title)
            .child(div().flex1().minH(px(0)).child(self.page(window, look, cx, sec)));
        return root.child(detail);
    }

    fn macSidebarRows(_: *SettingsView, window: *Window, look: prefs.Look, cx: *Context(SettingsView), sec: Section, glass: bool) zpui.StatefulDiv {
        const sys = systemColors(window);
        const active = window.isWindowActive();
        const sel_bg = if (sys) |c| hsla(if (active) c.selected_content_background else c.unemphasized_selected_content_background) else look.accent;
        const sel_fg = if (active) (if (sys) |c| hsla(c.alternate_selected_text) else look.accent_fg) else look.fg;
        // Rows start under the traffic lights' toolbar band.
        const inset: f32 = if (glass) 8 else 0;
        var col = div().id("sections").flex().flexCol().gap(px(2)).px(px(10)).pt(px(band_h + 4 - inset)).role(.tab_list).ariaLabel("Sections");
        for (Section.labels, 0..) |label, i| {
            const on = @intFromEnum(sec) == i;
            const badge = div().flexNone().w(px(20)).h(px(20)).rounded(px(5)).bg(zpui.rgb(Section.badges[i]).toHsla())
                .flex().itemsCenter().justifyCenter()
                .child(zpui.systemSymbol(Section.symbols[i], .{ .point_size = 11.5, .weight = .medium, .fit = 14 }).w(px(14)).h(px(14)).textColor(zpui.rgb(0xffffff).toHsla()));
            col = col.child(div().id(.{ "section", i }).flex().itemsCenter().gap(px(8)).h(px(if (glass) 32 else 28)).px(px(6))
                .rounded(px(if (glass) 9 else 5)).bg(if (on) sel_bg else zpui.color.transparent_black)
                .textColor(if (on) sel_fg else look.fg).textSize(px(13))
                .role(.tab).ariaLabel(label).ariaSelected(on)
                .onClick(cx.listenerWith(@as(u8, @intCast(i)), SettingsView.onSection))
                .child(badge)
                .child(div().flex1().minW(px(0)).overflowHidden().whitespaceNowrap().child(label)));
        }
        return col;
    }

    /// The System Settings form look with the system's own semantic colors
    /// (labelColor, secondaryLabelColor, separatorColor, windowBackgroundColor,
    /// controlAccentColor) for the window's appearance.
    fn macLook(window: *Window) prefs.Look {
        var look = prefs.lookFor(window);
        if (systemColors(window)) |c| {
            look.fg = hsla(c.label);
            look.fg_dim = hsla(c.secondary_label);
            look.separator = hsla(c.separator);
            look.window_bg = hsla(c.window_background);
            look.accent = hsla(c.control_accent);
            look.item_hover = look.accent;
            look.focus_ring = look.accent.alpha(0.5);
        }
        return look;
    }

    fn onKey(_: *SettingsView, ev: *const zpui.input.KeyDownEvent, window: *Window, cx: *Context(SettingsView)) void {
        const ks = ev.keystroke;
        const m = ks.modifiers;
        if (m.platform and !m.control and !m.alt and std.mem.eql(u8, ks.key, "w")) {
            window.removeWindow();
            return;
        }
        if (m.platform or m.control or m.alt) return;
        const tb = app_mod.instance;
        const n: u8 = Section.labels.len;
        const cur: u8 = @intFromEnum(tb.settings_section);
        const next: u8 = if (std.mem.eql(u8, ks.key, "down")) @min(cur + 1, n - 1) else if (std.mem.eql(u8, ks.key, "up")) cur -| 1 else if (std.mem.eql(u8, ks.key, "home")) 0 else if (std.mem.eql(u8, ks.key, "end")) n - 1 else return;
        if (next == cur) return;
        tb.settings_section = @enumFromInt(next);
        cx.notify();
    }

    fn sidebar(_: *SettingsView, window: *Window, look: prefs.Look, cx: *Context(SettingsView), sec: Section) zpui.AnyElement {
        const mac = look.family == .macos;
        var col = div().flex().flexCol().gap(px(2)).p(px(10)).pt(px(if (mac) 12 else 10)).w(px(172)).flexNone().h(zpui.relative(1));
        for (Section.labels, 0..) |label, i| {
            const on = @intFromEnum(sec) == i;
            const fg = if (on and mac) look.accent_fg else look.fg;
            const bg = if (!on) zpui.color.transparent_black else if (mac) look.accent else if (look.family == .breeze) look.toggle_checked else look.button_bg;
            col = col.child(div().id(.{ "section", i }).flex().itemsCenter().h(px(if (mac) 28 else 36)).px(px(10))
                .rounded(px(if (mac) 6 else look.button_radius)).bg(bg).textColor(fg).cursorPointer()
                .fontWeight(if (on and !mac) 700 else 400)
                .hover(sb.bg(if (on) bg else look.button_hover))
                .role(.tab).ariaLabel(label).ariaSelected(on)
                .onClick(cx.listenerWith(@as(u8, @intCast(i)), SettingsView.onSection))
                .child(label));
        }
        const pane = div().h(zpui.relative(1)).flexNone().borderR1().borderColor(look.separator).bg(if (mac) look.window_bg else look.view_bg)
            .fontFamily(zpui.desktop_controls.fontFamily(window, look)).textSize(px(look.font_size)).child(col);
        if (mac and zpui.platformSupportsLiquidGlass(cx)) {
            return zpui.intoAnyElement(div().h(zpui.relative(1)).flexNone().p(px(8)).child(zpui.liquidGlass("sidebar-glass", .{ .shape = .{ .rounded = 12 } }, div().h(zpui.relative(1)).child(col))));
        }
        return zpui.intoAnyElement(pane);
    }

    fn page(self: *SettingsView, window: *Window, look: prefs.Look, cx: *Context(SettingsView), sec: Section) zpui.AnyElement {
        const tb = app_mod.instance;
        const s = &tb.settings;
        return switch (sec) {
            .character => prefs.page(window, look, &.{
                .{ .title = "Character", .description = "Who sits at the keyboard", .content = zpui.intoAnyElement(self.characterPicker(window, look, cx)) },
                .{ .title = "Vibe", .rows = &.{
                    prefs.row("Colors", "Keyboard and headphones", zpui.nativeSegmented("vibe", .{ .items = &art.Vibe.labels, .selected = @intFromEnum(s.vibe), .label = "Vibe" }, cx.listenerWith(Choice.vibe, SettingsView.onChoice), null)),
                } },
            }),
            .accessories => self.accessoriesPage(window, look, cx),
            .behavior => self.behaviorPage(window, look, cx),
            .sounds => self.soundsPage(window, look, cx),
            .visibility => self.visibilityPage(window, look, cx),
            .system => self.systemPage(window, look, cx),
            .credits => creditsPage(window, look),
        };
    }

    // ---- character ------------------------------------------------------------------------

    fn characterPicker(self: *SettingsView, window: *Window, look: prefs.Look, cx: *Context(SettingsView)) zpui.Div {
        const tb = app_mod.instance;
        const scale = window.scaleFactor();
        self.ensureIcons(scale);
        var tiles = div().flex().flexRow().flexWrap().gap(px(8)).w(px(72 * 4 + 8 * 3));
        for (tb.catalog.list(), 0..) |a, i| {
            const on = i == tb.animal;
            const icon_ctx = IconCtx{ .view = self, .index = i };
            tiles = tiles.child(div().id(.{ "animal", i }).flex().flexCol().itemsCenter().gap(px(4)).w(px(72)).py(px(8))
                .rounded(px(look.card_radius)).bg(if (on) look.toggle_checked else look.card_bg)
                .border2().borderColor(if (on) look.accent else zpui.color.transparent_black)
                .cursorPointer().hover(sb.bg(if (on) look.toggle_checked else look.button_hover))
                .role(.radio_button).ariaLabel(a.name).ariaToggled(on)
                .onClick(cx.listenerWith(@as(u8, @intCast(i)), SettingsView.onAnimal))
                .child(zpui.canvas(icon_ctx, paintIcon).w(px(48)).h(px(48)))
                .child(div().textSize(px(look.small_font_size)).child(capitalized(a.name))));
        }
        const preview = div().flexNone().w(px(160)).h(px(160)).rounded(px(look.card_radius)).bg(previewBg(tb.settings.vibe)).overflowHidden()
            .child(zpui.canvas(self, paintPreview).size(zpui.relative(1)));
        return div().flex().flexRow().gap(px(14)).itemsCenter().p(px(12)).w(px(160 + 14 + 72 * 4 + 24 + 24)).maxW(zpui.relative(1)).rounded(px(look.card_radius)).bg(look.card_bg)
            .child(preview)
            .child(tiles);
    }

    fn ensureIcons(self: *SettingsView, scale: f32) void {
        const tb = app_mod.instance;
        const want: u32 = @intFromFloat(@round(48 * scale));
        if (want == self.icon_px) return;
        for (&self.icons) |*i| if (i.*) |img| {
            img.img.release();
            i.* = null;
        };
        self.icon_px = want;
        for (tb.catalog.list(), 0..) |a, i| {
            var pb: [96]u8 = undefined;
            const path = std.fmt.bufPrint(&pb, "art/{s}/icon.svg", .{a.name}) catch continue;
            const src = assets.get(path) orelse continue;
            const cmap = tb.catalog.colorMap(i, .bright);
            const buf = tb.gpa.alloc(u8, src.len) catch continue;
            defer tb.gpa.free(buf);
            art.recolorInto(buf, src, &cmap);
            var pm = zpui.image.svg.rasterizeBgra(tb.gpa, buf, .{ .size = .{ .width = @intCast(want), .height = @intCast(want) } }, 0xFF000000) catch continue;
            defer pm.deinit(tb.gpa);
            self.icons[i] = raster.cropToImage(tb.gpa, pm.bytes, pm.width, pm.height, want) catch null;
        }
    }

    const IconCtx = struct { view: *SettingsView, index: usize };

    fn paintIcon(c: IconCtx, b: Bounds, w: *Window, _: *App) void {
        const img = c.view.icons[c.index] orelse return;
        const s = b.size.width / @as(f32, @floatFromInt(img.px));
        w.paintImage(.{
            .origin = .{ .x = b.origin.x + @as(f32, @floatFromInt(img.x)) * s, .y = b.origin.y + @as(f32, @floatFromInt(img.y)) * s },
            .size = .{ .width = @as(f32, @floatFromInt(img.w)) * s, .height = @as(f32, @floatFromInt(img.h)) * s },
        }, .all(0), img.img, 0, false);
    }

    fn paintPreview(self: *SettingsView, b: Bounds, w: *Window, _: *App) void {
        const tb = app_mod.instance;
        const scale = w.scaleFactor();
        self.preview_cache.atlas = w.sprite_atlas;
        const size = @min(b.size.width, b.size.height);
        const rp: u32 = @intFromFloat(@round(size * scale));
        self.preview_cache.retainOnly(tb.animal, tb.settings.vibe, rp);
        const kb = art.Affine.keyboard(tb.catalog.animals[tb.animal].anchors.keyboard);
        if (tb.font_id) |fid| if (!self.preview_layout.matches(size, scale, kb)) legends.layout(&self.preview_layout, tb.app.textSystem(), fid, &tb.keys, size, scale, kb);
        const now = tb.now();
        const pet = pet_view.currentPet(tb, now, .{ b.origin.x, b.origin.y }, size, rp, size);
        var wp: render_mod.WindowPainter = .{ .window = w };
        render_mod.paint(pet, .{ .catalog = tb.catalog, .cache = &self.preview_cache, .legend_layout = if (tb.font_id != null) &self.preview_layout else null, .legend_colors = render_mod.legendColors(tb.catalog) }, wp.painter());
        if (tb.state.animating(now)) w.requestAnimationFrame();
    }

    // ---- accessories ----------------------------------------------------------------------

    fn accessoriesPage(self: *SettingsView, window: *Window, look: prefs.Look, cx: *Context(SettingsView)) zpui.AnyElement {
        _ = self;
        const tb = app_mod.instance;
        const s = &tb.settings;
        // Head items this animal has art for (yuzu is the capybara's).
        const a = &tb.catalog.animals[tb.animal];
        const fa = zpui.frameAllocator();
        var heads: std.ArrayList([]const u8) = .empty;
        var head_sel: ?u32 = null;
        for (std.meta.tags(art.HeadItem)) |h| if (a.hasHeadItem(h)) {
            if (h == s.head) head_sel = @intCast(heads.items.len);
            heads.append(fa, art.HeadItem.labels[@intFromEnum(h)]) catch {};
        };
        return prefs.page(window, look, &.{
            .{ .title = "Gear", .rows = &.{
                prefs.row("Keyboard", "The little keyboard the paws tap", sw("keyboard", s.keyboard, "Keyboard", cx, .keyboard)),
                prefs.row("Head Item", "Headphones add music notes while typing", zpui.nativePopup("head", .{ .items = heads.items, .selected = head_sel, .label = "Head Item", .width = px(160) }, cx.listenerWith(Choice.head, SettingsView.onChoice), null)),
                prefs.row("Held Item", "Hugged and sipped while idle, set on the desk while typing", zpui.nativePopup("held", .{ .items = &art.HeldItem.labels, .selected = @intFromEnum(s.held), .label = "Held Item", .width = px(160) }, cx.listenerWith(Choice.held, SettingsView.onChoice), null)),
            } },
            .{ .title = "Desk", .rows = &.{
                prefs.row("Plant", "", sw("plant", s.desk_plant, "Plant", cx, .desk_plant)),
                prefs.row("Lamp", "", sw("lamp", s.desk_lamp, "Lamp", cx, .desk_lamp)),
                prefs.row("Mug", "", sw("mug", s.desk_mug, "Mug", cx, .desk_mug)),
                prefs.row("Sparkles", "A few twinkles behind the scene", sw("sparkles", s.sparkles, "Sparkles", cx, .sparkles)),
            } },
        });
    }

    // ---- behavior -------------------------------------------------------------------------

    fn behaviorPage(self: *SettingsView, window: *Window, look: prefs.Look, cx: *Context(SettingsView)) zpui.AnyElement {
        _ = self;
        const tb = app_mod.instance;
        const s = &tb.settings;
        var preset: ?u32 = null;
        for (settings_mod.size_presets, 0..) |p, i| if (p == s.size) {
            preset = @intCast(i);
        };
        var sleep_sel: ?u32 = null;
        for (sleep_choices, 0..) |c, i| if (c == s.sleep_after) {
            sleep_sel = @intCast(i);
        };
        var displays: [8]zpui.platform.Display = undefined;
        const nd = tb.displays(&displays);
        const fa = zpui.frameAllocator();
        const dnames: [][]const u8 = fa.alloc([]const u8, @max(nd, 1)) catch @panic("OOM");
        for (dnames, 0..) |*d, i| d.* = if (nd == 0) "Main Display" else if (displays[i].primary) zpui.fmt("Display {d} (main)", .{i + 1}) else zpui.fmt("Display {d}", .{i + 1});
        var size_row = div().flex().flexRow().itemsCenter().gap(px(10))
            .child(zpui.nativeSlider("size", .{ .value = s.size, .min = settings_mod.min_size, .max = settings_mod.max_size, .label = "Size", .width = px(150) }, cx.listenerWith(Value.size, SettingsView.onValue), null))
            .child(zpui.nativeSegmented("size-preset", .{ .items = &size_labels, .selected = preset, .label = "Size Preset" }, cx.listenerWith(Choice.size_preset, SettingsView.onChoice), null));
        _ = &size_row;
        return prefs.page(window, look, &.{
            .{ .title = "Placement", .rows = &.{
                prefs.row("Size", zpui.fmt("{d:.0} px · drag the grip on the pet to resize", .{s.size}), size_row),
                prefs.row("Corner", "Or drag the pet; it snaps to the nearest corner", zpui.nativePopup("corner", .{ .items = &corner_labels, .selected = @intFromEnum(s.corner), .label = "Corner", .width = px(160) }, cx.listenerWith(Choice.corner, SettingsView.onChoice), null)),
                prefs.row("Display", "", zpui.nativePopup("display", .{ .items = dnames, .selected = @min(s.display, @as(u32, @intCast(dnames.len -| 1))), .label = "Display", .width = px(160), .enabled = nd > 1 }, cx.listenerWith(Choice.display, SettingsView.onChoice), null)),
            } },
            .{ .title = "Animation", .rows = &.{
                prefs.row("Animations", "Off: a still pet that only swaps paws (reduce motion)", sw("animations", s.animations, "Animations", cx, .animations)),
                prefs.row("Fall Asleep After", "Idle time before the pet naps", zpui.nativePopup("sleep", .{ .items = &sleep_labels, .selected = sleep_sel, .label = "Fall Asleep After", .width = px(160), .enabled = s.animations }, cx.listenerWith(Choice.sleep, SettingsView.onChoice), null)),
                prefs.row("Excitement", zpui.fmt("Gets excited above {d:.0} words per minute", .{s.sensitivity.wpm()}), zpui.nativeSegmented("sensitivity", .{ .items = &settings_mod.Sensitivity.labels, .selected = @intFromEnum(s.sensitivity), .label = "Excitement", .enabled = s.animations }, cx.listenerWith(Choice.sensitivity, SettingsView.onChoice), null)),
            } },
        });
    }

    // ---- sounds ---------------------------------------------------------------------------

    fn soundsPage(self: *SettingsView, window: *Window, look: prefs.Look, cx: *Context(SettingsView)) zpui.AnyElement {
        _ = self;
        const tb = app_mod.instance;
        const s = &tb.settings;
        const fa = zpui.frameAllocator();
        const names: [][]const u8 = fa.alloc([]const u8, tb.library.packs.items.len) catch @panic("OOM");
        for (names, tb.library.packs.items) |*n, p| n.* = p.name;
        const sel: ?u32 = if (tb.library.indexOf(s.pack.slice())) |i| @intCast(i) else null;
        const info = tb.library.find(s.pack.slice());
        var status: []const u8 = "";
        if (tb.audio) |a| {
            const st = a.status();
            if (st.backend == .none) status = zpui.fmt("No audio output ({s})", .{st.reason});
        }
        if (tb.monitor) |m| if (m.shouldMute()) {
            status = if (m.microphoneInUse()) "Muted: the microphone is in use" else "Muted: other audio is playing";
        };
        const pack_row = div().flex().flexRow().itemsCenter().gap(px(8))
            .child(zpui.nativePopup("pack", .{ .items = names, .selected = sel, .label = "Sound Pack", .width = px(190), .enabled = s.sound }, cx.listenerWith(Choice.pack, SettingsView.onChoice), null))
            .child(button(look, "preview", "Preview", s.sound, cx.listener(SettingsView.onPreview)));
        const import_row = div().flex().flexRow().itemsCenter().gap(px(8))
            .child(button(look, "import", "Import Pack…", true, cx.listener(SettingsView.onImport)));
        return prefs.page(window, look, &.{
            .{ .title = "Typing Sounds", .description = status, .rows = &.{
                prefs.row("Typing Sounds", "Mechanical keyboard clicks as you type", sw("sound", s.sound, "Typing Sounds", cx, .sound)),
                prefs.row("Sound Pack", if (info) |i| i.description else "", pack_row),
                prefs.row("Volume", "", zpui.nativeSlider("volume", .{ .value = s.volume, .label = "Volume", .width = px(200), .enabled = s.sound }, cx.listenerWith(Value.volume, SettingsView.onValue), null)),
                prefs.row("Key-Up Sounds", "Also play the release of each key", swEnabled("keyup", s.key_up, "Key-Up Sounds", s.sound, cx, .key_up)),
            } },
            .{ .title = "Auto-Mute", .rows = &.{
                prefs.row("While Other Audio Plays", "Music, videos, games", swEnabled("mute-audio", s.mute_other_audio, "Mute While Other Audio Plays", s.sound, cx, .mute_other_audio)),
                prefs.row("During Calls", "When an app uses the microphone", swEnabled("mute-mic", s.mute_mic, "Mute During Calls", s.sound, cx, .mute_mic)),
            } },
            .{ .title = "Your Packs", .description = "Mechvibes, MechvibesDX and Thock packs (pick the folder with config.json)", .rows = &.{
                prefs.row("Import", tb.import_message.slice(), import_row),
            } },
        });
    }

    // ---- visibility -----------------------------------------------------------------------

    fn visibilityPage(self: *SettingsView, window: *Window, look: prefs.Look, cx: *Context(SettingsView)) zpui.AnyElement {
        const tb = app_mod.instance;
        const s = &tb.settings;
        const n = s.app_count;
        for (s.appList(), 0..) |*a, i| self.app_items[i] = .{ .title = a.name.slice(), .subtitle = a.id.slice(), .icon = zpui.intoAnyElement(appIcon(a.name.slice())) };
        const sel = if (self.selected_app) |x| (if (x < n) x else null) else null;
        const fg: []const u8 = if (tb.fg_id) |id| zpui.fmt("Front app now: {s}", .{id}) else "The front app is not reported on this desktop";
        const list_title = switch (s.visibility) {
            .everywhere, .only_in => "Only Show in These Apps",
            .hide_in => "Hide in These Apps",
        };
        return prefs.page(window, look, &.{
            .{ .title = "Where to Show", .rows = &.{
                prefs.row("Show typebud", fg, zpui.nativePopup("vis", .{ .items = &settings_mod.VisibilityMode.labels, .selected = @intFromEnum(s.visibility), .label = "Show typebud", .width = px(200) }, cx.listenerWith(Choice.visibility, SettingsView.onChoice), null)),
                prefs.row("Remember Shown / Hidden", "Keep the tray's Show / Hide choice after a restart", sw("remember", s.remember_visible, "Remember Shown / Hidden", cx, .remember_visible)),
            } },
            .{ .title = list_title, .description = "+ adds the app you used most recently", .content = prefs.editableList(look, "apps", .{
                .items = self.app_items[0..n],
                .selected = sel,
                .label = "Apps",
                .add_label = "Add Recent App…",
            }, cx.listener(SettingsView.onApps)) },
        });
    }

    // ---- system ---------------------------------------------------------------------------

    fn systemPage(self: *SettingsView, window: *Window, look: prefs.Look, cx: *Context(SettingsView)) zpui.AnyElement {
        _ = self;
        const tb = app_mod.instance;
        const s = &tb.settings;
        var ub: [128]u8 = undefined;
        const ustatus = zpui.fmt("{s}", .{update_hook.statusText(&ub)});
        const check_row = div().flex().flexRow().itemsCenter().gap(px(8)).child(button(look, "check", "Check Now", true, cx.listener(SettingsView.onCheckNow)));
        const general = [_]prefs.Row{
            prefs.row("Launch at Login", "Start typebud when you log in", sw("login", s.launch_at_login, "Launch at Login", cx, .launch_at_login)),
        };
        const perm = tb.app.inputPermission();
        const precise_sub = zpui.fmt("Needs Input Monitoring permission · {s}", .{switch (perm) {
            .granted => "granted",
            .denied => "denied in System Settings",
            .not_determined => "not asked yet",
            .not_applicable => "not needed now",
        }});
        const mac_rows = [_]prefs.Row{
            prefs.row("Precise Typing Detection", precise_sub, sw("precise", s.precise_input, "Precise Typing Detection", cx, .precise_input)),
        };
        const typing = if (builtin.os.tag == .macos) mac_rows[0..] else &[_]prefs.Row{
            prefs.row("Typing Detection", switch (tb.input_status) {
                .ok => "Watching the keyboard (never which keys)",
                .needs_permission => "Needs access to /dev/input: add yourself to the input group",
                .unsupported => "Not available on this desktop",
            }, null),
        };
        return prefs.page(window, look, &.{
            .{ .title = "General", .rows = &general },
            .{ .title = "Typing", .rows = typing },
            .{ .title = "Updates", .rows = &.{
                prefs.row("Check Automatically", ustatus, sw("autoupdate", s.auto_update, "Check for Updates Automatically", cx, .auto_update)),
                prefs.row("Check for Updates", zpui.fmt("typebud {s}", .{build_options.version}), check_row),
            } },
        });
    }

    // ---- handlers -------------------------------------------------------------------------

    fn onSection(_: *SettingsView, i: u8, _: *const zpui.ClickEvent, cx: *Context(SettingsView)) void {
        app_mod.instance.settings_section = @enumFromInt(i);
        cx.notify();
    }

    fn onAnimal(_: *SettingsView, i: u8, _: *const zpui.ClickEvent, cx: *Context(SettingsView)) void {
        const tb = app_mod.instance;
        tb.settings.animal.set(tb.catalog.animals[i].name);
        if (!tb.catalog.animals[i].hasHeadItem(tb.settings.head)) tb.settings.head = .none;
        tb.settingsChanged();
        cx.notify();
    }

    fn onToggle(_: *SettingsView, t: Toggle, ev: *const Ev, cx: *Context(SettingsView)) void {
        const s = &app_mod.instance.settings;
        switch (t) {
            inline else => |tag| @field(s, @tagName(tag)) = ev.on,
        }
        app_mod.instance.settingsChanged();
        cx.notify();
    }

    fn onChoice(_: *SettingsView, c: Choice, ev: *const Ev, cx: *Context(SettingsView)) void {
        const tb = app_mod.instance;
        const s = &tb.settings;
        const i = ev.index;
        switch (c) {
            .vibe => s.vibe = @enumFromInt(@min(i, 2)),
            .head => {
                // Index into the filtered list.
                var k: u32 = 0;
                for (std.meta.tags(art.HeadItem)) |h| if (tb.catalog.animals[tb.animal].hasHeadItem(h)) {
                    if (k == i) s.head = h;
                    k += 1;
                };
            },
            .held => s.held = @enumFromInt(@min(i, 3)),
            .corner => {
                s.corner = @enumFromInt(@min(i, 3));
                s.margin_x = 16;
                s.margin_y = 16;
            },
            .display => s.display = i,
            .sleep => s.sleep_after = sleep_choices[@min(i, sleep_choices.len - 1)],
            .sensitivity => s.sensitivity = @enumFromInt(@min(i, 2)),
            .pack => if (i < tb.library.packs.items.len) s.pack.set(tb.library.packs.items[i].id),
            .visibility => s.visibility = @enumFromInt(@min(i, 2)),
            .size_preset => s.size = settings_mod.size_presets[@min(i, 2)],
        }
        tb.settingsChanged();
        if (c == .pack) tb.previewPack();
        cx.notify();
    }

    fn onValue(_: *SettingsView, v: Value, ev: *const Ev, cx: *Context(SettingsView)) void {
        const tb = app_mod.instance;
        switch (v) {
            .size => tb.settings.size = @round(@as(f32, @floatCast(ev.value))),
            .volume => tb.settings.volume = @floatCast(ev.value),
        }
        tb.settingsChanged();
        cx.notify();
    }

    fn onApps(self: *SettingsView, ev: *const prefs.ListEvent, cx: *Context(SettingsView)) void {
        const tb = app_mod.instance;
        switch (ev.*) {
            .select => |i| self.selected_app = i,
            .add => if (tb.recentCandidate()) |r| {
                _ = tb.settings.addApp(r.id.slice(), r.name.slice());
                tb.settingsChanged();
            },
            .remove => |i| {
                tb.settings.removeApp(i);
                self.selected_app = null;
                tb.settingsChanged();
            },
        }
        cx.notify();
    }

    fn onPreview(_: *SettingsView, _: *const zpui.ClickEvent, _: *Context(SettingsView)) void {
        app_mod.instance.previewPack();
    }
    fn onImport(_: *SettingsView, _: *const zpui.ClickEvent, _: *Context(SettingsView)) void {
        app_mod.instance.importPack();
    }
    fn onCheckNow(_: *SettingsView, _: *const zpui.ClickEvent, cx: *Context(SettingsView)) void {
        update_hook.checkNow(true);
        cx.notify();
    }
};

fn sw(id: []const u8, on: bool, label: []const u8, cx: *Context(SettingsView), t: Toggle) zpui.native_control.NativeControl {
    return swEnabled(id, on, label, true, cx, t);
}

fn swEnabled(id: []const u8, on: bool, label: []const u8, enabled: bool, cx: *Context(SettingsView), t: Toggle) zpui.native_control.NativeControl {
    return zpui.nativeSwitch(id, .{ .on = on, .label = label, .enabled = enabled }, cx.listenerWith(t, SettingsView.onToggle), null);
}

/// A push button in the family's look (zpui has no native push-button control yet).
fn button(look: prefs.Look, id: []const u8, label: []const u8, enabled: bool, listener: anytype) zpui.StatefulDiv {
    const mac = look.family == .macos;
    var b = div().id(id).flex().itemsCenter().justifyCenter().h(px(if (mac) 22 else look.control_height)).px(px(if (mac) 10 else 14))
        .rounded(px(look.button_radius)).bg(look.button_bg).textColor(look.fg).role(.button).ariaLabel(label)
        .fontWeight(if (look.family == .adwaita) 700 else 400);
    if (look.family != .adwaita) b = b.border1().borderColor(look.outline);
    if (mac) b = b.shadowSm();
    if (enabled) {
        b = b.cursorPointer().hover(sb.bg(look.button_hover)).active(sb.bg(look.button_active)).onClick(listener);
    } else b = b.opacity(look.disabled_opacity);
    return b.child(label);
}

fn appIcon(name: []const u8) zpui.Div {
    var h: u32 = 2166136261;
    for (name) |c| h = (h ^ c) *% 16777619;
    const palette = [_]u32{ 0xe5a50a, 0x3584e4, 0x2190a4, 0xe01b24, 0x9141ac, 0x33d17a, 0xc64600, 0x613583 };
    const initial = if (name.len > 0) zpui.fmt("{c}", .{std.ascii.toUpper(name[0])}) else "?";
    return div().size(zpui.relative(1)).rounded(px(6)).bg(zpui.rgb(palette[h % palette.len]).toHsla()).flex().itemsCenter().justifyCenter()
        .textColor(zpui.rgb(0xffffff).toHsla()).fontWeight(700).textSize(px(12)).child(initial);
}

/// The system's semantic colors for the window's appearance, or for the forced light /
/// dark look (smoke screenshots, `glass_dark`).
fn systemColors(window: *Window) ?zpui.platform.SystemColors {
    return window.systemColors(window.desktopTheme().dark orelse window.glass_dark);
}

/// 0xRRGGBBAA (zpui.platform.SystemColors) as a color.
fn hsla(rgba: u32) zpui.Hsla {
    return zpui.rgba(rgba).toHsla();
}

fn previewBg(v: art.Vibe) zpui.Hsla {
    return switch (v) {
        .dark => zpui.rgb(0x1e1e24).toHsla(),
        .bright => zpui.rgb(0xf5f5f0).toHsla(),
        .pink => zpui.rgb(0xffe4ec).toHsla(),
    };
}

fn capitalized(name: []const u8) []const u8 {
    const out = zpui.frameAllocator().dupe(u8, name) catch return name;
    if (out.len > 0) out[0] = std.ascii.toUpper(out[0]);
    return out;
}

fn creditsPage(window: *Window, look: prefs.Look) zpui.AnyElement {
    const tb = app_mod.instance;
    const fa = zpui.frameAllocator();
    var rows: std.ArrayList(prefs.Row) = .empty;
    for (tb.library.packs.items) |p| {
        const sub = if (p.attribution.len > 0) p.attribution else zpui.fmt("{s} · {s}", .{ p.author, p.license });
        rows.append(fa, prefs.row(p.name, sub, div().textColor(look.fg_dim).textSize(px(look.small_font_size)).child(p.license))) catch {};
    }
    return prefs.page(window, look, &.{
        .{ .title = "typebud", .description = zpui.fmt("Version {s} · a cozy typing companion", .{build_options.version}), .rows = &.{
            prefs.row("Art", "Cat, capybara, penguin and shiba drawn for typebud", null),
            prefs.row("Keycap Font", "Nunito by Vernon Adams, Cyreal and Jacques Le Bailly · SIL Open Font License 1.1", div().textColor(look.fg_dim).textSize(px(look.small_font_size)).child("OFL-1.1")),
            prefs.row("UI Framework", zpui.fmt("zpui (github.com/plyght/zpui @ {s}), a Zig port of Zed's gpui (Apache-2.0)", .{build_options.zpui_commit[0..7]}), null),
            prefs.row("Audio Decoders", "stb_vorbis (Sean Barrett, public domain) and minimp3 (lieff, CC0), for pack import", null),
        } },
        .{ .title = "Sound Packs", .rows = rows.items },
    });
}
