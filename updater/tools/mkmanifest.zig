//! Writes manifest.json for a set of release artifacts (run in CI).
//!
//!   mkmanifest --version 0.2.0 [--channel stable|beta] -o manifest.json FILE...
//!
//! Each FILE's basename must be one of the fixed artifact names (see
//! src/platform.zig); its size and SHA-256 are computed here.

const std = @import("std");
const updater = @import("updater");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var version: ?[]const u8 = null;
    var channel: ?updater.Channel = null;
    var out_path: []const u8 = "manifest.json";
    var files: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "--channel") or std.mem.eql(u8, a, "-o")) {
            i += 1;
            if (i >= args.len) return fail("{s} needs a value", .{a});
            const v = args[i];
            if (std.mem.eql(u8, a, "--version")) {
                version = std.mem.trimStart(u8, v, "v");
            } else if (std.mem.eql(u8, a, "--channel")) {
                channel = std.meta.stringToEnum(updater.Channel, v) orelse return fail("--channel must be stable or beta", .{});
            } else out_path = v;
        } else try files.append(arena, a);
    }
    const ver = version orelse return fail("--version is required", .{});
    const parsed = updater.semver.parse(ver) catch return fail("--version {s} is not semver", .{ver});
    const ch = channel orelse if (updater.semver.isPrerelease(parsed)) updater.Channel.beta else .stable;
    if (ch == .stable and updater.semver.isPrerelease(parsed)) return fail("pre-release version {s} can't go to the stable channel", .{ver});
    if (files.items.len == 0) return fail("no artifacts given", .{});

    const cwd = std.Io.Dir.cwd();
    var arts: std.ArrayList(updater.manifest.Artifact) = .empty;
    for (files.items) |path| {
        const name = std.fs.path.basename(path);
        const key = updater.platform.PlatformKey.fromArtifactName(name) orelse return fail("{s}: not a known artifact name", .{name});
        for (arts.items) |prev| if (std.mem.eql(u8, prev.platform, @tagName(key))) return fail("{s} given twice", .{name});
        const file = try cwd.openFile(io, path, .{});
        defer file.close(io);
        const size = try file.length(io);
        var buf: [64 * 1024]u8 = undefined;
        var fr = file.reader(io, &buf);
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        while (true) {
            const chunk = fr.interface.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => return fr.err.?,
            };
            h.update(chunk);
            fr.interface.toss(chunk.len);
        }
        const hex = std.fmt.bytesToHex(h.finalResult(), .lower);
        try arts.append(arena, .{ .platform = @tagName(key), .name = name, .size = size, .sha256 = try arena.dupe(u8, &hex) });
    }

    var out: std.Io.Writer.Allocating = .init(arena);
    try updater.manifest.write(&out.writer, .{
        .schema = updater.manifest.schema_version,
        .product = updater.manifest.product_name,
        .version = ver,
        .channel = ch,
        .artifacts = arts.items,
    });
    // Sanity: the app must be able to parse what we wrote.
    _ = updater.manifest.parse(arena, out.written()) catch |err| return fail("generated manifest doesn't parse: {t}", .{err});
    try cwd.writeFile(io, .{ .sub_path = out_path, .data = out.written() });
    std.debug.print("wrote {s}: typebud {s} ({t}), {d} artifacts\n", .{ out_path, ver, ch, arts.items.len });
    return 0;
}

fn fail(comptime fmt: []const u8, args: anytype) u8 {
    std.debug.print("mkmanifest: " ++ fmt ++ "\n", args);
    return 1;
}
