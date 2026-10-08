//! Offscreen renders of the pet (smoke screenshots, contact sheets): the same `render.paint`
//! path as the window, into a zpui offscreen renderer, read back as straight RGBA.

const std = @import("std");
const zpui = @import("zpui");
const art = @import("art.zig");
const raster = @import("raster.zig");
const legends = @import("legends.zig");
const render = @import("render.zig");
const assets = @import("assets.zig");

const Renderer = zpui.renderer.Renderer;

pub const Snapshotter = struct {
    gpa: std.mem.Allocator,
    catalog: *const art.Catalog,
    text_system: *zpui.text.TextSystem,
    font_id: zpui.text.FontId,
    keys: *const legends.Keys,
    scene: zpui.Scene = .{},
    cache: raster.LayerCache,
    layout: legends.Layout = .{},
    renderer: ?Renderer = null,
    renderer_size: u32 = 0,

    pub fn init(gpa: std.mem.Allocator, catalog: *const art.Catalog, ts: *zpui.text.TextSystem, font_id: zpui.text.FontId, keys: *const legends.Keys) Snapshotter {
        return .{ .gpa = gpa, .catalog = catalog, .text_system = ts, .font_id = font_id, .keys = keys, .cache = .init(gpa, catalog) };
    }

    pub fn deinit(s: *Snapshotter) void {
        s.cache.deinit();
        s.cache.atlas = null;
        s.scene.deinit(s.gpa);
        if (s.renderer) |*r| r.deinit();
    }

    /// Render `pet` (its `size` is in device px here; scale 1) to straight RGBA, caller frees.
    pub fn renderRgba(s: *Snapshotter, pet_in: render.Pet) ![]u8 {
        const px: u32 = @intFromFloat(@round(pet_in.size));
        if (s.renderer == null or s.renderer_size != px) {
            s.cache.clear();
            s.cache.atlas = null;
            if (s.renderer) |*r| r.deinit();
            s.renderer = null;
            s.renderer = try Renderer.init(s.gpa, .{ .size = .{ .width = @intCast(px), .height = @intCast(px) }, .transparent = true });
            s.renderer_size = px;
        }
        const r = &s.renderer.?;
        s.cache.atlas = r.atlas();
        var pet = pet_in;
        pet.raster_px = px;
        pet.legend_size = pet.size;
        const kb = art.Affine.keyboard(s.catalog.animals[pet.animal].anchors.keyboard);
        if (!s.layout.matches(pet.size, 1, kb)) legends.layout(&s.layout, s.text_system, s.font_id, s.keys, pet.size, 1, kb);
        s.scene.clear(s.gpa);
        const full: zpui.scene.ContentMask = .{ .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = pet.size, .height = pet.size } } };
        var sp: render.ScenePainter = .{ .gpa = s.gpa, .scene = &s.scene, .atlas = r.atlas(), .text_system = s.text_system, .scale = 1, .clip = full };
        render.paint(pet, .{ .catalog = s.catalog, .cache = &s.cache, .legend_layout = &s.layout, .legend_colors = render.legendColors(s.catalog) }, sp.painter());
        s.scene.finish();
        const size: zpui.Size(zpui.DevicePixels) = .{ .width = @intCast(px), .height = @intCast(px) };
        try r.drawScene(&s.scene, size, 1, zpui.color.transparent_black);
        const pixels = try r.readPixels(s.gpa);
        unpremultiply(pixels);
        return pixels;
    }
};

pub fn unpremultiply(rgba: []u8) void {
    var i: usize = 0;
    while (i + 4 <= rgba.len) : (i += 4) {
        const a: u32 = rgba[i + 3];
        if (a == 0 or a == 255) continue;
        for (rgba[i..][0..3]) |*c| c.* = @intCast(@min(255, (@as(u32, c.*) * 255 + a / 2) / a));
    }
}

/// A straight-RGBA canvas for contact sheets.
pub const Sheet = struct {
    w: u32,
    h: u32,
    px: []u8,

    pub fn init(gpa: std.mem.Allocator, w: u32, h: u32, bg: [4]u8) !Sheet {
        const px = try gpa.alloc(u8, @as(usize, w) * h * 4);
        var i: usize = 0;
        while (i < px.len) : (i += 4) px[i..][0..4].* = bg;
        return .{ .w = w, .h = h, .px = px };
    }
    pub fn deinit(s: *Sheet, gpa: std.mem.Allocator) void {
        gpa.free(s.px);
    }
    pub fn fill(s: *Sheet, x: u32, y: u32, w: u32, h: u32, c: [4]u8) void {
        for (y..@min(s.h, y + h)) |yy| for (x..@min(s.w, x + w)) |xx| {
            s.px[(yy * s.w + xx) * 4 ..][0..4].* = c;
        };
    }
    /// Alpha-composite straight RGBA `src` (w × h) at (x, y).
    pub fn blit(s: *Sheet, x: u32, y: u32, src: []const u8, w: u32, h: u32) void {
        for (0..h) |yy| for (0..w) |xx| {
            const dx = x + xx;
            const dy = y + yy;
            if (dx >= s.w or dy >= s.h) continue;
            const sp = src[(yy * w + xx) * 4 ..][0..4];
            const dp = s.px[(dy * s.w + dx) * 4 ..][0..4];
            const a: u32 = sp[3];
            for (0..3) |c| dp[c] = @intCast((@as(u32, sp[c]) * a + @as(u32, dp[c]) * (255 - a) + 127) / 255);
            dp[3] = @intCast(@min(255, a + @as(u32, dp[3]) * (255 - a) / 255));
        };
    }
    pub fn writePng(s: *const Sheet, gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
        const png = try zpui.image.encodePng(gpa, s.px, s.w, s.h, .rgba);
        defer gpa.free(png);
        if (std.fs.path.dirname(path)) |d| try std.Io.Dir.cwd().createDirPath(io, d);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = png });
    }
};

pub fn writeRgbaPng(gpa: std.mem.Allocator, io: std.Io, path: []const u8, rgba: []const u8, w: u32, h: u32) !void {
    const png = try zpui.image.encodePng(gpa, rgba, w, h, .rgba);
    defer gpa.free(png);
    if (std.fs.path.dirname(path)) |d| try std.Io.Dir.cwd().createDirPath(io, d);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = png });
}

/// Backdrops of render_art.py's sheets per vibe.
pub const backdrops = [3][4]u8{ .{ 30, 30, 36, 255 }, .{ 245, 245, 240, 255 }, .{ 255, 228, 236, 255 } };

/// render_art.py-style sheet: every frame (columns) × every vibe (rows), headphones and
/// coffee on, at `cell` px.
pub fn animalSheet(s: *Snapshotter, io: std.Io, animal: usize, cell: u32, path: []const u8) !void {
    const frames = std.meta.tags(art.Frame);
    var sheet = try Sheet.init(s.gpa, cell * @as(u32, @intCast(frames.len)), cell * 3, .{ 255, 255, 255, 255 });
    defer sheet.deinit(s.gpa);
    for (frames, 0..) |f, col| for (std.meta.tags(art.Vibe), 0..) |v, row| {
        const x: u32 = @intCast(col * cell);
        const y: u32 = @intCast(row * cell);
        sheet.fill(x, y, cell, cell, backdrops[row]);
        const held: art.HeldItem = if (f == .hold or f == .sip) .coffee else .none;
        const rgba = try s.renderRgba(.{ .animal = animal, .vibe = v, .frame = f, .outfit = .{ .head = .headphones, .held = held }, .origin = .{ 0, 0 }, .size = @floatFromInt(cell), .raster_px = cell, .legend_size = @floatFromInt(cell) });
        defer s.gpa.free(rgba);
        sheet.blit(x, y, rgba, cell, cell);
    };
    try sheet.writePng(s.gpa, io, path);
}
