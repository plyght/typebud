//! Keycap legends (art/_shared/keyboard_keys.json): drawn with the text system in the
//! board's own affine frame — glyph x along `u`, glyph up along `v` — like
//! render_art.py's FreeType path. Layout (glyph ids, origins, matrices) is computed once
//! per pet size and kept; painting is one transformed glyph sprite per character.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const zpui = @import("zpui");
const art = @import("art.zig");
const assets = @import("assets.zig");

const TransformationMatrix = zpui.scene.TransformationMatrix;
const text = zpui.text;

pub const max_keys = 80;
pub const max_chars = 6;

pub const Key = struct {
    label: [max_chars]u8 = undefined,
    label_len: u8 = 0,
    center: [2]f32,
    em: f32,
};

/// The parsed key list (labels with this OS's modifier row applied).
pub const Keys = struct {
    keys: [max_keys]Key = undefined,
    len: usize = 0,
    u: [2]f32 = .{ 1, 0 },
    v: [2]f32 = .{ 0, -1 },
    font_path: []const u8 = "assets/fonts/Nunito-ExtraBold.ttf",

    pub fn parse(arena: Allocator, json: []const u8, os: []const u8) !Keys {
        const Raw = struct {
            font: []const u8 = "assets/fonts/Nunito-ExtraBold.ttf",
            u: [2]f32,
            v: [2]f32,
            os_overrides: std.json.Value = .null,
            keys: []const struct { row: u32, index: u32, label: []const u8, center: [2]f32, em: f32 },
        };
        const raw = try std.json.parseFromSliceLeaky(Raw, arena, json, .{ .ignore_unknown_fields = true });
        var k: Keys = .{ .u = raw.u, .v = raw.v, .font_path = raw.font };
        for (raw.keys) |key| {
            var label = key.label;
            if (raw.os_overrides == .object) if (raw.os_overrides.object.get(os)) |ov| if (ov == .object) {
                var rb: [8]u8 = undefined;
                const row_key = std.fmt.bufPrint(&rb, "{d}", .{key.row}) catch "";
                if (ov.object.get(row_key)) |row| if (row == .array and key.index < row.array.items.len) {
                    const s = row.array.items[key.index];
                    if (s == .string) label = s.string;
                };
            };
            if (label.len == 0 or k.len == max_keys) continue;
            var e: Key = .{ .center = key.center, .em = key.em };
            e.label_len = @intCast(@min(label.len, max_chars));
            @memcpy(e.label[0..e.label_len], label[0..e.label_len]);
            k.keys[k.len] = e;
            k.len += 1;
        }
        return k;
    }
};

/// `os_overrides` name for this build.
pub const os_name: []const u8 = switch (builtin.os.tag) {
    .macos => "macos",
    .linux => "linux",
    else => "default",
};

pub const Glyph = struct {
    id: text.GlyphId,
    /// Untransformed baseline origin, logical px relative to the pet's top-left.
    origin: [2]f32,
    /// Index of the key (all glyphs of a key share its matrix).
    key: u8,
};

pub const KeyXform = struct {
    /// Rotation/scale part (device px → device px) and the pivot (key centre, logical px
    /// relative to the pet's top-left) it applies around.
    m: [2][2]f32,
    pivot: [2]f32,
};

/// Glyphs for one pet size: rebuilt when the size, scale or keyboard placement changes.
pub const Layout = struct {
    glyphs: [max_keys * max_chars]Glyph = undefined,
    glyph_len: usize = 0,
    xforms: [max_keys]KeyXform = undefined,
    /// Font size (logical px) the glyphs rasterize at.
    font_size: f32 = 0,
    font_id: text.FontId = undefined,
    // what it was built for
    size: f32 = 0,
    scale: f32 = 0,
    kb: art.Affine = .{},
    valid: bool = false,

    pub fn matches(l: *const Layout, size: f32, scale: f32, kb: art.Affine) bool {
        return l.valid and l.size == size and l.scale == scale and std.meta.eql(l.kb, kb);
    }
};

/// Build the layout for a `size` × `size` logical-px pet at `scale` device px / logical px.
pub fn layout(out: *Layout, ts: *text.TextSystem, font_id: text.FontId, keys: *const Keys, size: f32, scale: f32, kb: art.Affine) void {
    out.* = .{ .size = size, .scale = scale, .kb = kb, .font_id = font_id, .valid = true };
    const unit = size / 256.0; // logical px per viewBox unit
    const dev = unit * scale; // device px per viewBox unit
    const u = keys.u;
    const v = keys.v;
    const det = @abs(u[0] * v[1] - v[0] * u[1]);
    const L = @sqrt(@max(det, 1e-6));
    // All keys share `em` in practice; the font size uses the first key's.
    const em0 = if (keys.len > 0) keys.keys[0].em else 0.2;
    const kb_scale = kb.a;
    // Device px per glyph em, then the glyph raster size that makes the matrix area-preserving.
    const f_dev = em0 * 1.35 * kb_scale * dev * L;
    out.font_size = f_dev / scale;
    if (f_dev < 1.2) {
        // Too small to read (SPEC: legends may vanish below ~160 px); draw nothing.
        out.glyph_len = 0;
        return;
    }
    const m: [2][2]f32 = .{ .{ u[0] / L, -v[0] / L }, .{ u[1] / L, -v[1] / L } };
    for (keys.keys[0..keys.len], 0..) |key, ki| {
        // Pen positions and ink box of the label, device px, relative to the line origin.
        var pen: f32 = 0;
        var ink_l: f32 = std.math.floatMax(f32);
        var ink_t: f32 = std.math.floatMax(f32);
        var ink_r: f32 = -std.math.floatMax(f32);
        var ink_b: f32 = -std.math.floatMax(f32);
        const first = out.glyph_len;
        for (key.label[0..key.label_len]) |ch| {
            const gid = ts.platform.vtable.glyphForChar(ts.platform.ptr, font_id, ch) orelse continue;
            const adv = (ts.advance(font_id, out.font_size, ch) catch continue).width * scale;
            const params: text.RenderGlyphParams = .{
                .font_id = font_id,
                .glyph_id = gid,
                .font_size = out.font_size,
                .subpixel_variant_x = 0,
                .subpixel_variant_y = 0,
                .is_emoji = false,
                .subpixel_rendering = false,
                .scale_factor = scale,
            };
            const rb_or = ts.rasterBounds(params);
            if (rb_or) |rb| {
                if (rb.size.width > 0 and rb.size.height > 0) {
                    const l: f32 = @floatFromInt(rb.origin.x);
                    const t: f32 = @floatFromInt(rb.origin.y);
                    ink_l = @min(ink_l, pen + l);
                    ink_r = @max(ink_r, pen + l + @as(f32, @floatFromInt(rb.size.width)));
                    ink_t = @min(ink_t, t);
                    ink_b = @max(ink_b, t + @as(f32, @floatFromInt(rb.size.height)));
                }
            } else |_| {}
            if (out.glyph_len < out.glyphs.len) {
                out.glyphs[out.glyph_len] = .{ .id = gid, .origin = .{ pen, 0 }, .key = @intCast(ki) };
                out.glyph_len += 1;
            }
            pen += adv;
        }
        if (out.glyph_len == first or ink_r <= ink_l) {
            out.glyph_len = first;
            continue;
        }
        // Key centre (logical px), then place the line so its ink box is centred on it.
        const c = kb.apply(key.center[0], key.center[1]);
        const cx = c[0] * unit;
        const cy = c[1] * unit;
        const gcx = (ink_l + ink_r) / 2 / scale;
        const gcy = (ink_t + ink_b) / 2 / scale;
        for (out.glyphs[first..out.glyph_len]) |*g| {
            g.origin = .{ cx - gcx + g.origin[0] / scale, cy - gcy };
        }
        out.xforms[ki] = .{ .m = m, .pivot = .{ cx, cy } };
    }
}

/// The sprite matrix for key `k` when the pet's top-left is at `origin` (logical px) and
/// the layout is drawn `stretch` times its built size (live resize), device px.
pub fn matrix(l: *const Layout, k: usize, origin: [2]f32, stretch: f32, scale: f32) TransformationMatrix {
    const x = l.xforms[k];
    const r: [2][2]f32 = .{ .{ x.m[0][0] * stretch, x.m[0][1] * stretch }, .{ x.m[1][0] * stretch, x.m[1][1] * stretch } };
    // Pivot before (as laid out) and after (stretched) placement, device px.
    const px = (origin[0] + x.pivot[0]) * scale;
    const py = (origin[1] + x.pivot[1]) * scale;
    const qx = (origin[0] + x.pivot[0] * stretch) * scale;
    const qy = (origin[1] + x.pivot[1] * stretch) * scale;
    return .{ .rotation_scale = r, .translation = .{ qx - (r[0][0] * px + r[0][1] * py), qy - (r[1][0] * px + r[1][1] * py) } };
}

test "keys parse with the OS modifier row" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const json = assets.get("art/_shared/keyboard_keys.json").?;
    const mac = try Keys.parse(arena.allocator(), json, "macos");
    const lin = try Keys.parse(arena.allocator(), json, "linux");
    try std.testing.expect(mac.len > 40);
    var has_cmd = false;
    for (mac.keys[0..mac.len]) |k| has_cmd = has_cmd or std.mem.eql(u8, k.label[0..k.label_len], "cmd");
    try std.testing.expect(has_cmd);
    var has_super = false;
    for (lin.keys[0..lin.len]) |k| has_super = has_super or std.mem.eql(u8, k.label[0..k.label_len], "super");
    try std.testing.expect(has_super);
}

test "legend matrix pivots on the key centre" {
    var l: Layout = .{};
    l.xforms[0] = .{ .m = .{ .{ 0.5, 0.2 }, .{ -0.1, 0.9 } }, .pivot = .{ 40, 30 } };
    const t = matrix(&l, 0, .{ 10, 5 }, 1, 2);
    const p = t.apply(.{ .x = 100, .y = 70 });
    try std.testing.expectApproxEqAbs(@as(f32, 100), p.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 70), p.y, 1e-4);
    const t2 = matrix(&l, 0, .{ 10, 5 }, 2, 2);
    const p2 = t2.apply(.{ .x = 100, .y = 70 });
    try std.testing.expectApproxEqAbs(@as(f32, (10 + 80) * 2), p2.x, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, (5 + 60) * 2), p2.y, 1e-3);
}
