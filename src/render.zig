//! Composites the pet: the layer stack of the current frame, drawn back to front from the
//! cached layer images, plus the keycap legends. One code path paints into a live zpui
//! window (`WindowPainter`) and into an offscreen scene for screenshots (`ScenePainter`).

const std = @import("std");
const zpui = @import("zpui");
const art = @import("art.zig");
const raster = @import("raster.zig");
const legends = @import("legends.zig");

const Bounds = zpui.Bounds(zpui.Pixels);
const TransformationMatrix = zpui.scene.TransformationMatrix;
const Hsla = zpui.Hsla;

/// Where pixels go. `scale` is device px per logical px.
pub const Painter = struct {
    ctx: *anyopaque,
    scale: f32,
    image: *const fn (ctx: *anyopaque, bounds: Bounds, img: *zpui.RenderImage, opacity: f32) void,
    glyph: *const fn (ctx: *anyopaque, origin: zpui.Point(zpui.Pixels), font_id: zpui.text.FontId, glyph_id: zpui.text.GlyphId, font_size: f32, color: Hsla, t: TransformationMatrix) void,
};

/// Small per-frame body motion (viewBox units), applied to the `body` group only.
pub const Motion = struct {
    /// Vertical offset (negative = up).
    dy: f32 = 0,
    /// Squash: >0 squashes (shorter, wider), <0 stretches.
    squash: f32 = 0,
    /// Pivot of the squash (the body's base), viewBox units.
    pivot: [2]f32 = .{ 128, 236 },
};

pub const Pet = struct {
    animal: usize,
    vibe: art.Vibe,
    frame: art.Frame,
    outfit: art.Outfit,
    motion: Motion = .{},
    /// Top-left of the 256-unit canvas and its edge length, logical px.
    origin: [2]f32,
    size: f32,
    /// Device-pixel canvas the layer images come from (== size * scale except while a
    /// resize drag scales the old images).
    raster_px: u32,
    /// Size the legend layout was built for (legends stretch like the images).
    legend_size: f32,
};

pub const Context = struct {
    catalog: *const art.Catalog,
    cache: *raster.LayerCache,
    legend_layout: ?*const legends.Layout,
    legend_colors: [3]Hsla,
};

/// Paint `pet` through `p`. Allocation-free once every needed image is cached.
pub fn paint(pet: Pet, ctx: Context, p: Painter) void {
    const a = &ctx.catalog.animals[pet.animal];
    const stack = a.layers(pet.frame, pet.outfit);
    const unit = pet.size / 256.0;
    const k = pet.size / (@as(f32, @floatFromInt(pet.raster_px)) / p.scale); // image px → logical
    for (stack.items()) |*layer| {
        switch (layer.kind) {
            .legends => paintLegends(pet, ctx, p),
            .svg => {
                const img = ctx.cache.get(pet.animal, pet.vibe, layer, pet.raster_px) orelse continue;
                const s = k / p.scale;
                var b: Bounds = .{
                    .origin = .{ .x = pet.origin[0] + @as(f32, @floatFromInt(img.x)) * s, .y = pet.origin[1] + @as(f32, @floatFromInt(img.y)) * s },
                    .size = .{ .width = @as(f32, @floatFromInt(img.w)) * s, .height = @as(f32, @floatFromInt(img.h)) * s },
                };
                if (layer.group == .body) b = moveBody(b, pet, unit);
                p.image(p.ctx, b, img.img, 1);
            },
        }
    }
}

/// Bob and squash about the body's base (in logical px).
fn moveBody(b: Bounds, pet: Pet, unit: f32) Bounds {
    const m = pet.motion;
    if (m.dy == 0 and m.squash == 0) return b;
    const sx = 1 + m.squash * 0.5;
    const sy = 1 - m.squash;
    const px = pet.origin[0] + m.pivot[0] * unit;
    const py = pet.origin[1] + m.pivot[1] * unit;
    return .{
        .origin = .{ .x = px + (b.origin.x - px) * sx, .y = py + (b.origin.y - py) * sy + m.dy * unit },
        .size = .{ .width = b.size.width * sx, .height = b.size.height * sy },
    };
}

fn paintLegends(pet: Pet, ctx: Context, p: Painter) void {
    const l = ctx.legend_layout orelse return;
    if (!l.valid or l.glyph_len == 0) return;
    const stretch = pet.size / l.size;
    const color = ctx.legend_colors[@intFromEnum(pet.vibe)];
    var last_key: usize = std.math.maxInt(usize);
    var t: TransformationMatrix = .{};
    for (l.glyphs[0..l.glyph_len]) |g| {
        if (g.key != last_key) {
            last_key = g.key;
            t = legends.matrix(l, g.key, pet.origin, stretch, p.scale);
        }
        p.glyph(p.ctx, .{ .x = pet.origin[0] + g.origin[0], .y = pet.origin[1] + g.origin[1] }, l.font_id, g.id, l.font_size, color, t);
    }
}

/// Keycap legend colour per vibe (themes.json `keycap_legend`).
pub fn legendColors(catalog: *const art.Catalog) [3]Hsla {
    var out: [3]Hsla = undefined;
    for (std.meta.tags(art.Vibe), 0..) |v, i| {
        const hex = catalog.themes.gear(v, "keycap_legend") orelse art.parseHex("#B8C0CC").?;
        out[i] = zpui.rgb(art.hexRgb(hex)).toHsla();
    }
    return out;
}

/// Coarse hit rectangles (logical px, relative to the canvas origin) of what is drawn:
/// the animal (frame + paws) and the keyboard, for the window's input region.
pub fn hitRects(pet: Pet, ctx: Context, scale: f32, out: []Bounds) usize {
    const a = &ctx.catalog.animals[pet.animal];
    const stack = a.layers(pet.frame, pet.outfit);
    const k = pet.size / (@as(f32, @floatFromInt(pet.raster_px)) / scale) / scale;
    var n: usize = 0;
    var body: ?Bounds = null;
    for (stack.items()) |*layer| {
        if (layer.kind != .svg) continue;
        const img = ctx.cache.get(pet.animal, pet.vibe, layer, pet.raster_px) orelse continue;
        const b: Bounds = .{
            .origin = .{ .x = @as(f32, @floatFromInt(img.x)) * k, .y = @as(f32, @floatFromInt(img.y)) * k },
            .size = .{ .width = @as(f32, @floatFromInt(img.w)) * k, .height = @as(f32, @floatFromInt(img.h)) * k },
        };
        switch (layer.group) {
            .body, .paws, .held => body = if (body) |x| unionB(x, b) else b,
            .gear => if (n < out.len) {
                out[n] = b;
                n += 1;
            },
            else => {},
        }
    }
    if (body) |b| if (n < out.len) {
        out[n] = b;
        n += 1;
    };
    return n;
}

pub fn unionB(a: Bounds, b: Bounds) Bounds {
    const l = @min(a.origin.x, b.origin.x);
    const t = @min(a.origin.y, b.origin.y);
    const r = @max(a.origin.x + a.size.width, b.origin.x + b.size.width);
    const btm = @max(a.origin.y + a.size.height, b.origin.y + b.size.height);
    return .{ .origin = .{ .x = l, .y = t }, .size = .{ .width = r - l, .height = btm - t } };
}

// ---- painters ---------------------------------------------------------------------------

/// Paints into the current zpui window (inside a canvas' paint callback).
pub const WindowPainter = struct {
    window: *zpui.Window,

    pub fn painter(self: *WindowPainter) Painter {
        return .{ .ctx = self, .scale = self.window.scaleFactor(), .image = image, .glyph = glyph };
    }
    fn image(ctx: *anyopaque, b: Bounds, img: *zpui.RenderImage, opacity: f32) void {
        const self: *WindowPainter = @ptrCast(@alignCast(ctx));
        _ = opacity;
        self.window.paintImage(b, .all(0), img, 0, false);
    }
    fn glyph(ctx: *anyopaque, origin: zpui.Point(zpui.Pixels), font_id: zpui.text.FontId, glyph_id: zpui.text.GlyphId, font_size: f32, color: Hsla, t: TransformationMatrix) void {
        const self: *WindowPainter = @ptrCast(@alignCast(ctx));
        paintLegendGlyph(self.window, origin, font_id, glyph_id, font_size, color, t);
    }
};

/// The one place legends reach zpui: swap to `paintGlyphRasterTransformed` (glyph outlines
/// transformed before rasterization) once zpui main has it.
pub fn paintLegendGlyph(w: *zpui.Window, origin: zpui.Point(zpui.Pixels), font_id: zpui.text.FontId, glyph_id: zpui.text.GlyphId, font_size: f32, color: Hsla, t: TransformationMatrix) void {
    w.paintGlyphTransformed(origin, font_id, glyph_id, font_size, color, t, 0);
}

/// Paints straight into a `Scene` whose sprites live in `atlas` (offscreen renders).
pub const ScenePainter = struct {
    gpa: std.mem.Allocator,
    scene: *zpui.Scene,
    atlas: *zpui.atlas.Atlas,
    text_system: *zpui.text.TextSystem,
    scale: f32,
    /// Device-pixel clip (the whole target).
    clip: zpui.scene.ContentMask,

    pub fn painter(self: *ScenePainter) Painter {
        return .{ .ctx = self, .scale = self.scale, .image = image, .glyph = glyph };
    }
    fn image(ctx: *anyopaque, b: Bounds, img: *zpui.RenderImage, opacity: f32) void {
        const self: *ScenePainter = @ptrCast(@alignCast(ctx));
        const tile = (self.atlas.getOrInsertWith(img.atlasKey(0), img.tileBuilder(0)) catch return) orelse return;
        const s = self.scale;
        const l = @round(b.origin.x * s);
        const t = @round(b.origin.y * s);
        self.scene.insertPolychromeSprite(self.gpa, .{
            .bounds = .{ .origin = .{ .x = l, .y = t }, .size = .{ .width = @round((b.origin.x + b.size.width) * s) - l, .height = @round((b.origin.y + b.size.height) * s) - t } },
            .content_mask = self.clip,
            .tile = tile,
            .opacity = opacity,
        }) catch {};
    }
    fn glyph(ctx: *anyopaque, origin: zpui.Point(zpui.Pixels), font_id: zpui.text.FontId, glyph_id: zpui.text.GlyphId, font_size: f32, color: Hsla, t: TransformationMatrix) void {
        const self: *ScenePainter = @ptrCast(@alignCast(ctx));
        const g = zpui.text.line.glyphRenderParams(font_id, glyph_id, font_size, origin, self.scale, false);
        const sprite = (self.text_system.rasterizeToAtlas(self.atlas, g.params, g.origin) catch return) orelse return;
        self.scene.insertMonochromeSprite(self.gpa, .{
            .bounds = sprite.bounds,
            .content_mask = self.clip,
            .color = color,
            .tile = sprite.tile,
            .transformation = t,
        }) catch {};
    }
};
