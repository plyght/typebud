//! typebud-update-check: exercises the updater from the command line (CI).
//!
//!   typebud-update-check verify --manifest manifest.json --sig manifest.json.sig
//!                        [--artifacts DIR] [--expect-version V] [--public-key HEX]
//!       Offline: verify the signature, parse the manifest and check every
//!       listed artifact in DIR against its size and SHA-256. Run in CI before
//!       publishing.
//!
//!   typebud-update-check check [--owner plyght] [--repo typebud] [--channel stable|beta]
//!                        [--current 0.0.0] [--expect-version V] [--platform KEY]
//!                        [--download] [--work-dir DIR] [--public-key HEX] [--token-env NAME]
//!       Online: run the same check the app runs against GitHub Releases; with
//!       --download also download and verify the artifact for --platform
//!       (default: the host's). Run in CI after publishing.
//!       --api-base / --download-base point it at a mock server (testing only).
//!
//! Exit status: 0 success, 1 failure, 2 usage error.

const std = @import("std");
const updater = @import("updater");
const Io = std.Io;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) return usage();

    var opts: Args = .{};
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const needs_value = !std.mem.eql(u8, a, "--download");
        const v: []const u8 = if (needs_value) blk: {
            i += 1;
            if (i >= args.len) {
                std.debug.print("{s} needs a value\n", .{a});
                return 2;
            }
            break :blk args[i];
        } else "";
        if (std.mem.eql(u8, a, "--manifest")) opts.manifest = v //
        else if (std.mem.eql(u8, a, "--sig")) opts.sig = v //
        else if (std.mem.eql(u8, a, "--artifacts")) opts.artifacts = v //
        else if (std.mem.eql(u8, a, "--expect-version")) opts.expect_version = std.mem.trimStart(u8, v, "v") //
        else if (std.mem.eql(u8, a, "--public-key")) opts.public_key_hex = v //
        else if (std.mem.eql(u8, a, "--owner")) opts.owner = v //
        else if (std.mem.eql(u8, a, "--repo")) opts.repo = v //
        else if (std.mem.eql(u8, a, "--channel")) opts.channel = std.meta.stringToEnum(updater.Channel, v) orelse return usage() //
        else if (std.mem.eql(u8, a, "--current")) opts.current = v //
        else if (std.mem.eql(u8, a, "--platform")) opts.platform = std.meta.stringToEnum(updater.platform.PlatformKey, v) orelse return usage() //
        else if (std.mem.eql(u8, a, "--work-dir")) opts.work_dir = v //
        else if (std.mem.eql(u8, a, "--token-env")) opts.token_env = v //
        else if (std.mem.eql(u8, a, "--api-base")) opts.api_base = v //
        else if (std.mem.eql(u8, a, "--download-base")) opts.download_base = v //
        else if (std.mem.eql(u8, a, "--download")) opts.download = true //
        else {
            std.debug.print("unknown argument: {s}\n", .{a});
            return 2;
        }
    }

    var pk: [32]u8 = updater.release_key.public_key;
    if (opts.public_key_hex) |h| {
        _ = std.fmt.hexToBytes(&pk, std.mem.trim(u8, h, " \r\n")) catch {
            std.debug.print("--public-key must be 64 hex characters\n", .{});
            return 2;
        };
    } else if (!updater.release_key.configured) {
        std.debug.print("release_key.zig still has the placeholder key; pass --public-key\n", .{});
        return 2;
    }

    if (std.mem.eql(u8, args[1], "verify")) return verify(io, arena, opts, pk);
    if (std.mem.eql(u8, args[1], "check")) return check(init, opts, pk);
    return usage();
}

const Args = struct {
    manifest: ?[]const u8 = null,
    sig: ?[]const u8 = null,
    artifacts: ?[]const u8 = null,
    expect_version: ?[]const u8 = null,
    public_key_hex: ?[]const u8 = null,
    owner: []const u8 = "plyght",
    repo: []const u8 = "typebud",
    channel: updater.Channel = .stable,
    current: []const u8 = "0.0.0",
    platform: ?updater.platform.PlatformKey = null,
    work_dir: []const u8 = ".typebud-update-check",
    token_env: ?[]const u8 = null,
    download: bool = false,
    api_base: []const u8 = updater.github.default_api_base,
    download_base: []const u8 = updater.github.default_download_base,
};

fn usage() u8 {
    std.debug.print(
        \\usage:
        \\  typebud-update-check verify --manifest FILE --sig FILE [--artifacts DIR] [--expect-version V] [--public-key HEX]
        \\  typebud-update-check check [--owner O] [--repo R] [--channel stable|beta] [--current V]
        \\                             [--expect-version V] [--platform KEY] [--download] [--work-dir DIR]
        \\                             [--public-key HEX] [--token-env NAME]
        \\
    , .{});
    return 2;
}

fn verify(io: Io, arena: std.mem.Allocator, a: Args, pk: [32]u8) !u8 {
    const cwd = Io.Dir.cwd();
    const man_path = a.manifest orelse return usage();
    const sig_path = a.sig orelse return usage();
    const man = try cwd.readFileAlloc(io, man_path, arena, .limited(updater.manifest.max_manifest_bytes));
    const sig = try cwd.readFileAlloc(io, sig_path, arena, .limited(1024));
    const m = updater.manifest.verifyAndParse(arena, man, sig, pk) catch |err| {
        std.debug.print("FAIL: manifest rejected: {t}\n", .{err});
        return 1;
    };
    std.debug.print("signature OK; typebud {s} ({t}), {d} artifacts\n", .{ m.version, m.channel, m.artifacts.len });
    if (a.expect_version) |want| {
        const ord = updater.semver.orderStrings(m.version, want) catch .lt;
        if (ord != .eq) {
            std.debug.print("FAIL: manifest version {s} != expected {s}\n", .{ m.version, want });
            return 1;
        }
    }
    if (a.artifacts) |dir_path| {
        var dir = try cwd.openDir(io, dir_path, .{});
        defer dir.close(io);
        var failed = false;
        for (m.artifacts) |art| {
            if (updater.verifyFile(io, dir, art.name, art.size, art.digest())) |_| {
                std.debug.print("  ok    {s} ({d} bytes)\n", .{ art.name, art.size });
            } else |err| {
                std.debug.print("  FAIL  {s}: {t}\n", .{ art.name, err });
                failed = true;
            }
        }
        if (failed) return 1;
    }
    return 0;
}

fn installFor(key: updater.platform.PlatformKey) struct { updater.platform.Host, updater.platform.Install } {
    const P = updater.platform;
    return switch (key) {
        .@"macos-universal" => .{ .{ .os = .macos, .arch = .aarch64 }, .{ .mac_bundle = .{ .parent_dir = "/Applications", .bundle_name = "Typebud.app" } } },
        .@"windows-x86_64" => .{ .{ .os = .windows, .arch = .x86_64 }, .{ .windows_portable = .{ .dir = "C:\\typebud", .exe_name = "typebud.exe" } } },
        .@"windows-aarch64" => .{ .{ .os = .windows, .arch = .aarch64 }, .{ .windows_portable = .{ .dir = "C:\\typebud", .exe_name = "typebud.exe" } } },
        .@"linux-x86_64-appimage" => .{ .{ .os = .linux, .arch = .x86_64 }, .{ .linux_appimage = .{ .dir = "/opt", .file_name = "Typebud.AppImage" } } },
        .@"linux-aarch64-appimage" => .{ .{ .os = .linux, .arch = .aarch64 }, .{ .linux_appimage = .{ .dir = "/opt", .file_name = "Typebud.AppImage" } } },
        .@"linux-x86_64-tarball" => .{ .{ .os = .linux, .arch = .x86_64 }, P.Install{ .linux_tarball = .{ .parent_dir = "/opt", .dir_name = "typebud", .exe_name = "typebud" } } },
        .@"linux-aarch64-tarball" => .{ .{ .os = .linux, .arch = .aarch64 }, P.Install{ .linux_tarball = .{ .parent_dir = "/opt", .dir_name = "typebud", .exe_name = "typebud" } } },
    };
}

fn check(init: std.process.Init, a: Args, pk: [32]u8) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const key: updater.platform.PlatformKey = a.platform orelse switch (updater.platform.Host.current().os) {
        .macos => .@"macos-universal",
        .windows => .@"windows-x86_64",
        .linux => .@"linux-x86_64-tarball",
    };
    const host, const install = installFor(key);
    const state_dir = try std.fs.path.join(arena, &.{ a.work_dir, "state" });
    const cache_dir = try std.fs.path.join(arena, &.{ a.work_dir, "cache" });
    const token: ?[]const u8 = if (a.token_env) |name| init.environ_map.get(name) else null;

    var u = try updater.Updater.init(gpa, io, .{
        .owner = a.owner,
        .repo = a.repo,
        .current_version = a.current,
        .channel = a.channel,
        .public_key = pk,
        .environ_map = init.environ_map,
        .state_dir = state_dir,
        .cache_dir = cache_dir,
        .exe_path = "/nonexistent/typebud",
        .github_token = token,
        .host_override = host,
        .install_override = install,
        .api_base = a.api_base,
        .download_base = a.download_base,
    });
    defer u.deinit();

    const status = u.check() catch |err| {
        std.debug.print("FAIL: check: {t}\n", .{err});
        return 1;
    };
    switch (status) {
        .up_to_date => {
            std.debug.print("up to date ({s} on {t})\n", .{ a.current, a.channel });
            if (a.expect_version != null) {
                std.debug.print("FAIL: expected {s} to be offered\n", .{a.expect_version.?});
                return 1;
            }
            return 0;
        },
        .available => |av| {
            std.debug.print("update available: {s} ({d} bytes for {t}){s}\n  {s}\n", .{
                av.version, av.size, key, if (av.prerelease) " [prerelease]" else "", av.release_url,
            });
            if (a.expect_version) |want| {
                const ord = updater.semver.orderStrings(av.version, want) catch .lt;
                if (ord != .eq) {
                    std.debug.print("FAIL: offered {s}, expected {s}\n", .{ av.version, want });
                    return 1;
                }
            }
            if (a.download) {
                u.downloadBlocking(.{ .func = progress }) catch |err| {
                    std.debug.print("\nFAIL: download: {t}\n", .{err});
                    return 1;
                };
                std.debug.print("\ndownloaded and verified (sha256 + size) into {s}\n", .{cache_dir});
            }
            return 0;
        },
    }
}

fn progress(_: ?*anyopaque, done: u64, total: u64) void {
    std.debug.print("\r  {d}/{d} bytes", .{ done, total });
}
