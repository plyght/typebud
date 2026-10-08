//! Import foreign keyboard sound packs into typebud's format (sounds/FORMAT.md §7): a
//! native port of scripts/sounds/import_pack.py's readers — Mechvibes v1/v2 (single sprite
//! or one file per key, `{a-b}` ranges, `-up` keys), MechvibesDX (W3C codes, timing pairs,
//! rejoined migration halves), Thock and the kbsim folder layout — with WAV, OGG Vorbis
//! (stb_vorbis) and MP3 (minimp3) decoding, mono downmix and resampling to 48 kHz.
//!
//! Processing is a lighter version of the Python chain: onset-aligned trim with a 1 ms
//! faded pre-roll, tail cut at the noise floor + 12 ms fade, per-class level smoothing,
//! one pack gain that matches the bundled packs' strike loudness, a -1 dBFS ceiling.
//! Every path from a foreign config is untrusted: it must stay inside the pack folder.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const zpui = @import("zpui");
const assets = @import("assets.zig");
const sound = @import("sound.zig");
/// third_party/decoders.c (stb_vorbis) and decoders_mp3.c (minimp3).
const c = struct {
    extern fn tb_decode_ogg(data: [*]const u8, len: c_int, channels: *c_int, rate: *c_int, out: *?[*]c_short) c_int;
    extern fn tb_decode_mp3(data: [*]const u8, len: c_int, channels: *c_int, rate: *c_int, out: *?[*]c_short) c_int;
    extern fn tb_decoder_free(p: ?*anyopaque) void;
};

const SR: u32 = 48000;
const max_generic = 8;
const max_special = 3;

pub const ImportError = error{
    NoConfig,
    UnknownFormat,
    UnsupportedFormat,
    PathEscapes,
    MissingAudio,
    BadAudio,
    NoKeyDownSounds,
    OutOfMemory,
};

/// User-facing text for an import failure.
pub fn describe(e: anyerror) []const u8 {
    return switch (e) {
        error.NoConfig => "no config.json (or press/ folder) in that folder",
        error.UnknownFormat => "config.json is not a Mechvibes, MechvibesDX or Thock pack",
        error.UnsupportedFormat => "this MechvibesDX pack must be opened in MechvibesDX once first",
        error.PathEscapes => "the pack refers to files outside its folder",
        error.MissingAudio => "a sound file the pack lists is missing",
        error.BadAudio => "a sound file could not be decoded (WAV, OGG and MP3 are supported)",
        error.NoKeyDownSounds => "the pack has no key sounds",
        else => @errorName(e),
    };
}

// ---- key classes (FORMAT.md §7.4) ------------------------------------------------------

pub fn iohookPool(code: u32) sound.Pool {
    const cls: sound.Pool = switch (code) {
        16...25, 30...38, 44...50 => .letter,
        2...11 => .digit,
        57 => .space,
        28, 3612 => .enter,
        14 => .backspace,
        15 => .tab,
        42, 54, 29, 3613, 56, 3640, 3675, 3676, 3677, 58 => .modifier,
        57416, 57419, 57421, 57424, 61000, 61003, 61005, 61008 => .arrow,
        else => .other,
    };
    return importPool(cls);
}

pub fn w3cPool(code: []const u8) sound.Pool {
    const m = std.mem;
    const cls: sound.Pool = blk: {
        if (code.len == 4 and m.startsWith(u8, code, "Key") and std.ascii.isUpper(code[3])) break :blk .letter;
        if (code.len == 6 and m.startsWith(u8, code, "Digit") and std.ascii.isDigit(code[5])) break :blk .digit;
        if (m.eql(u8, code, "Space")) break :blk .space;
        if (m.eql(u8, code, "Enter") or m.eql(u8, code, "NumpadEnter")) break :blk .enter;
        if (m.eql(u8, code, "Backspace")) break :blk .backspace;
        if (m.eql(u8, code, "Tab")) break :blk .tab;
        for ([_][]const u8{ "Shift", "Control", "Alt", "Meta", "OS" }) |p| if (m.startsWith(u8, code, p) and (m.endsWith(u8, code, "Left") or m.endsWith(u8, code, "Right")) and code.len == p.len + (if (m.endsWith(u8, code, "Left")) @as(usize, 4) else 5)) break :blk .modifier;
        if (m.eql(u8, code, "CapsLock") or m.eql(u8, code, "ContextMenu") or m.eql(u8, code, "Fn")) break :blk .modifier;
        if (m.startsWith(u8, code, "Arrow")) break :blk .arrow;
        break :blk .other;
    };
    return importPool(cls);
}

/// Letters, digits and other printable keys share the generic pool on import.
fn importPool(cls: sound.Pool) sound.Pool {
    return switch (cls) {
        .letter, .digit, .other => .generic,
        else => cls,
    };
}

// ---- spec ---------------------------------------------------------------------------------

const Source = struct {
    /// Absolute path of the audio file.
    path: []const u8,
    start_ms: ?f64 = null,
    end_ms: ?f64 = null,

    fn eql(a: Source, b: Source) bool {
        return std.mem.eql(u8, a.path, b.path) and std.meta.eql(a.start_ms, b.start_ms) and std.meta.eql(a.end_ms, b.end_ms);
    }
};

const Spec = struct {
    name: []const u8 = "",
    author: []const u8 = "",
    license: []const u8 = "",
    format: []const u8 = "",
    sounds: [2][sound.pool_count]std.ArrayList(Source) = @splat(@splat(.empty)),

    fn add(s: *Spec, arena: Allocator, d: sound.Dir, pool: sound.Pool, src: Source) !void {
        const list = &s.sounds[@intFromEnum(d)][@intFromEnum(pool)];
        for (list.items) |x| if (x.eql(src)) return;
        try list.append(arena, src);
    }
};

const Ctx = struct {
    arena: Allocator,
    io: Io,
    folder: []const u8,

    /// `rel` resolved inside the pack folder (case-insensitive fallback on the file name).
    fn resolve(x: Ctx, rel: []const u8) ![]const u8 {
        if (rel.len == 0 or std.fs.path.isAbsolute(rel) or rel[0] == '/' or rel[0] == '\\') return error.PathEscapes;
        var it = std.mem.tokenizeAny(u8, rel, "/\\");
        while (it.next()) |seg| if (std.mem.eql(u8, seg, "..")) return error.PathEscapes;
        const norm = try std.mem.replaceOwned(u8, x.arena, rel, "\\", "/");
        const full = try std.fs.path.join(x.arena, &.{ x.folder, norm });
        if (Io.Dir.cwd().access(x.io, full, .{})) |_| return full else |_| {}
        const dir_part = std.fs.path.dirname(full) orelse x.folder;
        const base = std.fs.path.basename(full);
        var d = Io.Dir.cwd().openDir(x.io, dir_part, .{ .iterate = true }) catch return error.MissingAudio;
        defer d.close(x.io);
        var di = d.iterate();
        while (di.next(x.io) catch null) |e| if (std.ascii.eqlIgnoreCase(e.name, base))
            return std.fs.path.join(x.arena, &.{ dir_part, e.name });
        return error.MissingAudio;
    }
};

fn expandRange(arena: Allocator, pattern: []const u8) ![]const []const u8 {
    const open = std.mem.indexOfScalar(u8, pattern, '{') orelse return arena.dupe([]const u8, &.{pattern});
    const close = std.mem.indexOfScalarPos(u8, pattern, open, '}') orelse return arena.dupe([]const u8, &.{pattern});
    const inner = pattern[open + 1 .. close];
    const dash = std.mem.indexOfScalar(u8, inner, '-') orelse return arena.dupe([]const u8, &.{pattern});
    const a = std.fmt.parseInt(u32, inner[0..dash], 10) catch return arena.dupe([]const u8, &.{pattern});
    const b = std.fmt.parseInt(u32, inner[dash + 1 ..], 10) catch return arena.dupe([]const u8, &.{pattern});
    if (b < a or b - a > 64) return error.UnknownFormat;
    var out: std.ArrayList([]const u8) = .empty;
    var i = a;
    while (i <= b) : (i += 1) try out.append(arena, try std.fmt.allocPrint(arena, "{s}{d}{s}", .{ pattern[0..open], i, pattern[close + 1 ..] }));
    return out.items;
}

fn str(o: std.json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return if (v == .string) v.string else null;
}

fn num(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn readMechvibes(x: Ctx, cfg: std.json.ObjectMap) !Spec {
    var spec: Spec = .{ .name = str(cfg, "name") orelse "", .format = "mechvibes" };
    const version: i64 = if (cfg.get("version")) |v| (if (v == .integer) v.integer else 1) else 1;
    const kind = str(cfg, "key_define_type") orelse "single";
    const defines = if (cfg.get("defines")) |d| (if (d == .object) d.object else return error.UnknownFormat) else return error.UnknownFormat;
    var it = defines.iterator();
    if (std.mem.eql(u8, kind, "single")) {
        const sprite = try x.resolve(str(cfg, "sound") orelse return error.UnknownFormat);
        while (it.next()) |e| {
            const v = e.value_ptr.*;
            if (v != .array or v.array.items.len < 2) continue;
            const up = std.mem.endsWith(u8, e.key_ptr.*, "-up");
            const code = std.fmt.parseInt(u32, if (up) e.key_ptr.*[0 .. e.key_ptr.len - 3] else e.key_ptr.*, 10) catch continue;
            const start = num(v.array.items[0]) orelse continue;
            const dur = num(v.array.items[1]) orelse continue;
            try spec.add(x.arena, if (up) .up else .down, iohookPool(code), .{ .path = sprite, .start_ms = start, .end_ms = start + dur });
        }
        return spec;
    }
    if (!std.mem.eql(u8, kind, "multi")) return error.UnknownFormat;
    while (it.next()) |e| {
        const v = e.value_ptr.*;
        if (v != .string or v.string.len == 0) continue;
        const up = std.mem.endsWith(u8, e.key_ptr.*, "-up");
        const code = std.fmt.parseInt(u32, if (up) e.key_ptr.*[0 .. e.key_ptr.len - 3] else e.key_ptr.*, 10) catch continue;
        for (try expandRange(x.arena, v.string)) |name|
            try spec.add(x.arena, if (up) .up else .down, iohookPool(code), .{ .path = try x.resolve(name) });
    }
    if (version >= 2) {
        for ([_]struct { d: sound.Dir, f: []const u8 }{ .{ .d = .down, .f = "sound" }, .{ .d = .up, .f = "soundup" } }) |p| {
            const pat = str(cfg, p.f) orelse continue;
            for (try expandRange(x.arena, pat)) |name| {
                const path = x.resolve(name) catch |err| switch (err) {
                    error.MissingAudio => continue,
                    else => return err,
                };
                try spec.add(x.arena, p.d, .generic, .{ .path = path });
            }
        }
    }
    return spec;
}

fn readMechvibesDx(x: Ctx, cfg: std.json.ObjectMap) !Spec {
    const defs_v = cfg.get("definitions") orelse cfg.get("defs") orelse return error.UnknownFormat;
    if (defs_v != .object) return error.UnknownFormat;
    const method = str(cfg, "definition_method") orelse "single";
    if (!std.mem.eql(u8, method, "single")) return error.UnsupportedFormat;
    const sprite = try x.resolve(str(cfg, "audio_file") orelse return error.UnsupportedFormat);
    var spec: Spec = .{ .name = str(cfg, "name") orelse "", .author = str(cfg, "author") orelse "", .format = "mechvibesdx" };
    var it = defs_v.object.iterator();
    while (it.next()) |e| {
        const code = e.key_ptr.*;
        if (std.mem.startsWith(u8, code, "Mouse") or std.mem.startsWith(u8, code, "Wheel") or std.mem.startsWith(u8, code, "Button")) continue;
        if (e.value_ptr.* != .object) continue;
        const t = e.value_ptr.object.get("timing") orelse continue;
        if (t != .array) continue;
        var pairs: [2][2]f64 = undefined;
        var n: usize = 0;
        for (t.array.items) |p| {
            if (n == 2) break;
            if (p != .array or p.array.items.len < 2) continue;
            pairs[n] = .{ num(p.array.items[0]) orelse continue, num(p.array.items[1]) orelse continue };
            n += 1;
        }
        const pool = w3cPool(code);
        if (n >= 2 and @abs(pairs[1][0] - pairs[0][1]) < 0.01) {
            // Migration artifact: one key-down cut in half (FORMAT.md §7.5).
            try spec.add(x.arena, .down, pool, .{ .path = sprite, .start_ms = pairs[0][0], .end_ms = pairs[1][1] });
            continue;
        }
        if (n >= 1) try spec.add(x.arena, .down, pool, .{ .path = sprite, .start_ms = pairs[0][0], .end_ms = pairs[0][1] });
        if (n >= 2) try spec.add(x.arena, .up, pool, .{ .path = sprite, .start_ms = pairs[1][0], .end_ms = pairs[1][1] });
    }
    return spec;
}

fn readThock(x: Ctx, cfg: std.json.ObjectMap) !Spec {
    var spec: Spec = .{ .format = "thock" };
    if (cfg.get("metadata")) |md| if (md == .object) {
        spec.name = str(md.object, "name") orelse "";
        spec.author = str(md.object, "author") orelse "";
    };
    if (cfg.get("license")) |l| if (l == .object) {
        spec.license = str(l.object, "type") orelse "";
    };
    const sounds = cfg.get("sounds") orelse return error.UnknownFormat;
    if (sounds != .object) return error.UnknownFormat;
    var it = sounds.object.iterator();
    while (it.next()) |e| {
        const pool: sound.Pool = if (std.mem.eql(u8, e.key_ptr.*, "default")) .generic else sound.Pool.fromName(e.key_ptr.*) orelse .generic;
        if (e.value_ptr.* != .object) continue;
        for ([_]sound.Dir{ .down, .up }) |d| {
            const list = e.value_ptr.object.get(@tagName(d)) orelse continue;
            if (list != .array) continue;
            for (list.array.items) |n| if (n == .string) try spec.add(x.arena, d, pool, .{ .path = try x.resolve(n.string) });
        }
    }
    return spec;
}

fn readKbsim(x: Ctx) !Spec {
    var spec: Spec = .{ .format = "kbsim" };
    for ([_]struct { d: sound.Dir, sub: []const u8 }{ .{ .d = .down, .sub = "press" }, .{ .d = .up, .sub = "release" } }) |p| {
        const dir_path = try std.fs.path.join(x.arena, &.{ x.folder, p.sub });
        var d = Io.Dir.cwd().openDir(x.io, dir_path, .{ .iterate = true }) catch continue;
        defer d.close(x.io);
        var names: std.ArrayList([]const u8) = .empty;
        var it = d.iterate();
        while (it.next(x.io) catch null) |e| if (e.kind == .file) try names.append(x.arena, try x.arena.dupe(u8, e.name));
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        for (names.items) |name| {
            const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse continue;
            const ext = name[dot..];
            if (!(std.ascii.eqlIgnoreCase(ext, ".wav") or std.ascii.eqlIgnoreCase(ext, ".ogg") or std.ascii.eqlIgnoreCase(ext, ".mp3"))) continue;
            var stem_buf: [64]u8 = undefined;
            const stem = std.ascii.upperString(stem_buf[0..@min(dot, 64)], name[0..@min(dot, 64)]);
            var base = stem;
            if (std.mem.lastIndexOf(u8, stem, "_R")) |r| if (r + 2 < stem.len and std.ascii.isDigit(stem[r + 2])) {
                base = stem[0..r];
            };
            const pool: ?sound.Pool = if (std.mem.eql(u8, base, "GENERIC")) .generic else if (std.mem.eql(u8, base, "SPACE")) .space else if (std.mem.eql(u8, base, "ENTER")) .enter else if (std.mem.eql(u8, base, "BACKSPACE")) .backspace else null;
            if (pool) |pl| try spec.add(x.arena, p.d, pl, .{ .path = try std.fs.path.join(x.arena, &.{ dir_path, name }) });
        }
    }
    return spec;
}

fn readAny(x: Ctx) !Spec {
    const cfg_path = try std.fs.path.join(x.arena, &.{ x.folder, "config.json" });
    const bytes = Io.Dir.cwd().readFileAlloc(x.io, cfg_path, x.arena, .limited(4 << 20)) catch {
        const press = try std.fs.path.join(x.arena, &.{ x.folder, "press" });
        if (Io.Dir.cwd().access(x.io, press, .{})) |_| return readKbsim(x) else |_| return error.NoConfig;
    };
    const text = if (std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF")) bytes[3..] else bytes;
    const v = std.json.parseFromSliceLeaky(std.json.Value, x.arena, text, .{}) catch return error.UnknownFormat;
    if (v != .object) return error.UnknownFormat;
    const o = v.object;
    if (o.get("sounds") != null and o.get("metadata") != null) return readThock(x, o);
    if (o.get("definitions") != null or o.get("defs") != null) return readMechvibesDx(x, o);
    if (o.get("defines") != null) return readMechvibes(x, o);
    return error.UnknownFormat;
}

// ---- audio --------------------------------------------------------------------------------

const Decoded = struct { samples: []f32, rate: u32 };

/// Decode a whole file to mono f32 (cached per path: sprites are shared by every key).
fn decodeFile(x: Ctx, cache: *std.StringHashMapUnmanaged(Decoded), path: []const u8) !Decoded {
    if (cache.get(path)) |d| return d;
    const bytes = Io.Dir.cwd().readFileAlloc(x.io, path, x.arena, .limited(64 << 20)) catch return error.MissingAudio;
    const d = try decodeBytes(x.arena, bytes);
    try cache.put(x.arena, path, d);
    return d;
}

pub fn decodeBytes(arena: Allocator, bytes: []const u8) !Decoded {
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF")) {
        var d = zpui.audio.wav.decode(arena, bytes) catch return error.BadAudio;
        defer d.deinit(arena);
        return .{ .samples = try downmix(arena, d.samples, d.channels), .rate = d.rate };
    }
    var channels: c_int = 0;
    var rate: c_int = 0;
    var out_ptr: ?[*]c_short = null;
    const frames = if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "OggS"))
        c.tb_decode_ogg(bytes.ptr, @intCast(bytes.len), &channels, &rate, &out_ptr)
    else
        c.tb_decode_mp3(bytes.ptr, @intCast(bytes.len), &channels, &rate, &out_ptr);
    const out = out_ptr orelse return error.BadAudio;
    defer c.tb_decoder_free(out);
    if (frames <= 0 or channels <= 0 or rate <= 0) return error.BadAudio;
    const n: usize = @intCast(frames);
    const ch: usize = @intCast(channels);
    const mono = try arena.alloc(f32, n);
    for (mono, 0..) |*m, i| {
        var acc: f32 = 0;
        for (0..ch) |k| acc += @as(f32, @floatFromInt(out[i * ch + k])) / 32768.0;
        m.* = acc / @as(f32, @floatFromInt(ch));
    }
    return .{ .samples = mono, .rate = @intCast(rate) };
}

fn downmix(arena: Allocator, interleaved: []const f32, channels: anytype) ![]f32 {
    const ch: usize = @max(@as(usize, @intCast(channels)), 1);
    const n = interleaved.len / ch;
    const mono = try arena.alloc(f32, n);
    for (mono, 0..) |*m, i| {
        var acc: f32 = 0;
        for (0..ch) |k| acc += interleaved[i * ch + k];
        m.* = acc / @as(f32, @floatFromInt(ch));
    }
    return mono;
}

/// Linear-interpolation resampler (key clicks are short; aliasing is inaudible here).
fn resample(arena: Allocator, x: []const f32, from: u32) ![]f32 {
    if (from == SR) return arena.dupe(f32, x);
    const n: usize = @intCast(@as(u64, x.len) * SR / from);
    const out = try arena.alloc(f32, @max(n, 1));
    const step = @as(f64, @floatFromInt(from)) / SR;
    for (out, 0..) |*o, i| {
        const p = @as(f64, @floatFromInt(i)) * step;
        const k: usize = @intFromFloat(p);
        const f: f32 = @floatCast(p - @as(f64, @floatFromInt(k)));
        const a = if (k < x.len) x[k] else 0;
        const b = if (k + 1 < x.len) x[k + 1] else a;
        o.* = a + (b - a) * f;
    }
    return out;
}

fn loadSource(x: Ctx, cache: *std.StringHashMapUnmanaged(Decoded), s: Source) ![]f32 {
    const d = try decodeFile(x, cache, s.path);
    var seg = d.samples;
    if (s.start_ms) |st| {
        const r: f64 = @floatFromInt(d.rate);
        const a: usize = @intFromFloat(@max(0, @round(st * r / 1000)));
        const b: usize = @intFromFloat(@max(0, @round((s.end_ms orelse st) * r / 1000)));
        const lo = @min(a, seg.len);
        seg = seg[lo..@min(@max(b, lo + 1), seg.len)];
    }
    return resample(x.arena, seg, d.rate);
}

/// RMS envelope sample at i over a window of `w` samples (centred).
fn envAt(x: []const f32, i: usize, w: usize) f32 {
    const lo = i -| w / 2;
    const hi = @min(x.len, lo + w);
    var acc: f32 = 0;
    for (x[lo..hi]) |v| acc += v * v;
    return @sqrt(acc / @as(f32, @floatFromInt(@max(hi - lo, 1))));
}

/// Onset-aligned trim (1 ms pre-roll, sin² fade-in), tail cut + 12 ms cos² fade-out.
pub fn trim(arena: Allocator, x_in: []const f32, max_ms: u32) ![]f32 {
    if (x_in.len < 32) return error.BadAudio;
    // Remove DC.
    var mean: f32 = 0;
    for (x_in) |v| mean += v;
    mean /= @floatFromInt(x_in.len);
    const x = try arena.alloc(f32, x_in.len);
    for (x, x_in) |*o, v| o.* = v - mean;
    var peak: f32 = 0;
    for (x) |v| peak = @max(peak, @abs(v));
    if (peak < 1e-5) return error.BadAudio;
    const w_on: usize = SR / 4000; // 0.25 ms
    var env_pk: f32 = 0;
    var i: usize = 0;
    while (i < x.len) : (i += w_on) env_pk = @max(env_pk, envAt(x, i, w_on));
    var onset: usize = 0;
    while (onset < x.len and envAt(x, onset, w_on) < env_pk * 0.1) onset += 1;
    const pre: usize = SR / 1000;
    const start = onset -| pre;
    const k = onset - start;
    var y: std.ArrayList(f32) = .empty;
    if (k < pre) try y.appendNTimes(arena, 0, pre - k);
    try y.appendSlice(arena, x[start..]);
    const fade_in_start = pre - k;
    for (0..k) |j| {
        const t = @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(@max(k, 1)));
        const s = @sin(t * std.math.pi / 2);
        y.items[fade_in_start + j] *= s * s;
    }
    // Tail: last point where the 5 ms envelope is above peak − 48 dB.
    const w5: usize = SR / 200;
    var env5_pk: f32 = 0;
    i = 0;
    while (i < y.items.len) : (i += w5 / 2) env5_pk = @max(env5_pk, envAt(y.items, i, w5));
    const thr = env5_pk * 0.004; // −48 dB
    var end = y.items.len;
    while (end > pre and envAt(y.items, end - 1, w5) < thr) end -|= w5 / 4;
    end = @min(@min(end + w5, y.items.len), @as(usize, max_ms) * SR / 1000);
    end = @max(end, @min(y.items.len, SR / 50));
    const out = y.items[0..end];
    const nf = @min(SR * 12 / 1000, out.len / 3);
    for (0..nf) |j| {
        const t = @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(nf));
        const cv = @cos(t * std.math.pi / 2);
        out[out.len - nf + j] *= cv * cv;
    }
    return out;
}

/// "Strike loudness": RMS over the first 50 ms, dBFS.
pub fn strikeDb(x: []const f32) f32 {
    const n = @min(x.len, SR / 20);
    var acc: f64 = 0;
    for (x[0..n]) |v| acc += v * v;
    const rms = @sqrt(acc / @as(f64, @floatFromInt(SR / 20)));
    return @floatCast(20 * std.math.log10(@max(rms, 1e-9)));
}

fn median(vals: []f32) f32 {
    std.mem.sort(f32, vals, {}, std.sort.asc(f32));
    return vals[vals.len / 2];
}

/// Target strike loudness: the bundled nk-cream generic key-downs (all bundled packs are
/// loudness-matched to each other).
fn referenceDb(arena: Allocator) f32 {
    var vals: [8]f32 = undefined;
    var n: usize = 0;
    for (1..6) |i| {
        var b: [64]u8 = undefined;
        const p = std.fmt.bufPrint(&b, "sounds/packs/nk-cream/down/generic_{d:0>2}.wav", .{i}) catch continue;
        const bytes = assets.get(p) orelse continue;
        const d = decodeBytes(arena, bytes) catch continue;
        vals[n] = strikeDb(d.samples);
        n += 1;
    }
    return if (n == 0) -24 else median(vals[0..n]);
}

fn pick(list: []const Source, cap: usize, out: []Source) []Source {
    if (list.len <= cap) {
        @memcpy(out[0..list.len], list);
        return out[0..list.len];
    }
    for (0..cap) |i| out[i] = list[(i * (list.len - 1) + (cap - 1) / 2) / (cap - 1)];
    return out[0..cap];
}

pub fn slugify(buf: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    var dash = false;
    for (s) |ch| {
        if (n == buf.len) break;
        if (std.ascii.isAlphanumeric(ch)) {
            if (dash and n > 0 and n < buf.len) {
                buf[n] = '-';
                n += 1;
            }
            dash = false;
            if (n < buf.len) {
                buf[n] = std.ascii.toLower(ch);
                n += 1;
            }
        } else dash = true;
    }
    if (n == 0) {
        @memcpy(buf[0..4], "pack");
        n = 4;
    }
    return buf[0..@min(n, 64)];
}

/// Convert the pack in `src_folder` into `<dest_root>/<id>/` and return the id (caller frees).
pub fn importPack(gpa: Allocator, io: Io, src_folder: []const u8, dest_root: []const u8) ![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const x: Ctx = .{ .arena = arena, .io = io, .folder = src_folder };
    const spec = try readAny(x);

    var cache: std.StringHashMapUnmanaged(Decoded) = .empty;
    var proc: [2][sound.pool_count][]const []f32 = @splat(@splat(&.{}));
    for (0..2) |di| for (0..sound.pool_count) |pi| {
        const list = spec.sounds[di][pi].items;
        if (list.len == 0) continue;
        var buf: [max_generic]Source = undefined;
        const chosen = pick(list, if (pi == @intFromEnum(sound.Pool.generic)) max_generic else max_special, &buf);
        var ys: std.ArrayList([]f32) = .empty;
        for (chosen) |s| {
            const raw = try loadSource(x, &cache, s);
            const y = trim(arena, raw, if (di == 0) 260 else 200) catch continue;
            try ys.append(arena, y);
        }
        if (ys.items.len == 0) continue;
        // Pull variants of one pool within ±2 dB of the pool median.
        const lv = try arena.alloc(f32, ys.items.len);
        for (ys.items, lv) |y, *l| l.* = strikeDb(y);
        const lv_sorted = try arena.dupe(f32, lv);
        const med = median(lv_sorted);
        for (ys.items, lv) |y, l| {
            const g = std.math.pow(f32, 10, (std.math.clamp(l, med - 2, med + 2) - l) / 20);
            for (y) |*v| v.* *= g;
        }
        proc[di][pi] = ys.items;
    };
    const gi = @intFromEnum(sound.Pool.generic);
    for (0..2) |di| if (proc[di][gi].len == 0) {
        // Every pack needs a generic pool: borrow the most populated one.
        var best: usize = 0;
        var best_n: usize = 0;
        for (proc[di], 0..) |p, i| if (p.len > best_n) {
            best_n = p.len;
            best = i;
        };
        if (best_n > 0) proc[di][gi] = proc[di][best];
    };
    if (proc[0][gi].len == 0) return error.NoKeyDownSounds;

    const gen_db = try arena.alloc(f32, proc[0][gi].len);
    for (proc[0][gi], gen_db) |y, *l| l.* = strikeDb(y);
    const ref = median(gen_db);
    // Specials at most +4 dB, key-ups at most +0 dB relative to generic key-downs.
    for (0..2) |di| for (0..sound.pool_count) |pi| {
        if ((di == 0 and pi == gi) or proc[di][pi].len == 0) continue;
        const v = try arena.alloc(f32, proc[di][pi].len);
        for (proc[di][pi], v) |y, *l| l.* = strikeDb(y);
        const med = median(v);
        const cap: f32 = if (di == 1) 0 else 4;
        if (med > ref + cap) {
            const g = std.math.pow(f32, 10, (ref + cap - med) / 20);
            for (proc[di][pi]) |y| for (y) |*s| {
                s.* *= g;
            };
        }
    };
    const gain = std.math.pow(f32, 10, (referenceDb(arena) - ref) / 20);
    const ceiling: f32 = std.math.pow(f32, 10, -1.0 / 20.0);

    const raw_name = if (spec.name.len > 0) spec.name else std.fs.path.basename(src_folder);
    var id_buf: [64]u8 = undefined;
    const id = slugify(&id_buf, raw_name);
    const out_dir = try std.fs.path.join(arena, &.{ dest_root, id });
    Io.Dir.cwd().deleteTree(io, out_dir) catch {};
    var od = try Io.Dir.cwd().createDirPathOpen(io, out_dir, .{});
    defer od.close(io);

    var json: std.ArrayList(u8) = .empty;
    const js = struct {
        fn esc(a: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
            try out.append(a, '"');
            for (s) |ch| switch (ch) {
                '"' => try out.appendSlice(a, "\\\""),
                '\\' => try out.appendSlice(a, "\\\\"),
                0...0x1f => try out.print(a, "\\u{x:0>4}", .{ch}),
                else => try out.append(a, ch),
            };
            try out.append(a, '"');
        }
    };
    try json.appendSlice(arena, "{\n  \"format\": \"typebud.soundpack\",\n  \"format_version\": 1,\n  \"id\": ");
    try js.esc(arena, &json, id);
    try json.appendSlice(arena, ",\n  \"name\": ");
    try js.esc(arena, &json, raw_name);
    try json.appendSlice(arena, ",\n  \"author\": ");
    try js.esc(arena, &json, if (spec.author.len > 0) spec.author else "unknown");
    try json.appendSlice(arena, ",\n  \"license\": ");
    try js.esc(arena, &json, if (spec.license.len > 0) spec.license else "NOASSERTION");
    try json.appendSlice(arena, ",\n  \"description\": ");
    try js.esc(arena, &json, try std.fmt.allocPrint(arena, "Imported {s} pack", .{spec.format}));
    try json.appendSlice(arena, ",\n  \"source\": { \"imported_from\": ");
    try js.esc(arena, &json, spec.format);
    try json.appendSlice(arena, " },\n  \"playback\": { \"pitch_jitter_cents\": 10, \"gain_jitter_db\": 1.0 },\n  \"sounds\": {");
    var first_dir = true;
    for (0..2) |di| {
        var any = false;
        for (proc[di]) |p| any = any or p.len > 0;
        if (!any) continue;
        const dname = if (di == 0) "down" else "up";
        try json.print(arena, "{s}\n    \"{s}\": {{", .{ if (first_dir) "" else ",", dname });
        first_dir = false;
        var first_pool = true;
        for (proc[di], 0..) |ys, pi| {
            if (ys.len == 0) continue;
            const pname = @tagName(@as(sound.Pool, @enumFromInt(pi)));
            try json.print(arena, "{s}\n      \"{s}\": [", .{ if (first_pool) "" else ",", pname });
            first_pool = false;
            for (ys, 1..) |y, n| {
                var pk: f32 = 0;
                for (y) |v| pk = @max(pk, @abs(v * gain));
                const g = if (pk > ceiling) gain * ceiling / pk else gain;
                const pcm = try arena.alloc(f32, y.len);
                for (pcm, y) |*o, v| o.* = v * g;
                const wav = try sound.encodeWav16(arena, pcm, SR, 1);
                const rel = try std.fmt.allocPrint(arena, "{s}/{s}_{d:0>2}.wav", .{ dname, pname, n });
                try od.createDirPath(io, dname);
                try od.writeFile(io, .{ .sub_path = rel, .data = wav });
                try json.print(arena, "{s}\"{s}\"", .{ if (n == 1) "" else ", ", rel });
            }
            try json.append(arena, ']');
        }
        try json.appendSlice(arena, "\n    }");
    }
    try json.appendSlice(arena, "\n  }\n}\n");
    try od.writeFile(io, .{ .sub_path = "pack.json", .data = json.items });
    return gpa.dupe(u8, id);
}

// ---- tests ----------------------------------------------------------------------------------

const testing = std.testing;

test "key code tables (FORMAT.md 7.4)" {
    try testing.expectEqual(sound.Pool.generic, iohookPool(30)); // A
    try testing.expectEqual(sound.Pool.space, iohookPool(57));
    try testing.expectEqual(sound.Pool.enter, iohookPool(3612));
    try testing.expectEqual(sound.Pool.modifier, iohookPool(3675));
    try testing.expectEqual(sound.Pool.arrow, iohookPool(61008));
    try testing.expectEqual(sound.Pool.generic, iohookPool(59)); // F1 -> other -> generic
    try testing.expectEqual(sound.Pool.generic, w3cPool("KeyQ"));
    try testing.expectEqual(sound.Pool.modifier, w3cPool("ShiftLeft"));
    try testing.expectEqual(sound.Pool.modifier, w3cPool("MetaRight"));
    try testing.expectEqual(sound.Pool.arrow, w3cPool("ArrowUp"));
    try testing.expectEqual(sound.Pool.enter, w3cPool("NumpadEnter"));
    try testing.expectEqual(sound.Pool.generic, w3cPool("Semicolon"));
}

test "ranges and slugs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try expandRange(arena.allocator(), "press/GENERIC_R{0-4}.mp3");
    try testing.expectEqual(@as(usize, 5), r.len);
    try testing.expectEqualStrings("press/GENERIC_R3.mp3", r[3]);
    var b: [64]u8 = undefined;
    try testing.expectEqualStrings("mx-brown-full-travel", slugify(&b, "MX Brown - Full Travel"));
}

fn writeTestPack(io: Io, dir: Io.Dir, sub: []const u8, files: []const [2][]const u8) !void {
    try dir.createDirPath(io, sub);
    for (files) |f| {
        var b: [256]u8 = undefined;
        const p = try std.fmt.bufPrint(&b, "{s}/{s}", .{ sub, f[0] });
        if (std.fs.path.dirname(p)) |d| try dir.createDirPath(io, d);
        try dir.writeFile(io, .{ .sub_path = p, .data = f[1] });
    }
}

test "import Mechvibes (single sprite + v2 multi), MechvibesDX and Thock packs" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pb: [512]u8 = undefined;
    const root = pb[0..try tmp.dir.realPath(io, &pb)];
    const k1 = assets.get("sounds/packs/topre/down/generic_01.wav").?;
    const k2 = assets.get("sounds/packs/topre/down/space_01.wav").?;
    // A sprite: two key sounds back to back (WAV, 48 kHz mono) — 300 ms each.
    var sprite_arena: std.heap.ArenaAllocator = .init(gpa);
    defer sprite_arena.deinit();
    const sa = sprite_arena.allocator();
    const d1 = try decodeBytes(sa, k1);
    const d2 = try decodeBytes(sa, k2);
    const sprite = try sa.alloc(f32, SR * 6 / 10);
    @memset(sprite, 0);
    @memcpy(sprite[0..d1.samples.len], d1.samples);
    @memcpy(sprite[SR * 3 / 10 ..][0..d2.samples.len], d2.samples);
    const sprite_wav = try sound.encodeWav16(sa, sprite, SR, 1);

    try writeTestPack(io, tmp.dir, "mv1", &.{
        .{ "config.json", "{\"name\":\"Test Sprite\",\"key_define_type\":\"single\",\"sound\":\"Sprite.WAV\",\"defines\":{\"30\":[0,250],\"31\":[0,250],\"57\":[300,250],\"2\":null}}" },
        .{ "sprite.wav", sprite_wav },
    });
    try writeTestPack(io, tmp.dir, "mv2", &.{
        .{ "config.json", "{\"name\":\"Multi V2\",\"version\":2,\"key_define_type\":\"multi\",\"sound\":\"press/GENERIC_R{0-1}.wav\",\"soundup\":\"release/GENERIC.wav\",\"defines\":{\"57\":\"press/SPACE.wav\",\"57-up\":\"release/GENERIC.wav\"}}" },
        .{ "press/GENERIC_R0.wav", k1 },
        .{ "press/GENERIC_R1.wav", k1 },
        .{ "press/SPACE.wav", k2 },
        .{ "release/GENERIC.wav", k1 },
    });
    try writeTestPack(io, tmp.dir, "dx", &.{
        .{ "config.json", "{\"config_version\":\"2\",\"name\":\"DX Pack\",\"author\":\"someone\",\"definition_method\":\"single\",\"audio_file\":\"s.wav\",\"definitions\":{\"KeyA\":{\"timing\":[[0,120],[120,250]]},\"Space\":{\"timing\":[[300,550]]},\"MouseLeft\":{\"timing\":[[0,10]]}}}" },
        .{ "s.wav", sprite_wav },
    });
    try writeTestPack(io, tmp.dir, "thock", &.{
        .{ "config.json", "{\"metadata\":{\"name\":\"Thocky\",\"author\":\"T\"},\"license\":{\"type\":\"CC0-1.0\"},\"sounds\":{\"default\":{\"down\":[\"1.wav\"],\"up\":[\"2.wav\"]},\"space\":{\"down\":[\"2.wav\"]}}}" },
        .{ "1.wav", k1 },
        .{ "2.wav", k2 },
    });
    try writeTestPack(io, tmp.dir, "evil", &.{
        .{ "config.json", "{\"name\":\"Evil\",\"key_define_type\":\"single\",\"sound\":\"../outside.wav\",\"defines\":{\"30\":[0,10]}}" },
    });

    const dest = try std.fs.path.join(gpa, &.{ root, "out" });
    defer gpa.free(dest);
    var lib = sound.Library.init(gpa);
    defer lib.deinit();
    for ([_][]const u8{ "mv1", "mv2", "dx", "thock" }, [_][]const u8{ "test-sprite", "multi-v2", "dx-pack", "thocky" }) |name, want_id| {
        const src = try std.fs.path.join(gpa, &.{ root, name });
        defer gpa.free(src);
        const id = try importPack(gpa, io, src, dest);
        defer gpa.free(id);
        try testing.expectEqualStrings(want_id, id);
        const info = try lib.loadUserPack(io, dest, id); // validates against FORMAT.md
        try testing.expect(info.files[0][@intFromEnum(sound.Pool.generic)].len >= 1);
    }
    try testing.expect(lib.find("test-sprite").?.files[0][@intFromEnum(sound.Pool.space)].len == 1);
    try testing.expect(lib.find("multi-v2").?.has_up);
    try testing.expect(!lib.find("dx-pack").?.has_up); // rejoined halves: no key-up
    try testing.expectEqualStrings("CC0-1.0", lib.find("thocky").?.license);
    const evil = try std.fs.path.join(gpa, &.{ root, "evil" });
    defer gpa.free(evil);
    try testing.expectError(error.PathEscapes, importPack(gpa, io, evil, dest));
}
