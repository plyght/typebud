//! Layer image cache: every SVG layer the pet needs is recoloured (vibe + fur), placed
//! (anchors.json transform), rasterized once with lunasvg at the pet's device-pixel size,
//! cropped to its visible pixels and kept as a `RenderImage`. Frames then just composite
//! these images; nothing is re-rasterized until the size, vibe or animal changes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zpui = @import("zpui");
const art = @import("art.zig");
const assets = @import("assets.zig");

const svg = zpui.image.svg;
const RenderImage = zpui.RenderImage;

pub const Image = struct {
    img: *RenderImage,
    /// Crop rectangle inside the `px` × `px` canvas, device pixels.
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    /// Canvas size it was rasterized for.
    px: u32,
};

pub const Key = struct {
    /// Embedded asset path (static, so the pointer identifies it).
    path: usize,
    transform: u64,
    animal: u16,
    vibe: art.Vibe,
    px: u32,
};

pub const Stats = struct { rasterized: u64 = 0, raster_ns: u64 = 0, bytes: usize = 0 };

pub const LayerCache = struct {
    gpa: Allocator,
    catalog: *const art.Catalog,
    map: std.AutoHashMapUnmanaged(Key, ?Image) = .empty,
    scratch: std.ArrayList(u8) = .empty,
    /// Atlas the images were uploaded to (their tiles are evicted with them).
    atlas: ?*zpui.atlas.Atlas = null,
    stats: Stats = .{},

    pub fn init(gpa: Allocator, catalog: *const art.Catalog) LayerCache {
        return .{ .gpa = gpa, .catalog = catalog };
    }

    pub fn deinit(c: *LayerCache) void {
        c.clear();
        c.map.deinit(c.gpa);
        c.scratch.deinit(c.gpa);
    }

    fn drop(c: *LayerCache, img: Image) void {
        if (c.atlas) |a| a.evictImage(img.img.id, 1);
        c.stats.bytes -|= @as(usize, img.w) * img.h * 4;
        img.img.release();
    }

    pub fn clear(c: *LayerCache) void {
        var it = c.map.valueIterator();
        while (it.next()) |v| if (v.*) |img| c.drop(img);
        c.map.clearRetainingCapacity();
    }

    /// Drop every image not rasterized for (`animal`, `vibe`, `px`).
    pub fn retainOnly(c: *LayerCache, animal: usize, vibe: art.Vibe, px: u32) void {
        var it = c.map.iterator();
        var doomed: [256]Key = undefined;
        var n: usize = 0;
        while (it.next()) |e| {
            const k = e.key_ptr.*;
            if (k.animal == animal and k.vibe == vibe and k.px == px) continue;
            if (n == doomed.len) break;
            doomed[n] = k;
            n += 1;
        }
        for (doomed[0..n]) |k| if (c.map.fetchRemove(k)) |kv| if (kv.value) |img| c.drop(img);
    }

    pub fn count(c: *const LayerCache) usize {
        return c.map.count();
    }

    /// The image of `layer` for (`animal`, `vibe`) at a `px` × `px` canvas, rasterizing it
    /// on first use. Null for missing or fully transparent layers.
    pub fn get(c: *LayerCache, animal: usize, vibe: art.Vibe, layer: *const art.Layer, px: u32) ?Image {
        if (layer.kind != .svg or px == 0) return null;
        const key: Key = .{
            .path = @intFromPtr(layer.path.ptr),
            .transform = std.hash.Wyhash.hash(0, std.mem.asBytes(&layer.transform)),
            .animal = @intCast(animal),
            .vibe = vibe,
            .px = px,
        };
        const gop = c.map.getOrPut(c.gpa, key) catch return null;
        if (gop.found_existing) return gop.value_ptr.*;
        gop.value_ptr.* = c.rasterize(animal, vibe, layer, px) catch |e| blk: {
            std.log.warn("raster {s} at {d}px failed: {t}", .{ layer.path, px, e });
            break :blk null;
        };
        return gop.value_ptr.*;
    }

    fn rasterize(c: *LayerCache, animal: usize, vibe: art.Vibe, layer: *const art.Layer, px: u32) !?Image {
        const t0 = nowNs();
        const src = assets.get(layer.path) orelse return null;
        const cmap = c.catalog.colorMap(animal, vibe);
        try c.scratch.resize(c.gpa, src.len);
        art.recolorInto(c.scratch.items, src, &cmap);
        var doc_bytes: []const u8 = c.scratch.items;
        var wrapped: ?[]u8 = null;
        defer if (wrapped) |w| c.gpa.free(w);
        if (!layer.transform.isIdentity()) {
            wrapped = try art.wrapTransform(c.gpa, c.scratch.items, layer.transform);
            if (wrapped) |w| doc_bytes = w;
        }
        var pm = try svg.rasterizeBgra(c.gpa, doc_bytes, .{ .size = .{ .width = @intCast(px), .height = @intCast(px) } }, 0xFF000000);
        defer pm.deinit(c.gpa);
        const img = try cropToImage(c.gpa, pm.bytes, pm.width, pm.height, px);
        c.stats.rasterized += 1;
        c.stats.raster_ns += nowNs() - t0;
        if (img) |i| c.stats.bytes += @as(usize, i.w) * i.h * 4;
        return img;
    }
};

/// Crop straight BGRA `pixels` to the bounding box of non-transparent pixels (+1 px so
/// bilinear sampling at the edge stays clean) and wrap it in a `RenderImage`.
pub fn cropToImage(gpa: Allocator, pixels: []const u8, width: u32, height: u32, px: u32) !?Image {
    var x0: u32 = width;
    var y0: u32 = height;
    var x1: u32 = 0;
    var y1: u32 = 0;
    for (0..height) |y| {
        const row = pixels[y * width * 4 ..][0 .. width * 4];
        var first: ?u32 = null;
        var last: u32 = 0;
        var x: u32 = 0;
        while (x < width) : (x += 1) if (row[x * 4 + 3] != 0) {
            if (first == null) first = x;
            last = x;
        };
        if (first) |f| {
            x0 = @min(x0, f);
            x1 = @max(x1, last + 1);
            y0 = @min(y0, @as(u32, @intCast(y)));
            y1 = @as(u32, @intCast(y)) + 1;
        }
    }
    if (x1 <= x0 or y1 <= y0) return null;
    x0 -|= 1;
    y0 -|= 1;
    x1 = @min(width, x1 + 1);
    y1 = @min(height, y1 + 1);
    const w = x1 - x0;
    const h = y1 - y0;
    const out = try gpa.alloc(u8, @as(usize, w) * h * 4);
    errdefer gpa.free(out);
    for (0..h) |r| {
        const src = pixels[((y0 + r) * width + x0) * 4 ..][0 .. w * 4];
        @memcpy(out[r * w * 4 ..][0 .. w * 4], src);
    }
    const frames = try gpa.alloc(zpui.image.Frame, 1);
    errdefer gpa.free(frames);
    frames[0] = .{ .width = w, .height = h, .pixels = out };
    const img = try RenderImage.create(gpa, .{ .frames = frames, .scale_factor = 1 });
    return .{ .img = img, .x = x0, .y = y0, .w = w, .h = h, .px = px };
}

const nowNs = @import("clock.zig").nowNs;

test "crop keeps the visible box plus a 1 px margin" {
    const gpa = std.testing.allocator;
    var px: [8 * 8 * 4]u8 = @splat(0);
    px[(3 * 8 + 4) * 4 + 3] = 255;
    px[(5 * 8 + 2) * 4 + 3] = 10;
    const img = (try cropToImage(gpa, &px, 8, 8, 8)).?;
    defer img.img.release();
    try std.testing.expectEqual(@as(u32, 1), img.x);
    try std.testing.expectEqual(@as(u32, 2), img.y);
    try std.testing.expectEqual(@as(u32, 5), img.w);
    try std.testing.expectEqual(@as(u32, 5), img.h);
    var empty: [4 * 4 * 4]u8 = @splat(0);
    try std.testing.expect((try cropToImage(gpa, &empty, 4, 4, 4)) == null);
}

test "every frame of every animal rasterizes at 96 px" {
    const gpa = std.testing.allocator;
    const cat = try art.Catalog.init(gpa);
    defer cat.deinit(gpa);
    var cache = LayerCache.init(gpa, cat);
    defer cache.deinit();
    for (cat.list(), 0..) |*a, ai| {
        for (std.meta.tags(art.Frame)) |f| {
            const s = a.layers(f, .{ .head = .headphones, .held = .coffee });
            for (s.items()) |*l| {
                if (l.kind != .svg) continue;
                if (std.mem.endsWith(u8, l.name.slice(), "zzz") or std.mem.endsWith(u8, l.name.slice(), "notes")) continue;
                if (cache.get(ai, .bright, l, 96) == null) {
                    std.debug.print("{s}: {s} rasterized to nothing\n", .{ a.name, l.path });
                    return error.EmptyLayer;
                }
            }
        }
    }
    try std.testing.expect(cache.count() > 20);
}
