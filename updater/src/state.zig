//! Persistent updater state (`update-state.json` in the app's state dir) and
//! the check schedule.
//!
//! Schedule: automatic checks happen at most once every `check_interval`, plus
//! a random 0..`check_jitter` delay so a fleet of clients that started at the
//! same moment doesn't hit GitHub in lockstep. Checks the user requests from
//! the settings window bypass the schedule (they're still conditional
//! requests, so they're cheap). Nothing runs between checks: the app asks
//! `msUntilNextCheck` and arms a one-shot timer on its own event loop.

const std = @import("std");
const github = @import("github.zig");

pub const check_interval_s: i64 = 6 * 60 * 60;
pub const check_jitter_s: i64 = 45 * 60;
pub const file_name = "update-state.json";

pub const State = struct {
    /// Channel the cached ETag/candidate belong to. A channel switch invalidates both.
    channel: []const u8 = "",
    /// Repository the cache belongs to (owner/repo).
    repo: []const u8 = "",
    etag: []const u8 = "",
    /// Unix seconds.
    last_check: i64 = 0,
    next_check: i64 = 0,
    candidate: ?github.Candidate = null,
};

/// Next automatic check time given `now` and a random value.
pub fn nextCheck(now: i64, random: u64) i64 {
    const jitter: i64 = @intCast(random % @as(u64, @intCast(check_jitter_s)));
    return now + check_interval_s + jitter;
}

pub fn isDue(s: State, now: i64) bool {
    if (s.next_check == 0) return true;
    // Clock went backwards by more than an interval (or state from the future): re-check.
    if (s.last_check > now + check_interval_s) return true;
    return now >= s.next_check;
}

pub fn secondsUntilDue(s: State, now: i64) i64 {
    if (isDue(s, now)) return 0;
    return s.next_check - now;
}

/// Loads state; any problem (missing, corrupt, too large) yields default state.
pub fn load(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) State {
    const bytes = dir.readFileAlloc(io, file_name, arena, .limited(1 << 20)) catch return .{};
    return std.json.parseFromSliceLeaky(State, arena, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch .{};
}

/// Writes state atomically (temp file + rename).
pub fn save(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, s: State) !void {
    const json = try std.json.Stringify.valueAlloc(gpa, s, .{ .whitespace = .indent_2 });
    defer gpa.free(json);
    const tmp_name = file_name ++ ".tmp";
    try dir.writeFile(io, .{ .sub_path = tmp_name, .data = json });
    try dir.rename(tmp_name, dir, file_name, io);
}

const testing = std.testing;

test "schedule: due when never checked, then every 6h plus jitter" {
    var s: State = .{};
    try testing.expect(isDue(s, 1_000_000));
    s.last_check = 1_000_000;
    s.next_check = nextCheck(1_000_000, 12345);
    try testing.expect(s.next_check >= 1_000_000 + check_interval_s);
    try testing.expect(s.next_check < 1_000_000 + check_interval_s + check_jitter_s);
    try testing.expect(!isDue(s, 1_000_000 + 60));
    try testing.expect(!isDue(s, 1_000_000 + check_interval_s - 1));
    try testing.expect(isDue(s, s.next_check));
    try testing.expectEqual(s.next_check - (1_000_000 + 60), secondsUntilDue(s, 1_000_000 + 60));
    // clock jumped backwards a long way
    try testing.expect(isDue(s, 1_000_000 - 2 * check_interval_s));
}

test "jitter spreads clients" {
    var seen_min: i64 = std.math.maxInt(i64);
    var seen_max: i64 = 0;
    var prng: std.Random.DefaultPrng = .init(42);
    for (0..1000) |_| {
        const n = nextCheck(0, prng.random().int(u64)) - check_interval_s;
        seen_min = @min(seen_min, n);
        seen_max = @max(seen_max, n);
    }
    try testing.expect(seen_min < 5 * 60);
    try testing.expect(seen_max > check_jitter_s - 5 * 60);
}

test "state save/load round-trip and corrupt file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s: State = .{
        .channel = "stable",
        .repo = "plyght/typebud",
        .etag = "W/\"abc\"",
        .last_check = 10,
        .next_check = 20,
        .candidate = .{
            .tag = "v0.2.0",
            .version = "0.2.0",
            .prerelease = false,
            .notes = "line1\nline2 \"quoted\"",
            .html_url = "https://github.com/plyght/typebud/releases/tag/v0.2.0",
            .manifest_url = "https://github.com/plyght/typebud/releases/download/v0.2.0/manifest.json",
            .signature_url = "https://github.com/plyght/typebud/releases/download/v0.2.0/manifest.json.sig",
            .assets = &.{.{ .name = "a", .url = "b" }},
        },
    };
    try save(testing.allocator, testing.io, tmp.dir, s);
    const l = load(arena.allocator(), testing.io, tmp.dir);
    try testing.expectEqualStrings("W/\"abc\"", l.etag);
    try testing.expectEqual(@as(i64, 20), l.next_check);
    try testing.expectEqualStrings("line1\nline2 \"quoted\"", l.candidate.?.notes);
    try testing.expectEqualStrings("b", l.candidate.?.assets[0].url);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = file_name, .data = "{not json" });
    const d = load(arena.allocator(), testing.io, tmp.dir);
    try testing.expectEqual(@as(i64, 0), d.next_check);
    try testing.expect(d.candidate == null);
}
