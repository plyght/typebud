//! Typing sounds (sounds/FORMAT.md): sound-pack loading and validation, the normative
//! sample choice (pool fallback, never the same variant twice in a row, pitch / gain
//! jitter), and playback through zpui.audio with -3 dB master headroom.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const zpui = @import("zpui");
const assets = @import("assets.zig");

const audio_mod = zpui.audio;

pub const Pool = enum {
    generic,
    letter,
    digit,
    space,
    enter,
    backspace,
    tab,
    modifier,
    arrow,
    other,

    pub fn fromName(s: []const u8) ?Pool {
        return std.meta.stringToEnum(Pool, s);
    }
};
pub const pool_count = @typeInfo(Pool).@"enum".field_names.len;

pub const Dir = enum { down, up };

/// GlobalKeyClass → pool (same names).
pub fn poolForClass(class: anytype) Pool {
    return Pool.fromName(@tagName(class)) orelse .other;
}

/// Pack metadata (strings owned by the library arena).
pub const Info = struct {
    id: []const u8,
    name: []const u8,
    author: []const u8,
    license: []const u8,
    attribution: []const u8 = "",
    description: []const u8 = "",
    switch_type: []const u8 = "unknown",
    pitch_jitter_cents: f32 = 0,
    gain_jitter_db: f32 = 0,
    /// Paths per direction and pool (relative to the pack folder).
    files: [2][pool_count][]const []const u8 = @splat(@splat(&.{})),
    /// Where the files live: embedded ("sounds/packs/<id>/") or a user folder (absolute).
    location: union(enum) { embedded: []const u8, folder: []const u8 },
    has_up: bool = false,
};

pub const ValidationError = error{
    NotJson,
    BadFormat,
    BadVersion,
    BadId,
    MissingField,
    NoGenericDown,
    UnsafePath,
    MissingFile,
    BadWav,
    TooManyFiles,
    OutOfMemory,
};

/// Parse and validate a pack.json (FORMAT.md §3–5). `folder_name` must equal the id;
/// `read` fetches a pack-relative file (for the WAV checks) or returns null.
pub fn parsePack(arena: Allocator, json: []const u8, folder_name: []const u8, location: @FieldType(Info, "location"), reader: anytype) ValidationError!Info {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch return error.NotJson;
    if (v != .object) return error.NotJson;
    const o = v.object;
    const str = struct {
        fn get(obj: std.json.ObjectMap, k: []const u8) ?[]const u8 {
            const x = obj.get(k) orelse return null;
            return if (x == .string) x.string else null;
        }
        fn num(obj: std.json.ObjectMap, k: []const u8) ?f32 {
            const x = obj.get(k) orelse return null;
            return switch (x) {
                .integer => |i| @floatFromInt(i),
                .float => |f| @floatCast(f),
                else => null,
            };
        }
    };
    const format = str.get(o, "format") orelse return error.BadFormat;
    if (!std.mem.eql(u8, format, "typebud.soundpack")) return error.BadFormat;
    const ver = o.get("format_version") orelse return error.BadVersion;
    if (ver != .integer or ver.integer != 1) return error.BadVersion;
    const id = str.get(o, "id") orelse return error.MissingField;
    if (!validId(id) or !std.mem.eql(u8, id, folder_name)) return error.BadId;
    var info: Info = .{
        .id = id,
        .name = str.get(o, "name") orelse return error.MissingField,
        .author = str.get(o, "author") orelse return error.MissingField,
        .license = str.get(o, "license") orelse return error.MissingField,
        .attribution = str.get(o, "attribution") orelse "",
        .description = str.get(o, "description") orelse "",
        .switch_type = str.get(o, "switch_type") orelse "unknown",
        .location = location,
    };
    if (o.get("playback")) |pb| if (pb == .object) {
        info.pitch_jitter_cents = @max(str.num(pb.object, "pitch_jitter_cents") orelse 0, 0);
        info.gain_jitter_db = @max(str.num(pb.object, "gain_jitter_db") orelse 0, 0);
    };
    const sounds = o.get("sounds") orelse return error.MissingField;
    if (sounds != .object) return error.MissingField;
    for ([_]Dir{ .down, .up }) |d| {
        const dv = sounds.object.get(@tagName(d)) orelse {
            if (d == .down) return error.MissingField;
            continue;
        };
        if (dv != .object) return error.MissingField;
        var it = dv.object.iterator();
        while (it.next()) |e| {
            const pool = Pool.fromName(e.key_ptr.*) orelse {
                std.log.info("sound pack {s}: ignoring unknown pool '{s}'", .{ id, e.key_ptr.* });
                continue;
            };
            if (e.value_ptr.* != .array) return error.MissingField;
            const items = e.value_ptr.array.items;
            if (items.len > 32) return error.TooManyFiles;
            const paths = try arena.alloc([]const u8, items.len);
            for (items, paths) |item, *p| {
                if (item != .string) return error.MissingField;
                if (!safePath(item.string)) return error.UnsafePath;
                const bytes = reader.read(item.string) orelse return error.MissingFile;
                checkWav(bytes) catch return error.BadWav;
                p.* = item.string;
            }
            info.files[@intFromEnum(d)][@intFromEnum(pool)] = paths;
            if (d == .up and paths.len > 0) info.has_up = true;
        }
    }
    if (info.files[0][@intFromEnum(Pool.generic)].len == 0) return error.NoGenericDown;
    return info;
}

pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id, 0..) |c, i| {
        const ok = std.ascii.isLower(c) or std.ascii.isDigit(c) or (c == '-' and i > 0);
        if (!ok) return false;
    }
    return true;
}

/// Pack-relative, `/`-separated, no `..`, no absolute paths, no backslashes.
pub fn safePath(p: []const u8) bool {
    if (p.len == 0 or p[0] == '/' or std.mem.indexOfScalar(u8, p, '\\') != null) return false;
    if (p.len >= 2 and p[1] == ':') return false;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |seg| if (std.mem.eql(u8, seg, "..") or seg.len == 0) return false;
    return true;
}

/// FORMAT.md §2: PCM 16-bit mono 48 kHz with a non-empty data chunk (others skipped).
pub fn checkWav(b: []const u8) !void {
    if (b.len < 12 or !std.mem.eql(u8, b[0..4], "RIFF") or !std.mem.eql(u8, b[8..12], "WAVE")) return error.BadWav;
    var pos: usize = 12;
    var fmt_ok = false;
    var data_ok = false;
    while (pos + 8 <= b.len) {
        const id = b[pos..][0..4];
        const size = std.mem.readInt(u32, b[pos + 4 ..][0..4], .little);
        const body = pos + 8;
        if (body + size > b.len) return error.BadWav;
        if (std.mem.eql(u8, id, "fmt ")) {
            if (size < 16) return error.BadWav;
            const tag = std.mem.readInt(u16, b[body..][0..2], .little);
            const ch = std.mem.readInt(u16, b[body + 2 ..][0..2], .little);
            const rate = std.mem.readInt(u32, b[body + 4 ..][0..4], .little);
            const bits = std.mem.readInt(u16, b[body + 14 ..][0..2], .little);
            fmt_ok = tag == 1 and ch == 1 and rate == 48000 and bits == 16;
        } else if (std.mem.eql(u8, id, "data")) {
            data_ok = size > 0;
        }
        pos = body + size + (size & 1);
    }
    if (!fmt_ok or !data_ok) return error.BadWav;
}

/// The pool for (dir, class) per FORMAT.md §4 step 1, or null (play nothing).
pub fn resolve(info: *const Info, d: Dir, pool: Pool) ?Pool {
    const lists = &info.files[@intFromEnum(d)];
    if (lists[@intFromEnum(pool)].len > 0) return pool;
    if (lists[@intFromEnum(Pool.generic)].len > 0) return .generic;
    return null;
}

/// Uniform pick of `n` entries that is never `last` when n > 1 (§4 step 2).
pub fn choose(r: std.Random, n: usize, last: ?usize) usize {
    if (n <= 1) return 0;
    if (last) |l| if (l < n) {
        const k = r.uintLessThan(usize, n - 1);
        return if (k >= l) k + 1 else k;
    };
    return r.uintLessThan(usize, n);
}

pub const Library = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    packs: std.ArrayList(Info) = .empty,

    pub fn init(gpa: Allocator) Library {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }
    pub fn deinit(l: *Library) void {
        l.packs.deinit(l.gpa);
        l.arena.deinit();
    }

    const EmbeddedReader = struct {
        prefix: []const u8,
        pub fn read(r: EmbeddedReader, rel: []const u8) ?[]const u8 {
            var buf: [256]u8 = undefined;
            const p = std.fmt.bufPrint(&buf, "{s}{s}", .{ r.prefix, rel }) catch return null;
            return assets.get(p);
        }
    };

    /// Bundled packs, in index.json order.
    pub fn loadBundled(l: *Library) void {
        const index = assets.get("sounds/packs/index.json") orelse return;
        const arena = l.arena.allocator();
        const Index = struct { packs: []const struct { id: []const u8 } };
        const parsed = std.json.parseFromSliceLeaky(Index, arena, index, .{ .ignore_unknown_fields = true }) catch return;
        for (parsed.packs) |p| {
            const prefix = std.fmt.allocPrint(arena, "sounds/packs/{s}/", .{p.id}) catch continue;
            const pj_path = std.fmt.allocPrint(arena, "{s}pack.json", .{prefix}) catch continue;
            const pj = assets.get(pj_path) orelse continue;
            const info = parsePack(arena, pj, p.id, .{ .embedded = prefix }, EmbeddedReader{ .prefix = prefix }) catch |e| {
                std.log.warn("bundled sound pack {s} rejected: {t}", .{ p.id, e });
                continue;
            };
            l.packs.append(l.gpa, info) catch {};
        }
    }

    const FolderReader = struct {
        io: Io,
        dir: Io.Dir,
        arena: Allocator,
        pub fn read(r: FolderReader, rel: []const u8) ?[]const u8 {
            return r.dir.readFileAlloc(r.io, rel, r.arena, .limited(8 << 20)) catch null;
        }
    };

    /// User packs: every `<root>/<id>/pack.json` (imported packs live here).
    pub fn loadFolder(l: *Library, io: Io, root: []const u8) void {
        var d = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
        defer d.close(io);
        var it = d.iterate();
        while (it.next(io) catch null) |e| {
            if (e.kind != .directory) continue;
            _ = l.loadUserPack(io, root, e.name) catch |err| std.log.warn("sound pack {s}/{s} rejected: {t}", .{ root, e.name, err });
        }
    }

    pub fn loadUserPack(l: *Library, io: Io, root: []const u8, name: []const u8) !*const Info {
        const arena = l.arena.allocator();
        const folder = try std.fs.path.join(arena, &.{ root, name });
        var pd = try Io.Dir.cwd().openDir(io, folder, .{});
        defer pd.close(io);
        const pj = try pd.readFileAlloc(io, "pack.json", arena, .limited(1 << 20));
        // WAV bytes are only checked here; they are re-read when the pack is played.
        var scratch: std.heap.ArenaAllocator = .init(l.gpa);
        defer scratch.deinit();
        const info = try parsePack(arena, pj, name, .{ .folder = folder }, FolderReader{ .io = io, .dir = pd, .arena = scratch.allocator() });
        for (l.packs.items) |*p| if (std.mem.eql(u8, p.id, info.id)) {
            p.* = info;
            return p;
        };
        try l.packs.append(l.gpa, info);
        return &l.packs.items[l.packs.items.len - 1];
    }

    pub fn find(l: *const Library, id: []const u8) ?*const Info {
        for (l.packs.items) |*p| if (std.mem.eql(u8, p.id, id)) return p;
        return null;
    }

    pub fn indexOf(l: *const Library, id: []const u8) ?usize {
        for (l.packs.items, 0..) |p, i| if (std.mem.eql(u8, p.id, id)) return i;
        return null;
    }
};

/// A pack's samples loaded into the mixer.
const Loaded = struct {
    info: *const Info,
    ids: [2][pool_count][]audio_mod.SoundId,
};

pub const master_headroom: f32 = 0.7079; // -3 dB

/// One sample played (for re-rendering the exact track offline, e.g. the demo video).
pub const Played = struct {
    t_ns: u64,
    info: *const Info,
    d: Dir,
    pool: Pool,
    k: u32,
    gain: f32,
    pitch: f32,
};

pub const Recorder = struct {
    gpa: Allocator,
    events: std.ArrayList(Played) = .empty,
    clock: *const fn (?*anyopaque) u64,
    clock_ctx: ?*anyopaque = null,

    pub fn deinit(r: *Recorder) void {
        r.events.deinit(r.gpa);
    }

    /// Render the recorded plays from `start_ns` to `end_ns` through a null-backend mixer
    /// with the same samples, gains and timing; 16-bit stereo WAV at the mixer rate.
    pub fn renderWav(r: *const Recorder, io: Io, start_ns: u64, end_ns: u64, volume: f32) ![]u8 {
        const gpa = r.gpa;
        const a = try audio_mod.Audio.init(gpa, .{ .backend = .null });
        defer a.deinit();
        var p = Player.init(gpa, io, a);
        defer p.deinit();
        p.setVolume(volume);
        const rate: u64 = a.sampleRate();
        const total_frames: usize = @intCast((end_ns -| start_ns) * rate / std.time.ns_per_s + rate / 2);
        const out = try gpa.alloc(f32, total_frames * 2);
        defer gpa.free(out);
        @memset(out, 0);
        var pos: usize = 0;
        for (r.events.items) |e| {
            if (e.t_ns < start_ns) continue;
            const at: usize = @min(@as(usize, @intCast((e.t_ns - start_ns) * rate / std.time.ns_per_s)), total_frames);
            if (at > pos) {
                a.renderOffline(out[pos * 2 .. at * 2]);
                pos = at;
            }
            try p.select(e.info);
            const l = &p.loaded.items[p.current.?];
            const ids = l.ids[@intFromEnum(e.d)][@intFromEnum(e.pool)];
            if (e.k < ids.len) a.play(ids[e.k], .{ .gain = e.gain, .pitch = e.pitch });
        }
        if (pos < total_frames) a.renderOffline(out[pos * 2 ..]);
        return encodeWav16(gpa, out, @intCast(rate), 2);
    }
};

/// Interleaved f32 → 16-bit PCM WAV (clipped).
pub fn encodeWav16(gpa: Allocator, samples: []const f32, rate: u32, channels: u16) ![]u8 {
    const data_len: u32 = @intCast(samples.len * 2);
    const buf = try gpa.alloc(u8, 44 + data_len);
    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], 36 + data_len, .little);
    @memcpy(buf[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, buf[16..20], 16, .little);
    std.mem.writeInt(u16, buf[20..22], 1, .little);
    std.mem.writeInt(u16, buf[22..24], channels, .little);
    std.mem.writeInt(u32, buf[24..28], rate, .little);
    std.mem.writeInt(u32, buf[28..32], rate * channels * 2, .little);
    std.mem.writeInt(u16, buf[32..34], channels * 2, .little);
    std.mem.writeInt(u16, buf[34..36], 16, .little);
    @memcpy(buf[36..40], "data");
    std.mem.writeInt(u32, buf[40..44], data_len, .little);
    for (samples, 0..) |x, i| {
        const v: i16 = @intFromFloat(std.math.clamp(x, -1, 1) * 32767);
        std.mem.writeInt(i16, buf[44 + i * 2 ..][0..2], v, .little);
    }
    return buf;
}

pub const Player = struct {
    gpa: Allocator,
    io: Io,
    audio: ?*audio_mod.Audio = null,
    arena: std.heap.ArenaAllocator,
    loaded: std.ArrayList(Loaded) = .empty,
    current: ?usize = null,
    last: [2][pool_count]?usize = @splat(@splat(null)),
    rng: std.Random.DefaultPrng = .init(0x50d),
    volume: f32 = 0.6,
    recorder: ?*Recorder = null,

    pub fn init(gpa: Allocator, io: Io, a: ?*audio_mod.Audio) Player {
        var p: Player = .{ .gpa = gpa, .io = io, .audio = a, .arena = .init(gpa) };
        p.setVolume(0.6);
        return p;
    }
    pub fn deinit(p: *Player) void {
        p.loaded.deinit(p.gpa);
        p.arena.deinit();
    }

    pub fn setVolume(p: *Player, v: f32) void {
        p.volume = std.math.clamp(v, 0, 1);
        if (p.audio) |a| a.setMasterVolume(p.volume * master_headroom);
    }

    /// Load (once) and select `info` for playback.
    pub fn select(p: *Player, info: *const Info) !void {
        for (p.loaded.items, 0..) |l, i| if (l.info == info) {
            if (p.current != i) p.last = @splat(@splat(null));
            p.current = i;
            return;
        };
        const a = p.audio orelse return;
        var l: Loaded = .{ .info = info, .ids = @splat(@splat(&.{})) };
        const arena = p.arena.allocator();
        for (0..2) |d| for (0..pool_count) |pi| {
            const files = info.files[d][pi];
            if (files.len == 0) continue;
            const ids = try arena.alloc(audio_mod.SoundId, files.len);
            for (files, ids) |f, *id| {
                const bytes = try p.readFile(info, f);
                defer if (info.location == .folder) p.gpa.free(bytes);
                id.* = try a.loadWav(bytes);
            }
            l.ids[d][pi] = ids;
        };
        try p.loaded.append(p.gpa, l);
        p.current = p.loaded.items.len - 1;
        p.last = @splat(@splat(null));
    }

    fn readFile(p: *Player, info: *const Info, rel: []const u8) ![]const u8 {
        switch (info.location) {
            .embedded => |prefix| {
                var buf: [256]u8 = undefined;
                return assets.get(try std.fmt.bufPrint(&buf, "{s}{s}", .{ prefix, rel })) orelse error.MissingFile;
            },
            .folder => |folder| {
                var d = try Io.Dir.cwd().openDir(p.io, folder, .{});
                defer d.close(p.io);
                return d.readFileAlloc(p.io, rel, p.gpa, .limited(8 << 20));
            },
        }
    }

    /// Play a key sound for (dir, pool) from the selected pack.
    pub fn play(p: *Player, d: Dir, pool: Pool) void {
        const a = p.audio orelse return;
        const ci = p.current orelse return;
        const l = &p.loaded.items[ci];
        const rp = resolve(l.info, d, pool) orelse return;
        const ids = l.ids[@intFromEnum(d)][@intFromEnum(rp)];
        if (ids.len == 0) return;
        const r = p.rng.random();
        const last = &p.last[@intFromEnum(d)][@intFromEnum(rp)];
        const k = choose(r, ids.len, last.*);
        last.* = k;
        const cents = (r.float(f32) * 2 - 1) * l.info.pitch_jitter_cents;
        const db = (r.float(f32) * 2 - 1) * l.info.gain_jitter_db;
        const gain = std.math.pow(f32, 10, db / 20);
        const pitch = std.math.pow(f32, 2, cents / 1200);
        if (p.recorder) |rec| rec.events.append(rec.gpa, .{ .t_ns = rec.clock(rec.clock_ctx), .info = l.info, .d = d, .pool = rp, .k = @intCast(k), .gain = gain, .pitch = pitch }) catch {};
        a.play(ids[k], .{ .gain = gain, .pitch = pitch });
    }
};

// ---- tests ------------------------------------------------------------------------------

const testing = std.testing;

test "every bundled pack validates" {
    var lib = Library.init(testing.allocator);
    defer lib.deinit();
    lib.loadBundled();
    try testing.expect(lib.packs.items.len >= 8);
    const cream = lib.find("nk-cream").?;
    try testing.expectEqual(@as(usize, 5), cream.files[0][@intFromEnum(Pool.generic)].len);
    try testing.expect(cream.has_up);
    try testing.expectEqual(@as(f32, 15), cream.pitch_jitter_cents);
    try testing.expect(cream.attribution.len > 0);
}

test "pool resolution falls back to generic, never up -> down" {
    var lib = Library.init(testing.allocator);
    defer lib.deinit();
    lib.loadBundled();
    const pop = lib.find("bubble-pop").?;
    try testing.expectEqual(Pool.space, resolve(pop, .down, .space).?);
    try testing.expectEqual(Pool.generic, resolve(pop, .down, .letter).?);
    try testing.expectEqual(Pool.modifier, resolve(pop, .down, .modifier).?);
    try testing.expectEqual(Pool.generic, resolve(pop, .up, .enter).?); // bubble-pop has no enter-up
    var info = pop.*;
    info.files[1] = @splat(&.{});
    try testing.expectEqual(@as(?Pool, null), resolve(&info, .up, .space));
}

test "choose never repeats the last variant and covers every other one" {
    var prng = std.Random.DefaultPrng.init(42);
    const r = prng.random();
    var seen: [5]u32 = @splat(0);
    var last: ?usize = null;
    for (0..2000) |_| {
        const k = choose(r, 5, last);
        if (last) |l| try testing.expect(k != l);
        seen[k] += 1;
        last = k;
    }
    for (seen) |c| try testing.expect(c > 300);
    try testing.expectEqual(@as(usize, 0), choose(r, 1, 0));
}

test "pack validation rejects unsafe or broken packs" {
    const R = struct {
        pub fn read(_: @This(), _: []const u8) ?[]const u8 {
            return assets.get("sounds/packs/nk-cream/down/generic_01.wav");
        }
    };
    const arena_state = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(arena_state);
    defer arena.deinit();
    const a = arena.allocator();
    const loc: @FieldType(Info, "location") = .{ .folder = "/x" };
    const ok = "{\"format\":\"typebud.soundpack\",\"format_version\":1,\"id\":\"p\",\"name\":\"P\",\"author\":\"A\",\"license\":\"MIT\",\"sounds\":{\"down\":{\"generic\":[\"a.wav\"],\"weird\":[\"b.wav\"]}}}";
    _ = try parsePack(a, ok, "p", loc, R{});
    try testing.expectError(error.BadId, parsePack(a, ok, "q", loc, R{}));
    try testing.expectError(error.UnsafePath, parsePack(a, "{\"format\":\"typebud.soundpack\",\"format_version\":1,\"id\":\"p\",\"name\":\"P\",\"author\":\"A\",\"license\":\"MIT\",\"sounds\":{\"down\":{\"generic\":[\"../a.wav\"]}}}", "p", loc, R{}));
    try testing.expectError(error.BadVersion, parsePack(a, "{\"format\":\"typebud.soundpack\",\"format_version\":2,\"id\":\"p\",\"name\":\"P\",\"author\":\"A\",\"license\":\"MIT\",\"sounds\":{}}", "p", loc, R{}));
    try testing.expectError(error.NoGenericDown, parsePack(a, "{\"format\":\"typebud.soundpack\",\"format_version\":1,\"id\":\"p\",\"name\":\"P\",\"author\":\"A\",\"license\":\"MIT\",\"sounds\":{\"down\":{\"space\":[\"a.wav\"]}}}", "p", loc, R{}));
    try testing.expect(!safePath("C:/x.wav"));
    try testing.expect(!safePath("a\\b.wav"));
    try testing.expect(safePath("down/generic_01.wav"));
}

test "recorded plays re-render offline to a WAV" {
    var lib = Library.init(testing.allocator);
    defer lib.deinit();
    lib.loadBundled();
    const S = struct {
        var t: u64 = 0;
        fn now(_: ?*anyopaque) u64 {
            return t;
        }
    };
    var rec: Recorder = .{ .gpa = testing.allocator, .clock = S.now };
    defer rec.deinit();
    const a = try audio_mod.Audio.init(testing.allocator, .{ .backend = .null });
    defer a.deinit();
    var p = Player.init(testing.allocator, testing.io, a);
    defer p.deinit();
    p.recorder = &rec;
    try p.select(lib.find("holy-panda").?);
    for (0..10) |i| {
        S.t = 1_000_000_000 + i * 100_000_000;
        p.play(.down, .letter);
    }
    try testing.expectEqual(@as(usize, 10), rec.events.items.len);
    const wav = try rec.renderWav(testing.io, 1_000_000_000, 2_000_000_000, 0.6);
    defer testing.allocator.free(wav);
    try testing.expect(wav.len > 44 + 48000 * 4);
    var peak: i32 = 0;
    var i: usize = 44;
    while (i + 2 <= wav.len) : (i += 2) peak = @max(peak, @as(i32, @abs(std.mem.readInt(i16, wav[i..][0..2], .little))));
    try testing.expect(peak > 300);
}

test "player selects packs and plays through the null backend" {
    const a = try audio_mod.Audio.init(testing.allocator, .{ .backend = .null });
    defer a.deinit();
    var lib = Library.init(testing.allocator);
    defer lib.deinit();
    lib.loadBundled();
    var p = Player.init(testing.allocator, testing.io, a);
    defer p.deinit();
    try p.select(lib.find("topre").?);
    p.play(.down, .letter);
    p.play(.down, .space);
    p.play(.up, .letter);
    var buf: [4800 * 2]f32 = undefined;
    a.renderOffline(&buf);
    var peak: f32 = 0;
    for (buf) |x| peak = @max(peak, @abs(x));
    try testing.expect(peak > 0.01);
    try testing.expect(peak < 1.0);
}
