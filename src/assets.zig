//! Runtime access to the files embedded at build time (tools/gen_assets.zig): the art
//! layers and JSON, the bundled sound packs and the legend font. Paths are repo-relative
//! ("art/cat/idle.svg", "sounds/packs/nk-cream/pack.json").

const std = @import("std");
const index = @import("asset_index");

pub const Entry = index.Entry;

/// The index entry of `path` (its `path` slice is static), or null when not embedded.
pub fn entry(path: []const u8) ?*const Entry {
    const entries = &index.entries;
    var lo: usize = 0;
    var hi: usize = entries.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        switch (std.mem.order(u8, entries[mid].path, path)) {
            .eq => return &entries[mid],
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    return null;
}

/// The bytes of `path`, or null when it was not embedded.
pub fn get(path: []const u8) ?[]const u8 {
    const e = entry(path) orelse return null;
    return index.blob[e.off..][0..e.len];
}

pub fn exists(path: []const u8) bool {
    return get(path) != null;
}

/// Every embedded path starting with `prefix` (sorted), for directory-style listing.
pub fn list(prefix: []const u8) []const Entry {
    const entries = &index.entries;
    var start: usize = 0;
    while (start < entries.len and std.mem.order(u8, entries[start].path, prefix) == .lt) start += 1;
    var end = start;
    while (end < entries.len and std.mem.startsWith(u8, entries[end].path, prefix)) end += 1;
    return entries[start..end];
}

/// Animal folders under art/ (every directory but `_shared`), in sorted order.
/// `out` receives the names (slices into the asset index); returns the count.
pub fn animals(out: [][]const u8) usize {
    var n: usize = 0;
    for (list("art/")) |e| {
        const rest = e.path["art/".len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse continue;
        const name = rest[0..slash];
        if (name.len == 0 or name[0] == '_') continue;
        // Only folders with an idle frame count as animals.
        if (!std.mem.eql(u8, rest[slash + 1 ..], "idle.svg")) continue;
        if (n > 0 and std.mem.eql(u8, out[n - 1], name)) continue;
        if (n == out.len) break;
        out[n] = name;
        n += 1;
    }
    return n;
}

test "embedded assets are indexed and sorted" {
    try std.testing.expect(get("art/_shared/keyboard.svg") != null);
    try std.testing.expect(get("art/_shared/themes.json") != null);
    try std.testing.expect(get("assets/fonts/Nunito-ExtraBold.ttf") != null);
    try std.testing.expect(get("sounds/packs/index.json") != null);
    try std.testing.expect(get("art/_shared/reference_pose.svg") == null);
    try std.testing.expect(get("art/cat/preview/sheet.png") == null);
    for (index.entries[1..], 0..) |e, i| try std.testing.expect(std.mem.order(u8, index.entries[i].path, e.path) == .lt);
    var buf: [16][]const u8 = undefined;
    const n = animals(&buf);
    try std.testing.expect(n >= 3);
    var has_cat = false;
    for (buf[0..n]) |a| has_cat = has_cat or std.mem.eql(u8, a, "cat");
    try std.testing.expect(has_cat);
}
