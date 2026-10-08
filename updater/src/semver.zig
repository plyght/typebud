//! Semantic version parsing and comparison for release tags.
//!
//! Thin wrapper around `std.SemanticVersion` that accepts an optional leading
//! `v` (git tags are `v1.2.3`) and exposes the comparisons the updater needs.

const std = @import("std");

pub const Version = std.SemanticVersion;

pub const ParseError = error{InvalidVersion};

/// Parses `1.2.3`, `v1.2.3`, `1.2.3-beta.1`, `1.2.3+build.5`.
/// The returned version borrows `text` (pre-release / build slices).
pub fn parse(text: []const u8) ParseError!Version {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const body = if (trimmed.len > 0 and (trimmed[0] == 'v' or trimmed[0] == 'V')) trimmed[1..] else trimmed;
    if (body.len == 0) return error.InvalidVersion;
    return Version.parse(body) catch return error.InvalidVersion;
}

pub fn order(a: Version, b: Version) std.math.Order {
    return a.order(b);
}

/// True if `candidate` is strictly newer than `current`.
pub fn isNewer(candidate: Version, current: Version) bool {
    return candidate.order(current) == .gt;
}

/// Compares two version strings. Unparseable strings are an error rather than
/// being silently ordered, so a malformed tag can never look "newer".
pub fn orderStrings(a: []const u8, b: []const u8) ParseError!std.math.Order {
    return order(try parse(a), try parse(b));
}

/// A version with a pre-release component (`1.2.0-beta.1`) is a beta build.
pub fn isPrerelease(v: Version) bool {
    return v.pre != null;
}

const testing = std.testing;

test "parse accepts optional v prefix" {
    const a = try parse("v1.2.3");
    try testing.expectEqual(@as(usize, 1), a.major);
    try testing.expectEqual(@as(usize, 2), a.minor);
    try testing.expectEqual(@as(usize, 3), a.patch);
    try testing.expect(a.pre == null);
    const b = try parse("0.1.0-beta.2+abc");
    try testing.expectEqualStrings("beta.2", b.pre.?);
    try testing.expectEqualStrings("abc", b.build.?);
}

test "parse rejects garbage" {
    try testing.expectError(error.InvalidVersion, parse(""));
    try testing.expectError(error.InvalidVersion, parse("v"));
    try testing.expectError(error.InvalidVersion, parse("1.2"));
    try testing.expectError(error.InvalidVersion, parse("1.2.3.4"));
    try testing.expectError(error.InvalidVersion, parse("01.2.3"));
    try testing.expectError(error.InvalidVersion, parse("1.2.x"));
    try testing.expectError(error.InvalidVersion, parse("latest"));
    try testing.expectError(error.InvalidVersion, parse("1.2.3-"));
}

test "ordering follows semver precedence" {
    const cases = [_]struct { a: []const u8, b: []const u8, want: std.math.Order }{
        .{ .a = "1.0.0", .b = "1.0.0", .want = .eq },
        .{ .a = "v1.0.0", .b = "1.0.0", .want = .eq },
        .{ .a = "1.0.1", .b = "1.0.0", .want = .gt },
        .{ .a = "1.1.0", .b = "1.0.9", .want = .gt },
        .{ .a = "2.0.0", .b = "1.99.99", .want = .gt },
        .{ .a = "0.10.0", .b = "0.9.0", .want = .gt }, // numeric, not lexical
        .{ .a = "1.0.0-beta.1", .b = "1.0.0", .want = .lt }, // pre-release < release
        .{ .a = "1.0.0-beta.2", .b = "1.0.0-beta.1", .want = .gt },
        .{ .a = "1.0.0-beta.10", .b = "1.0.0-beta.9", .want = .gt },
        .{ .a = "1.0.0-rc.1", .b = "1.0.0-beta.9", .want = .gt },
        .{ .a = "1.0.0-alpha", .b = "1.0.0-alpha.1", .want = .lt },
        .{ .a = "1.0.0+build.2", .b = "1.0.0+build.1", .want = .eq }, // build metadata ignored
    };
    for (cases) |c| {
        const got = try orderStrings(c.a, c.b);
        testing.expectEqual(c.want, got) catch |err| {
            std.debug.print("order({s}, {s})\n", .{ c.a, c.b });
            return err;
        };
    }
}

test "isNewer is strict" {
    try testing.expect(isNewer(try parse("0.2.0"), try parse("0.1.0")));
    try testing.expect(!isNewer(try parse("0.1.0"), try parse("0.1.0")));
    try testing.expect(!isNewer(try parse("0.0.9"), try parse("0.1.0")));
    try testing.expect(isPrerelease(try parse("0.2.0-beta.1")));
}
