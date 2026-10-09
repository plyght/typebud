//! Signs a release manifest (run in CI).
//!
//!   TYPEBUD_UPDATE_SIGNING_KEY=<hex seed> sign manifest.json [-o manifest.json.sig]
//!
//! The private key is read from the environment (never from argv, so it
//! doesn't show up in process listings or logs). Before signing, the derived
//! public key is compared with the one the app is built with: `--expect-public-key
//! HEX` (CI passes the repository variable TYPEBUD_UPDATE_PUBLIC_KEY, the same value
//! the release builds get as -Dupdate-public-key), or else the key this tool was
//! built with (-Dpublic-key). If they differ, nothing is signed, because the app
//! would reject the release anyway.

const std = @import("std");
const updater = @import("updater");
const Ed25519 = std.crypto.sign.Ed25519;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var manifest_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var key_env: []const u8 = "TYPEBUD_UPDATE_SIGNING_KEY";
    var expect_hex: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "--key-env") or std.mem.eql(u8, a, "--expect-public-key")) {
            i += 1;
            if (i >= args.len) return fail("{s} needs a value", .{a});
            if (std.mem.eql(u8, a, "-o")) out_path = args[i] else if (std.mem.eql(u8, a, "--key-env")) key_env = args[i] else expect_hex = args[i];
        } else if (manifest_path == null and !std.mem.startsWith(u8, a, "-")) {
            manifest_path = a;
        } else return fail("usage: sign manifest.json [-o manifest.json.sig] [--key-env NAME] [--expect-public-key HEX]", .{});
    }
    const mpath = manifest_path orelse return fail("usage: sign manifest.json [-o manifest.json.sig]", .{});
    const opath = out_path orelse try std.fmt.allocPrint(arena, "{s}.sig", .{mpath});

    const secret = init.environ_map.get(key_env) orelse return fail("${s} is not set", .{key_env});
    const kp = parseKey(std.mem.trim(u8, secret, " \t\r\n")) catch
        return fail("${s} must be the 64-hex-character key printed by keygen", .{key_env});

    const pinned: [32]u8 = if (expect_hex) |h|
        updater.release_key.parseHex(h) orelse return fail("--expect-public-key: must be 64 hex characters", .{})
    else
        updater.release_key.public_key orelse
            return fail("no public key to check against: pass --expect-public-key HEX (the app's TYPEBUD_UPDATE_PUBLIC_KEY)", .{});
    if (!std.mem.eql(u8, &pinned, &kp.public_key.toBytes())) {
        const got = std.fmt.bytesToHex(kp.public_key.toBytes(), .lower);
        return fail("signing key does not match the public key embedded in the app (key's public half: {s})", .{&got});
    }

    const cwd = std.Io.Dir.cwd();
    const bytes = try cwd.readFileAlloc(io, mpath, arena, .limited(updater.manifest.max_manifest_bytes));
    const sig = try updater.manifest.sign(arena, bytes, kp);
    // Round-trip: the exact check the app performs.
    const m = updater.manifest.verifyAndParse(arena, bytes, &sig, pinned) catch |err|
        return fail("manifest does not verify/parse after signing: {t}", .{err});

    try cwd.writeFile(io, .{ .sub_path = opath, .data = &(sig ++ "\n".*) });
    std.debug.print("signed {s} (typebud {s}, {t}, {d} artifacts) -> {s}\n", .{ mpath, m.version, m.channel, m.artifacts.len, opath });
    return 0;
}

fn parseKey(hex: []const u8) !Ed25519.KeyPair {
    if (hex.len != 64 and hex.len != 128) return error.BadKey;
    var raw: [64]u8 = undefined;
    const bytes = try std.fmt.hexToBytes(&raw, hex);
    const kp = try Ed25519.KeyPair.generateDeterministic(bytes[0..32].*);
    if (bytes.len == 64 and !std.mem.eql(u8, bytes[32..64], &kp.public_key.toBytes())) return error.BadKey;
    return kp;
}

fn fail(comptime fmt: []const u8, args: anytype) u8 {
    std.debug.print("sign: " ++ fmt ++ "\n", args);
    return 1;
}
