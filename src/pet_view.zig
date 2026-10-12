//! The pet window's root view: one canvas that composites the current frame, draws the
//! resize grip on hover, keeps the click-through input region in sync with what is drawn,
//! and turns presses into drag-to-move / drag-to-resize (anchor corner fixed).

const std = @import("std");
const zpui = @import("zpui");
const art = @import("art.zig");
const render = @import("render.zig");
const legends = @import("legends.zig");
const app_mod = @import("app.zig");

const Window = zpui.Window;
const App = zpui.App;
const Bounds = zpui.Bounds(zpui.Pixels);
const Point = zpui.Point(zpui.Pixels);
const input = zpui.input;
const Typebud = app_mod.Typebud;

pub const grip_size: f32 = 18;

pub const PetView = struct {
    pub fn init(_: *Window, _: *zpui.Context(PetView)) PetView {
        return .{};
    }

    pub fn render(_: *PetView, _: *Window, _: *zpui.Context(PetView)) zpui.Div {
        const tb = app_mod.instance;
        var root = zpui.div().relative().size(zpui.relative(1)).child(zpui.canvas(tb, paint).size(zpui.relative(1)));
        // The bubble steps aside for the resize grip while the pointer is over the pet.
        if (tb.settings.show_wpm and !tb.hovered and tb.drag == .none) if (tb.wpm.shown) |v| {
            root = root.child(wpmBubble(tb, v));
        };
        return root;
    }
};

/// The "Show WPM" bubble: a little rounded pill in the window's top-left corner (clear
/// of every animal's head, the headphones' notes and the excited arms), in the keycap
/// font, sized with the pet but never below a legible 9 px. Drawn text, not part of the
/// input region, so clicks still pass through around the pet.
pub fn wpmBubble(tb: *Typebud, value: u16) zpui.Div {
    const size = tb.petSize();
    const h = std.math.clamp(size * 0.105, 16, 30);
    const font = h * 0.6;
    const inset = @round(@max(size * 0.03, 3));
    const c = bubbleColors(tb.settings.vibe);
    return zpui.div().absolute().left(zpui.px(inset)).top(zpui.px(inset)).h(zpui.px(h)).px(zpui.px(@round(h * 0.42)))
        .flex().flexRow().itemsCenter().gap(zpui.px(@round(font * 0.28))).roundedFull()
        .bg(c.bg).border1().borderColor(c.border).whitespaceNowrap()
        .fontFamily("Nunito").fontWeight(800).textColor(c.fg).textSize(zpui.px(font))
        .child(zpui.fmt("{d}", .{value}))
        .child(zpui.div().textSize(zpui.px(@round(font * 0.78))).textColor(c.dim).child("wpm"));
}

const BubbleColors = struct { bg: zpui.Hsla, border: zpui.Hsla, fg: zpui.Hsla, dim: zpui.Hsla };

fn bubbleColors(v: art.Vibe) BubbleColors {
    return switch (v) {
        .dark => .{ .bg = zpui.rgba(0x262a33eb).toHsla(), .border = zpui.rgba(0xffffff2e).toHsla(), .fg = zpui.rgb(0xf6f3ec).toHsla(), .dim = zpui.rgb(0xb4bac6).toHsla() },
        .bright => .{ .bg = zpui.rgba(0xfffffff0).toHsla(), .border = zpui.rgba(0x3a3a4626).toHsla(), .fg = zpui.rgb(0x3a3a46).toHsla(), .dim = zpui.rgb(0x8a8a96).toHsla() },
        .pink => .{ .bg = zpui.rgba(0xfff3f7f0).toHsla(), .border = zpui.rgba(0xd9578d40).toHsla(), .fg = zpui.rgb(0xc2457a).toHsla(), .dim = zpui.rgb(0xe08aae).toHsla() },
    };
}

const Ctx = struct { tb: *Typebud };

/// The pet as drawn now (shared by the window and the settings preview).
pub fn currentPet(tb: *Typebud, now: u64, origin: [2]f32, size: f32, raster_px: u32, legend_size: f32) render.Pet {
    const frame = tb.state.frame(now);
    const m = tb.state.motion(now);
    const head = tb.catalog.animals[tb.animal].anchors.head;
    return .{
        .animal = tb.animal,
        .vibe = tb.settings.vibe,
        .frame = frame,
        .outfit = tb.outfit(frame),
        .motion = .{ .dy = m.dy, .squash = m.squash, .pivot = .{ head.cx, 236 } },
        .origin = origin,
        .size = size,
        .raster_px = raster_px,
        .legend_size = legend_size,
    };
}

fn paint(tb: *Typebud, bounds: Bounds, w: *Window, _: *App) void {
    const now = tb.now();
    _ = tb.state.update(now);
    const scale = w.scaleFactor();
    const size = tb.petSize();
    tb.cache.atlas = w.sprite_atlas;
    if (tb.drag != .resize) {
        const px: u32 = @intFromFloat(@round(size * scale));
        if (px != tb.raster_px) {
            tb.raster_px = px;
            tb.cache.retainOnly(tb.animal, tb.settings.vibe, px);
        }
    }
    const raster_size = @as(f32, @floatFromInt(tb.raster_px)) / scale;
    const kb = art.Affine.keyboard(tb.catalog.animals[tb.animal].anchors.keyboard);
    if (tb.font_id) |fid| if (!tb.layout.matches(raster_size, scale, kb)) {
        legends.layout(&tb.layout, tb.app.textSystem(), fid, &tb.keys, raster_size, scale, kb);
    };
    const origin: [2]f32 = .{ bounds.origin.x, bounds.origin.y };
    const pet = currentPet(tb, now, origin, size, tb.raster_px, raster_size);
    const ctx: render.Context = .{
        .catalog = tb.catalog,
        .cache = &tb.cache,
        .legend_layout = if (tb.font_id != null) &tb.layout else null,
        .legend_colors = render.legendColors(tb.catalog),
    };
    var wp: render.WindowPainter = .{ .window = w };
    render.paint(pet, ctx, wp.painter());

    updateRegion(tb, w, pet, ctx, scale);
    if (tb.hovered or tb.drag == .resize) paintGrip(tb, w, origin);

    w.onMouseEvent(input.MouseDownEvent, Ctx{ .tb = tb }, onMouseDown);
    w.onMouseEvent(input.MouseMoveEvent, Ctx{ .tb = tb }, onMouseMove);
    w.onMouseEvent(input.MouseUpEvent, Ctx{ .tb = tb }, onMouseUp);
    w.onMouseEvent(input.MouseExitEvent, Ctx{ .tb = tb }, onMouseExit);

    if (tb.state.animating(now)) w.requestAnimationFrame();
    tb.frames_drawn += 1;
    if (tb.frame_hook) |f| f(tb);
}

/// The grip's rectangle: the corner of what is drawn opposite the anchored corner.
pub fn gripRect(tb: *Typebud) Bounds {
    var box: Bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = tb.petSize(), .height = tb.petSize() } };
    if (tb.region_len > 0) {
        box = tb.region[0];
        for (tb.region[1..tb.region_len]) |r| box = render.unionB(box, r);
    }
    const g = grip_size;
    const right = box.origin.x + box.size.width;
    const bottom = box.origin.y + box.size.height;
    const pos: Point = switch (tb.anchor.corner) {
        .bottom_right => .{ .x = box.origin.x, .y = box.origin.y },
        .bottom_left => .{ .x = right - g, .y = box.origin.y },
        .top_right => .{ .x = box.origin.x, .y = bottom - g },
        .top_left => .{ .x = right - g, .y = bottom - g },
    };
    return .{ .origin = pos, .size = .{ .width = g, .height = g } };
}

fn paintGrip(tb: *Typebud, w: *Window, origin: [2]f32) void {
    var g = gripRect(tb);
    g.origin.x += origin[0];
    g.origin.y += origin[1];
    const dark = tb.settings.vibe == .dark;
    const fill = if (dark) zpui.rgba(0x2a2d35e6) else zpui.rgba(0xffffffe6);
    const line = if (dark) zpui.rgba(0xd8dce4ff) else zpui.rgba(0x5a5a66ff);
    w.paintQuad(zpui.quad(g, .all(5), fill.toHsla(), .all(1), line.toHsla(), .solid));
    // Three diagonal ticks pointing away from the anchor.
    const c: Point = .{ .x = g.origin.x + g.size.width / 2, .y = g.origin.y + g.size.height / 2 };
    const sx: f32 = if (tb.anchor.corner == .bottom_right or tb.anchor.corner == .top_right) -1 else 1;
    const sy: f32 = if (tb.anchor.corner == .bottom_right or tb.anchor.corner == .bottom_left) -1 else 1;
    for ([_]f32{ -3.5, 0, 3.5 }) |k| {
        const d: Bounds = .{ .origin = .{ .x = c.x + sx * k - 1.25, .y = c.y - sy * k - 1.25 }, .size = .{ .width = 2.5, .height = 2.5 } };
        w.paintQuad(zpui.fill(d, line.toHsla()).cornerRadii(zpui.Corners(zpui.Pixels).all(1.25)));
    }
}

fn updateRegion(tb: *Typebud, w: *Window, pet: render.Pet, ctx: render.Context, scale: f32) void {
    var rects: [5]Bounds = undefined;
    var n = render.hitRects(pet, ctx, scale, &rects);
    // Squash/bob only move the body a few px: the region keys off the frame and outfit.
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.asBytes(&pet.frame));
    h.update(std.mem.asBytes(&pet.outfit));
    h.update(std.mem.asBytes(&pet.size));
    h.update(std.mem.asBytes(&pet.animal));
    h.update(std.mem.asBytes(&tb.hovered));
    h.update(std.mem.asBytes(&tb.anchor.corner));
    const key = h.final();
    if (key == tb.region_key) return;
    tb.region_key = key;
    @memcpy(tb.region[0..n], rects[0..n]);
    tb.region_len = n;
    if (tb.hovered and n < rects.len) {
        rects[n] = gripRect(tb);
        n += 1;
    }
    w.setInputRegion(rects[0..n]);
}

fn inPet(tb: *Typebud, p: Point) bool {
    for (tb.region[0..tb.region_len]) |r| if (r.contains(p)) return true;
    return false;
}

fn onMouseDown(c: *Ctx, ev: *const input.MouseDownEvent, phase: zpui.DispatchPhase, w: *Window, _: *App) void {
    if (phase != .bubble or ev.button != .left) return;
    const tb = c.tb;
    if (tb.hovered and gripRect(tb).contains(ev.position)) {
        tb.beginDrag(.resize, w);
    } else if (inPet(tb, ev.position)) {
        if (ev.click_count >= 2) {
            tb.drag = .none;
            tb.openSettings();
            return;
        }
        tb.beginDrag(.move, w);
    }
    w.refresh();
}

fn onMouseMove(c: *Ctx, ev: *const input.MouseMoveEvent, phase: zpui.DispatchPhase, w: *Window, _: *App) void {
    if (phase != .bubble) return;
    const tb = c.tb;
    if (tb.drag != .none) {
        if (w.screenMousePosition()) |p| tb.dragTo(w, p);
        return;
    }
    const inside = inPet(tb, ev.position) or (tb.hovered and gripRect(tb).contains(ev.position));
    if (inside != tb.hovered) {
        tb.hovered = inside;
        w.refresh();
    }
}

fn onMouseUp(c: *Ctx, ev: *const input.MouseUpEvent, phase: zpui.DispatchPhase, w: *Window, _: *App) void {
    if (phase != .bubble or ev.button != .left) return;
    if (c.tb.drag != .none) c.tb.endDrag(w);
}

fn onMouseExit(c: *Ctx, _: *const input.MouseExitEvent, phase: zpui.DispatchPhase, w: *Window, _: *App) void {
    if (phase != .bubble) return;
    if (c.tb.drag == .none and c.tb.hovered) {
        c.tb.hovered = false;
        w.refresh();
    }
}
