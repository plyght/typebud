//! GitHub Releases: parsing `GET /repos/{owner}/{repo}/releases` and choosing
//! the release to offer. Pure functions; networking lives in http.zig.
//!
//! Nothing here is trusted for integrity: GitHub metadata (tag, prerelease
//! flag, asset URLs, notes) only tells us where to look. What gets installed
//! is decided by the signed manifest (manifest.zig).

const std = @import("std");
const semver = @import("semver.zig");
const manifest = @import("manifest.zig");

pub const api_host = "api.github.com";
pub const per_page = 15;
/// Upper bound on the releases response we'll buffer.
pub const max_releases_bytes = 4 * 1024 * 1024;
/// Release notes are truncated to this many bytes for display.
pub const max_notes_bytes = 16 * 1024;

pub const Asset = struct {
    name: []const u8,
    url: []const u8,
};

/// The release we'd offer, as remembered between checks (also serialized into
/// the state file so a `304 Not Modified` can be answered from cache).
pub const Candidate = struct {
    tag: []const u8,
    version: []const u8,
    prerelease: bool,
    notes: []const u8,
    html_url: []const u8,
    manifest_url: []const u8,
    signature_url: []const u8,
    assets: []const Asset,

    pub fn assetUrl(c: Candidate, name: []const u8) ?[]const u8 {
        for (c.assets) |a| if (std.mem.eql(u8, a.name, name)) return a.url;
        return null;
    }
};

const RawAsset = struct {
    name: []const u8,
    browser_download_url: []const u8,
};

const RawRelease = struct {
    tag_name: []const u8,
    draft: bool = false,
    prerelease: bool = false,
    body: ?[]const u8 = null,
    html_url: []const u8 = "",
    assets: []const RawAsset = &.{},
};

pub const default_api_base = "https://" ++ api_host;
pub const default_download_base = "https://github.com";

pub fn releasesUrl(buf: []u8, api_base: []const u8, owner: []const u8, repo: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/repos/{s}/{s}/releases?per_page={d}", .{ api_base, owner, repo, per_page });
}

/// Every asset URL must point at this repo's release downloads
/// (`https://github.com/<owner>/<repo>/releases/download/...`).
pub fn isTrustedAssetUrl(url: []const u8, download_base: []const u8, owner: []const u8, repo: []const u8) bool {
    if (!std.mem.startsWith(u8, url, download_base)) return false;
    var rest = url[download_base.len..];
    if (rest.len == 0 or rest[0] != '/') return false;
    rest = rest[1..];
    if (!std.ascii.startsWithIgnoreCase(rest, owner)) return false;
    rest = rest[owner.len..];
    if (rest.len == 0 or rest[0] != '/') return false;
    rest = rest[1..];
    if (!std.ascii.startsWithIgnoreCase(rest, repo)) return false;
    rest = rest[repo.len..];
    return std.mem.startsWith(u8, rest, "/releases/download/");
}

pub const SelectOptions = struct {
    owner: []const u8,
    repo: []const u8,
    channel: manifest.Channel,
    download_base: []const u8 = default_download_base,
};

/// Parses the releases JSON and picks the highest-versioned release that:
///   * is not a draft,
///   * is not a GitHub pre-release and has no semver pre-release tag (unless
///     the channel is `beta`),
///   * has a parseable `vX.Y.Z` tag,
///   * carries both `manifest.json` and `manifest.json.sig` assets.
/// Allocations go to `arena`. Returns null if nothing qualifies.
pub fn selectRelease(arena: std.mem.Allocator, json: []const u8, opts: SelectOptions) !?Candidate {
    const releases = std.json.parseFromSliceLeaky([]const RawRelease, arena, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ReleasesMalformed,
    };

    var best: ?RawRelease = null;
    var best_version: semver.Version = undefined;
    for (releases) |r| {
        if (r.draft) continue;
        const v = semver.parse(r.tag_name) catch continue;
        const is_pre = r.prerelease or semver.isPrerelease(v);
        if (is_pre and opts.channel != .beta) continue;
        if (findAsset(r.assets, manifest.manifest_asset_name, opts) == null) continue;
        if (findAsset(r.assets, manifest.signature_asset_name, opts) == null) continue;
        if (best == null or v.order(best_version) == .gt) {
            best = r;
            best_version = v;
        }
    }
    const r = best orelse return null;

    var assets: std.ArrayList(Asset) = .empty;
    for (r.assets) |a| {
        if (!isTrustedAssetUrl(a.browser_download_url, opts.download_base, opts.owner, opts.repo)) continue;
        try assets.append(arena, .{ .name = a.name, .url = a.browser_download_url });
    }
    const notes = r.body orelse "";
    const tag = std.mem.trim(u8, r.tag_name, " ");
    return .{
        .tag = tag,
        .version = if (tag[0] == 'v' or tag[0] == 'V') tag[1..] else tag,
        .prerelease = r.prerelease or semver.isPrerelease(best_version),
        .notes = notes[0..@min(notes.len, max_notes_bytes)],
        .html_url = r.html_url,
        .manifest_url = findAsset(r.assets, manifest.manifest_asset_name, opts).?,
        .signature_url = findAsset(r.assets, manifest.signature_asset_name, opts).?,
        .assets = assets.items,
    };
}

fn findAsset(assets: []const RawAsset, name: []const u8, opts: SelectOptions) ?[]const u8 {
    for (assets) |a| {
        if (std.mem.eql(u8, a.name, name) and isTrustedAssetUrl(a.browser_download_url, opts.download_base, opts.owner, opts.repo))
            return a.browser_download_url;
    }
    return null;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn rel(comptime tag: []const u8, comptime draft: bool, comptime pre: bool, comptime signed: bool) []const u8 {
    const base = "https://github.com/plyght/typebud/releases/download/" ++ tag ++ "/";
    const signed_assets = if (signed)
        \\{"name":"manifest.json","browser_download_url":"
    ++ base ++
        \\manifest.json","size":500},{"name":"manifest.json.sig","browser_download_url":"
    ++ base ++
        \\manifest.json.sig","size":129},
    else
        "";
    return "{\"tag_name\":\"" ++ tag ++ "\",\"draft\":" ++ (if (draft) "true" else "false") ++
        ",\"prerelease\":" ++ (if (pre) "true" else "false") ++
        ",\"body\":\"notes for " ++ tag ++ "\",\"html_url\":\"https://github.com/plyght/typebud/releases/tag/" ++ tag ++
        "\",\"author\":{\"login\":\"plyght\"},\"assets\":[" ++ signed_assets ++
        "{\"name\":\"typebud-macos-universal.zip\",\"browser_download_url\":\"" ++ base ++ "typebud-macos-universal.zip\",\"size\":1}]}";
}

const sample = "[" ++
    rel("v0.4.0", true, false, true) ++ "," ++ // draft: never
    rel("v0.3.1-beta.1", false, true, true) ++ "," ++ // beta only
    rel("v0.3.0", false, false, false) ++ "," ++ // unsigned: skipped
    rel("v0.2.0", false, false, true) ++ "," ++
    rel("nightly", false, false, true) ++ "," ++ // not semver
    rel("v0.1.0", false, false, true) ++ "]";

test "stable channel picks newest signed non-draft non-prerelease" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const c = (try selectRelease(arena.allocator(), sample, .{ .owner = "plyght", .repo = "typebud", .channel = .stable })).?;
    try testing.expectEqualStrings("v0.2.0", c.tag);
    try testing.expectEqualStrings("0.2.0", c.version);
    try testing.expect(!c.prerelease);
    try testing.expectEqualStrings("notes for v0.2.0", c.notes);
    try testing.expectEqualStrings("https://github.com/plyght/typebud/releases/download/v0.2.0/manifest.json", c.manifest_url);
    try testing.expect(c.assetUrl("typebud-macos-universal.zip") != null);
}

test "beta channel includes prereleases" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const c = (try selectRelease(arena.allocator(), sample, .{ .owner = "plyght", .repo = "typebud", .channel = .beta })).?;
    try testing.expectEqualStrings("0.3.1-beta.1", c.version);
    try testing.expect(c.prerelease);
}

test "prerelease-looking tag without the GitHub flag is still beta-only" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const json = comptime "[" ++ rel("v0.9.0-rc.1", false, false, true) ++ "," ++ rel("v0.1.0", false, false, true) ++ "]";
    const c = (try selectRelease(arena.allocator(), json, .{ .owner = "plyght", .repo = "typebud", .channel = .stable })).?;
    try testing.expectEqualStrings("0.1.0", c.version);
}

test "no qualifying release" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try selectRelease(arena.allocator(), "[]", .{ .owner = "plyght", .repo = "typebud", .channel = .stable })) == null);
    const json = comptime "[" ++ rel("v0.4.0", true, false, true) ++ "," ++ rel("v0.3.0", false, false, false) ++ "]";
    try testing.expect((try selectRelease(arena.allocator(), json, .{ .owner = "plyght", .repo = "typebud", .channel = .beta })) == null);
    try testing.expectError(error.ReleasesMalformed, selectRelease(arena.allocator(), "{\"message\":\"API rate limit exceeded\"}", .{ .owner = "plyght", .repo = "typebud", .channel = .stable }));
}

test "asset URLs from other repos are ignored" {
    try testing.expect(isTrustedAssetUrl("https://github.com/plyght/typebud/releases/download/v1.0.0/manifest.json", default_download_base, "plyght", "typebud"));
    try testing.expect(!isTrustedAssetUrl("http://github.com/plyght/typebud/releases/download/v1.0.0/manifest.json", default_download_base, "plyght", "typebud"));
    try testing.expect(!isTrustedAssetUrl("https://github.com/evil/typebud/releases/download/v1.0.0/manifest.json", default_download_base, "plyght", "typebud"));
    try testing.expect(!isTrustedAssetUrl("https://github.com/plyght/typebud-evil/releases/download/x", default_download_base, "plyght", "typebud"));
    try testing.expect(!isTrustedAssetUrl("https://example.com/plyght/typebud/releases/download/x", default_download_base, "plyght", "typebud"));
    try testing.expect(!isTrustedAssetUrl("https://github.com.evil.example/plyght/typebud/releases/download/x", default_download_base, "plyght", "typebud"));
}

test "releases without a signed manifest are never offered" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const o: SelectOptions = .{ .owner = "plyght", .repo = "typebud", .channel = .stable };
    // Newest release published without manifest.json/.sig (a build from a repo
    // with no signing key): skipped, the older signed one is offered instead.
    const mixed = comptime "[" ++ rel("v0.5.0", false, false, false) ++ "," ++ rel("v0.4.0", false, false, true) ++ "]";
    try testing.expectEqualStrings("0.4.0", (try selectRelease(arena.allocator(), mixed, o)).?.version);
    // Only unsigned releases: nothing to offer, so no manifest is ever fetched.
    const unsigned = comptime "[" ++ rel("v0.5.0", false, false, false) ++ "," ++ rel("v0.4.0", false, false, false) ++ "]";
    try testing.expect((try selectRelease(arena.allocator(), unsigned, o)) == null);
    // manifest.json without manifest.json.sig is just as unsigned.
    const base = "https://github.com/plyght/typebud/releases/download/v0.6.0/";
    const no_sig = "[{\"tag_name\":\"v0.6.0\",\"assets\":[{\"name\":\"manifest.json\",\"browser_download_url\":\"" ++ base ++
        "manifest.json\"},{\"name\":\"typebud-linux-x86_64.tar.gz\",\"browser_download_url\":\"" ++ base ++ "typebud-linux-x86_64.tar.gz\"}]}]";
    try testing.expect((try selectRelease(arena.allocator(), no_sig, o)) == null);
}
