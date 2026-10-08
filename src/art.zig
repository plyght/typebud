//! The art model (art/SPEC.md): animals, frames, accessories, colour tokens and the
//! layer stack. `Animal.layers` is a line-for-line port of `scripts/render_art.py`
//! (`Animal.layers` + `find` + `transform_for` + the legends insertion in `stack`), the
//! reference the renderer must match.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assets = @import("assets.zig");

pub const Frame = enum {
    idle,
    peek,
    type_left,
    type_right,
    type_both,
    excited,
    sleep,
    wake,
    hold,
    sip,

    pub fn isTyping(f: Frame) bool {
        return switch (f) {
            .type_left, .type_right, .type_both, .excited => true,
            else => false,
        };
    }
    pub fn isSleepy(f: Frame) bool {
        return f == .sleep or f == .wake;
    }
};

pub const Vibe = enum {
    dark,
    bright,
    pink,

    pub const labels = [_][]const u8{ "Dark", "Bright", "Pink" };
};

pub const HeadItem = enum {
    none,
    headphones,
    beanie,
    party_hat,
    bow,
    glasses,
    yuzu,

    pub const labels = [_][]const u8{ "None", "Headphones", "Beanie", "Party Hat", "Bow", "Glasses", "Yuzu" };
};

pub const HeldItem = enum {
    none,
    coffee,
    boba,
    book,

    pub const labels = [_][]const u8{ "None", "Coffee", "Boba", "Book" };
};

pub const Desk = packed struct {
    lamp: bool = false,
    plant: bool = false,
    mug: bool = false,
};

/// What is on stage besides the frame (SPEC "Draw order").
pub const Outfit = struct {
    keyboard: bool = true,
    sparkles: bool = false,
    desk: Desk = .{},
    head: HeadItem = .none,
    /// Shown with the `hold` / `sip` frames only.
    held: HeldItem = .none,
};

/// 2D affine in viewBox units: x' = a x + c y + e, y' = b x + d y + f (SVG `matrix(a b c d e f)`).
pub const Affine = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    e: f32 = 0,
    f: f32 = 0,

    pub const identity: Affine = .{};

    pub fn isIdentity(m: Affine) bool {
        return m.a == 1 and m.b == 0 and m.c == 0 and m.d == 1 and m.e == 0 and m.f == 0;
    }
    pub fn apply(m: Affine, x: f32, y: f32) [2]f32 {
        return .{ m.a * x + m.c * y + m.e, m.b * x + m.d * y + m.f };
    }
    /// `translate(tx ty) translate(30 200) scale(s) translate(-30 -200)` (render_art.py).
    pub fn keyboard(kb: Keyboard) Affine {
        const s = kb.scale;
        return .{ .a = s, .d = s, .e = kb.translate[0] + 30 - 30 * s, .f = kb.translate[1] + 200 - 200 * s };
    }
    pub fn translate(x: f32, y: f32) Affine {
        return .{ .e = x, .f = y };
    }
};

pub const Keyboard = struct {
    translate: [2]f32 = .{ 0, 0 },
    scale: f32 = 1.0,
};

pub const Anchors = struct {
    keyboard: Keyboard = .{},
    overlays: Overlays = .{},
    paws: struct { left: [2]f32 = .{ 122, 168 }, right: [2]f32 = .{ 160, 180 } } = .{},
    head: struct { cx: f32 = 152, cy: f32 = 80, rx: f32 = 58, ry: f32 = 48 } = .{},

    pub const Overlays = struct {
        music_notes: ?[2]f32 = null,
        zzz: ?[2]f32 = null,
        motion: ?[2]f32 = null,
    };
};

// ---- colours ------------------------------------------------------------------------

pub const Hex = [7]u8;

/// One placeholder -> real colour substitution (upper-case "#RRGGBB" on both sides).
pub const Swap = struct { from: Hex, to: Hex };
pub const max_swaps = 32;

/// Placeholder hex -> real hex for one (vibe, animal) (render_art.py `color_map`).
pub const ColorMap = struct {
    swaps: [max_swaps]Swap = undefined,
    len: usize = 0,

    pub fn lookup(m: *const ColorMap, hex: []const u8) ?Hex {
        for (m.swaps[0..m.len]) |s| if (eqlHex(&s.from, hex)) return s.to;
        return null;
    }
    fn put(m: *ColorMap, from: Hex, to: Hex) void {
        for (m.swaps[0..m.len]) |*s| if (std.mem.eql(u8, &s.from, &from)) {
            s.to = to;
            return;
        };
        if (m.len == max_swaps) return;
        m.swaps[m.len] = .{ .from = from, .to = to };
        m.len += 1;
    }
};

fn eqlHex(a: *const Hex, b: []const u8) bool {
    if (b.len != 7) return false;
    for (a, b) |x, y| if (x != std.ascii.toUpper(y)) return false;
    return true;
}

fn isHexDigit(c: u8) bool {
    return std.ascii.isHex(c);
}
fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

pub fn parseHex(s: []const u8) ?Hex {
    if (s.len != 7 or s[0] != '#') return null;
    var out: Hex = undefined;
    out[0] = '#';
    for (s[1..], 1..) |c, i| {
        if (!isHexDigit(c)) return null;
        out[i] = std.ascii.toUpper(c);
    }
    return out;
}

/// 0xRRGGBB of a "#RRGGBB" hex.
pub fn hexRgb(h: Hex) u32 {
    return std.fmt.parseInt(u32, h[1..], 16) catch 0;
}

/// Single-pass recolor (render_art.py `recolor`: `#[0-9A-Fa-f]{6}\b`): every hex that is a
/// placeholder is replaced; a replacement is never re-replaced. Same length in and out, so
/// `out` must be `svg.len` bytes.
pub fn recolorInto(out: []u8, svg: []const u8, cmap: *const ColorMap) void {
    std.debug.assert(out.len == svg.len);
    @memcpy(out, svg);
    var i: usize = 0;
    while (i + 7 <= svg.len) : (i += 1) {
        if (svg[i] != '#') continue;
        const cand = svg[i .. i + 7];
        var ok = true;
        for (cand[1..]) |c| ok = ok and isHexDigit(c);
        if (!ok) continue;
        // `\b` after the 6 digits: the next char must not be a word char.
        if (i + 7 < svg.len and isWordChar(svg[i + 7])) continue;
        if (cmap.lookup(cand)) |to| @memcpy(out[i .. i + 7], &to);
        i += 6;
    }
}

// ---- themes -------------------------------------------------------------------------

pub const Themes = struct {
    /// token name -> placeholder (upper-case).
    tokens: std.StringArrayHashMapUnmanaged(Hex) = .empty,
    fur_tokens: std.ArrayList([]const u8) = .empty,
    /// vibe -> (token -> real colour).
    vibes: [3]std.StringArrayHashMapUnmanaged(Hex) = @splat(.empty),

    pub fn parse(arena: Allocator, json: []const u8) !Themes {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
        var t: Themes = .{};
        const ph = v.object.get("placeholders") orelse return error.BadThemes;
        var it = ph.object.iterator();
        while (it.next()) |e| if (e.value_ptr.* == .string) {
            if (parseHex(e.value_ptr.string)) |h| try t.tokens.put(arena, e.key_ptr.*, h);
        };
        if (v.object.get("fur_tokens")) |ft| for (ft.array.items) |x| if (x == .string) try t.fur_tokens.append(arena, x.string);
        const themes = v.object.get("themes") orelse return error.BadThemes;
        for (std.meta.tags(Vibe), 0..) |vibe, i| {
            if (themes.object.get(@tagName(vibe))) |tv| {
                var ti = tv.object.iterator();
                while (ti.next()) |e| if (e.value_ptr.* == .string) {
                    if (parseHex(e.value_ptr.string)) |h| try t.vibes[i].put(arena, e.key_ptr.*, h);
                };
            }
        }
        return t;
    }

    fn isFur(t: *const Themes, token: []const u8) bool {
        for (t.fur_tokens.items) |f| if (std.mem.eql(u8, f, token)) return true;
        return false;
    }

    /// render_art.py `color_map(theme, fur)`: gear from the vibe, fur from the animal.
    pub fn colorMap(t: *const Themes, vibe: Vibe, fur: *const std.StringArrayHashMapUnmanaged(Hex)) ColorMap {
        var m: ColorMap = .{};
        var it = t.vibes[@intFromEnum(vibe)].iterator();
        while (it.next()) |e| if (t.tokens.get(e.key_ptr.*)) |ph| m.put(ph, e.value_ptr.*);
        var fi = fur.iterator();
        while (fi.next()) |e| if (t.isFur(e.key_ptr.*)) {
            if (t.tokens.get(e.key_ptr.*)) |ph| m.put(ph, e.value_ptr.*);
        };
        return m;
    }

    /// Real colour of a gear token in `vibe` (e.g. "keycap_legend").
    pub fn gear(t: *const Themes, vibe: Vibe, token: []const u8) ?Hex {
        return t.vibes[@intFromEnum(vibe)].get(token);
    }
};

// ---- layers -------------------------------------------------------------------------

pub const max_layers = 16;

/// A layer name as render_art.py spells it ("acc/keyboard", "idle_paws", "LEGENDS").
pub const Name = struct {
    buf: [40]u8 = undefined,
    len: u8 = 0,

    pub fn init(parts: []const []const u8) Name {
        var n: Name = .{};
        for (parts) |p| {
            const k = @min(p.len, n.buf.len - n.len);
            @memcpy(n.buf[n.len..][0..k], p[0..k]);
            n.len += @intCast(k);
        }
        return n;
    }
    pub fn slice(n: *const Name) []const u8 {
        return n.buf[0..n.len];
    }
};

/// Which part of the scene a layer belongs to (the app moves `body` layers when it bobs).
pub const Group = enum { decor, body, gear, held, paws, overlay };

pub const Layer = struct {
    name: Name,
    kind: enum { svg, legends } = .svg,
    /// Resolved embedded asset ("art/_shared/keyboard.svg"); empty for legends.
    path: []const u8 = "",
    /// Placement for shared layers (anchors.json); identity otherwise.
    transform: Affine = .identity,
    group: Group,
};

pub const Stack = struct {
    layers: [max_layers]Layer = undefined,
    len: usize = 0,
    /// Names that resolved to no file (missing art is skipped, like render_art.py).
    missing: [max_layers]Name = undefined,
    missing_len: usize = 0,

    pub fn items(s: *const Stack) []const Layer {
        return s.layers[0..s.len];
    }
    fn push(s: *Stack, l: Layer) void {
        if (s.len < max_layers) {
            s.layers[s.len] = l;
            s.len += 1;
        }
    }
};

const desk_names = [_][]const u8{ "desk_lamp", "desk_plant", "desk_mug" };
const head_names = [_][]const u8{ "", "headphones", "beanie", "party_hat", "bow", "glasses", "yuzu" };
const held_names = [_][]const u8{ "", "coffee", "boba", "book" };

pub const Animal = struct {
    name: []const u8,
    anchors: Anchors = .{},
    fur: std.StringArrayHashMapUnmanaged(Hex) = .empty,

    pub fn load(arena: Allocator, name: []const u8) !Animal {
        var a: Animal = .{ .name = name };
        var buf: [96]u8 = undefined;
        if (assets.get(try std.fmt.bufPrint(&buf, "art/{s}/anchors.json", .{name}))) |j| {
            a.anchors = std.json.parseFromSliceLeaky(Anchors, arena, j, .{ .ignore_unknown_fields = true }) catch |e| blk: {
                std.log.warn("{s}: bad anchors.json ({t}); using defaults", .{ name, e });
                break :blk .{};
            };
        }
        if (assets.get(try std.fmt.bufPrint(&buf, "art/{s}/palette.json", .{name}))) |j| {
            const v = std.json.parseFromSliceLeaky(std.json.Value, arena, j, .{}) catch null;
            if (v) |val| if (val == .object) {
                var it = val.object.iterator();
                while (it.next()) |e| if (e.value_ptr.* == .string) {
                    if (parseHex(e.value_ptr.string)) |h| try a.fur.put(arena, e.key_ptr.*, h);
                };
            };
        }
        return a;
    }

    /// Embedded path of a layer (render_art.py `find`): the animal's own file, else (for
    /// acc/ layers) the shared one; `peek_paws` / `wake_paws` fall back to idle / sleep.
    pub fn find(a: *const Animal, buf: []u8, rel: []const u8) ?[]const u8 {
        const own = std.fmt.bufPrint(buf, "art/{s}/{s}.svg", .{ a.name, rel }) catch return null;
        if (assets.entry(own)) |e| return e.path;
        if (std.mem.startsWith(u8, rel, "acc/")) {
            const shared = std.fmt.bufPrint(buf, "art/_shared/{s}.svg", .{rel[4..]}) catch return null;
            if (assets.entry(shared)) |e| return e.path;
        }
        if (std.mem.endsWith(u8, rel, "_paws")) {
            const base = rel[0 .. rel.len - "_paws".len];
            const fallback: ?[]const u8 = if (std.mem.eql(u8, base, "peek")) "idle_paws" else if (std.mem.eql(u8, base, "wake")) "sleep_paws" else null;
            if (fallback) |f| return a.find(buf, f);
        }
        return null;
    }

    pub fn hasHeadItem(a: *const Animal, item: HeadItem) bool {
        if (item == .none) return true;
        var buf: [96]u8 = undefined;
        var nb: [40]u8 = undefined;
        const rel = std.fmt.bufPrint(&nb, "acc/{s}", .{head_names[@intFromEnum(item)]}) catch return false;
        return a.find(&buf, rel) != null;
    }

    pub fn hasFrame(a: *const Animal, f: Frame) bool {
        var buf: [96]u8 = undefined;
        return a.find(&buf, @tagName(f)) != null;
    }

    /// The layer stack for `frame` (render_art.py `layers` + `stack`), in draw order.
    pub fn layers(a: *const Animal, frame: Frame, o: Outfit) Stack {
        var names: [max_layers]struct { n: Name, g: Group } = undefined;
        var nn: usize = 0;
        const add = struct {
            fn f(list: anytype, count: *usize, n: Name, g: Group) void {
                if (count.* < list.len) {
                    list[count.*] = .{ .n = n, .g = g };
                    count.* += 1;
                }
            }
        }.f;
        if (o.sparkles) add(&names, &nn, Name.init(&.{"acc/sparkles"}), .decor);
        const desk = [_]bool{ o.desk.lamp, o.desk.plant, o.desk.mug };
        for (desk_names, desk) |d, on| if (on) add(&names, &nn, Name.init(&.{ "acc/", d }), .decor);
        add(&names, &nn, Name.init(&.{@tagName(frame)}), .body);
        if (o.head != .none) {
            const h = head_names[@intFromEnum(o.head)];
            add(&names, &nn, if (frame.isSleepy()) Name.init(&.{ "acc/", h, "_sleep" }) else Name.init(&.{ "acc/", h }), .body);
        }
        if (o.keyboard) add(&names, &nn, Name.init(&.{"acc/keyboard"}), .gear);
        if (o.held != .none and (frame == .hold or frame == .sip)) {
            const item = held_names[@intFromEnum(o.held)];
            const sip = Name.init(&.{ "acc/sip_", item });
            var buf: [96]u8 = undefined;
            const use_sip = frame == .sip and a.find(&buf, sip.slice()) != null;
            add(&names, &nn, if (use_sip) sip else Name.init(&.{ "acc/hold_", item }), .held);
        }
        add(&names, &nn, Name.init(&.{ @tagName(frame), "_paws" }), .paws);
        if (o.head == .headphones and frame.isTyping()) add(&names, &nn, Name.init(&.{"acc/music_notes"}), .overlay);
        if (frame == .excited) add(&names, &nn, Name.init(&.{"acc/motion"}), .overlay);
        if (frame == .sleep) add(&names, &nn, Name.init(&.{"acc/zzz"}), .overlay);

        var s: Stack = .{};
        for (names[0..nn]) |entry| {
            var buf: [96]u8 = undefined;
            const path = a.find(&buf, entry.n.slice()) orelse {
                if (s.missing_len < max_layers) {
                    s.missing[s.missing_len] = entry.n;
                    s.missing_len += 1;
                }
                continue;
            };
            const shared = std.mem.startsWith(u8, path, "art/_shared/");
            s.push(.{ .name = entry.n, .path = path, .transform = a.transformFor(entry.n.slice(), shared), .group = entry.g });
            if (shared and std.mem.eql(u8, entry.n.slice(), "acc/keyboard"))
                s.push(.{ .name = Name.init(&.{"LEGENDS"}), .kind = .legends, .transform = Affine.keyboard(a.anchors.keyboard), .group = .gear });
        }
        return s;
    }

    /// render_art.py `transform_for`: anchors.json placement of shared layers.
    pub fn transformFor(a: *const Animal, name: []const u8, shared: bool) Affine {
        if (!shared) return .identity;
        const base = if (std.mem.startsWith(u8, name, "acc/")) name[4..] else name;
        const is_desk = for (desk_names) |d| {
            if (std.mem.eql(u8, base, d)) break true;
        } else false;
        if (std.mem.eql(u8, base, "keyboard") or is_desk) return Affine.keyboard(a.anchors.keyboard);
        const o = a.anchors.overlays;
        const off: ?[2]f32 = if (std.mem.eql(u8, base, "music_notes")) o.music_notes else if (std.mem.eql(u8, base, "zzz")) o.zzz else if (std.mem.eql(u8, base, "motion")) o.motion else null;
        if (off) |v| return Affine.translate(v[0], v[1]);
        return .identity;
    }
};

/// Wrap a whole SVG layer in `<g transform="matrix(...)">` (render_art.py `wrap`).
/// Returns null when the document has no `<svg ...>` element.
pub fn wrapTransform(gpa: Allocator, svg: []const u8, m: Affine) !?[]u8 {
    const open = std.mem.indexOf(u8, svg, "<svg") orelse return null;
    const gt = std.mem.indexOfScalarPos(u8, svg, open, '>') orelse return null;
    const end = std.mem.lastIndexOf(u8, svg, "</svg>") orelse return null;
    if (end < gt) return null;
    return try std.fmt.allocPrint(gpa, "{s}<g transform=\"matrix({d} {d} {d} {d} {d} {d})\">{s}</g>{s}", .{
        svg[0 .. gt + 1], m.a, m.b, m.c, m.d, m.e, m.f, svg[gt + 1 .. end], svg[end..],
    });
}

// ---- catalog --------------------------------------------------------------------------

pub const max_animals = 16;

/// Every embedded animal plus the shared themes, parsed once at startup.
pub const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    themes: Themes,
    animals: [max_animals]Animal = undefined,
    count: usize = 0,

    pub fn init(gpa: Allocator) !*Catalog {
        const c = try gpa.create(Catalog);
        errdefer gpa.destroy(c);
        c.* = .{ .arena = .init(gpa), .themes = .{} };
        errdefer c.arena.deinit();
        const arena = c.arena.allocator();
        c.themes = try Themes.parse(arena, assets.get("art/_shared/themes.json") orelse return error.MissingThemes);
        var names: [max_animals][]const u8 = undefined;
        const n = assets.animals(&names);
        for (names[0..n]) |name| {
            c.animals[c.count] = try Animal.load(arena, name);
            c.count += 1;
        }
        if (c.count == 0) return error.NoAnimals;
        return c;
    }

    pub fn deinit(c: *Catalog, gpa: Allocator) void {
        c.arena.deinit();
        gpa.destroy(c);
    }

    pub fn list(c: *const Catalog) []const Animal {
        return c.animals[0..c.count];
    }

    pub fn indexOf(c: *const Catalog, name: []const u8) ?usize {
        for (c.list(), 0..) |a, i| if (std.mem.eql(u8, a.name, name)) return i;
        return null;
    }

    pub fn colorMap(c: *const Catalog, animal: usize, vibe: Vibe) ColorMap {
        return c.themes.colorMap(vibe, &c.animals[animal].fur);
    }
};

// ---- tests ----------------------------------------------------------------------------

const testing = std.testing;

fn expectNames(s: Stack, want: []const []const u8) !void {
    if (s.len != want.len) {
        std.debug.print("got:", .{});
        for (s.items()) |l| std.debug.print(" {s}", .{l.name.slice()});
        std.debug.print("\nwant:", .{});
        for (want) |w| std.debug.print(" {s}", .{w});
        std.debug.print("\n", .{});
        return error.TestExpectedEqual;
    }
    for (s.items(), want) |l, w| try testing.expectEqualStrings(w, l.name.slice());
}

test "recolor is single pass, case-insensitive and respects word boundaries" {
    var m: ColorMap = .{};
    m.put(parseHex("#22252C").?, parseHex("#8A8A94").?);
    m.put(parseHex("#8A8A94").?, parseHex("#000000").?); // must not chain
    const src = "fill=\"#22252c\" stroke=\"#22252C1\" x=\"#8a8a94\"";
    var out: [src.len]u8 = undefined;
    recolorInto(&out, src, &m);
    try testing.expectEqualStrings("fill=\"#8A8A94\" stroke=\"#22252C1\" x=\"#000000\"", &out);
}

test "layer stacks match scripts/render_art.py" {
    const gpa = testing.allocator;
    const cat = try Catalog.init(gpa);
    defer cat.deinit(gpa);
    const c = &cat.animals[cat.indexOf("cat").?];
    // render_art.py: a.layers("type_left", head="headphones") with the shared keyboard.
    try expectNames(c.layers(.type_left, .{ .head = .headphones }), &.{ "type_left", "acc/headphones", "acc/keyboard", "LEGENDS", "type_left_paws", "acc/music_notes" });
    try expectNames(c.layers(.sleep, .{ .head = .beanie }), &.{ "sleep", "acc/beanie_sleep", "acc/keyboard", "LEGENDS", "sleep_paws", "acc/zzz" });
    try expectNames(c.layers(.sip, .{ .held = .coffee }), &.{ "sip", "acc/keyboard", "LEGENDS", "acc/sip_coffee", "sip_paws" });
    try expectNames(c.layers(.hold, .{ .held = .boba }), &.{ "hold", "acc/keyboard", "LEGENDS", "acc/hold_boba", "hold_paws" });
    try expectNames(c.layers(.type_both, .{ .desk = .{ .lamp = true, .plant = true, .mug = true }, .sparkles = true }), &.{ "acc/sparkles", "acc/desk_lamp", "acc/desk_plant", "acc/desk_mug", "type_both", "acc/keyboard", "LEGENDS", "type_both_paws" });
    try expectNames(c.layers(.excited, .{}), &.{ "excited", "acc/keyboard", "LEGENDS", "excited_paws", "acc/motion" });
    try expectNames(c.layers(.idle, .{ .keyboard = false }), &.{ "idle", "idle_paws" });
    // peek has no paws of its own: render_art.py resolves `peek_paws` to idle_paws.
    const peek = c.layers(.peek, .{});
    try expectNames(peek, &.{ "peek", "acc/keyboard", "LEGENDS", "peek_paws" });
    try testing.expectEqualStrings("art/cat/idle_paws.svg", peek.layers[3].path);
    // shared layers come from _shared, own acc/ copies win.
    const hp = c.layers(.idle, .{ .head = .headphones });
    try testing.expectEqualStrings("art/cat/acc/headphones.svg", hp.layers[1].path);
    try testing.expectEqualStrings("art/_shared/keyboard.svg", hp.layers[2].path);
    // A head item the animal lacks is reported missing, not drawn.
    const y = c.layers(.idle, .{ .head = .yuzu });
    try testing.expectEqual(@as(usize, 1), y.missing_len);
    try testing.expectEqualStrings("acc/yuzu", y.missing[0].slice());
}

test "anchors drive shared-layer placement (render_art.py transform_for)" {
    const gpa = testing.allocator;
    const cat = try Catalog.init(gpa);
    defer cat.deinit(gpa);
    const cap = &cat.animals[cat.indexOf("capybara").?];
    // capybara: translate(6 4) scale(0.94) about (30,200); its desk_lamp is its own copy.
    const s = cap.layers(.type_left, .{ .desk = .{ .lamp = true, .mug = true }, .head = .headphones });
    var saw_kb = false;
    for (s.items()) |l| {
        if (std.mem.eql(u8, l.name.slice(), "acc/keyboard")) {
            saw_kb = true;
            const p = l.transform.apply(30, 200);
            try testing.expectApproxEqAbs(@as(f32, 36), p[0], 1e-4);
            try testing.expectApproxEqAbs(@as(f32, 204), p[1], 1e-4);
            const q = l.transform.apply(130, 100);
            try testing.expectApproxEqAbs(@as(f32, 30 + 100 * 0.94 + 6), q[0], 1e-3);
            try testing.expectApproxEqAbs(@as(f32, 200 - 100 * 0.94 + 4), q[1], 1e-3);
        }
        if (std.mem.eql(u8, l.name.slice(), "acc/desk_lamp")) try testing.expect(l.transform.isIdentity()); // own copy
        if (std.mem.eql(u8, l.name.slice(), "acc/desk_mug")) try testing.expect(!l.transform.isIdentity()); // shared
        if (std.mem.eql(u8, l.name.slice(), "acc/music_notes")) {
            try testing.expectEqual(@as(f32, 4), l.transform.e);
            try testing.expectEqual(@as(f32, 0), l.transform.f);
        }
    }
    try testing.expect(saw_kb);
}

test "colour maps: gear by vibe, fur by animal" {
    const gpa = testing.allocator;
    const cat = try Catalog.init(gpa);
    defer cat.deinit(gpa);
    const ci = cat.indexOf("cat").?;
    const m = cat.colorMap(ci, .bright);
    try testing.expectEqualStrings("#FFFFFF", &m.lookup("#454B59").?); // keycap
    try testing.expectEqualStrings("#F4A257", &m.lookup("#b07a4a").?); // fur_main (cat)
    const d = cat.colorMap(ci, .dark);
    try testing.expectEqualStrings("#454B59", &d.lookup("#454B59").?);
    try testing.expectEqualStrings("#B25E7A", &cat.themes.gear(.pink, "keycap_legend").?);
}
