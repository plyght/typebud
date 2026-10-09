//! The Ed25519 public key that release manifests must be signed with.
//!
//! It is NOT in the source tree. It comes from the build: `-Dpublic-key=<64 hex>` on
//! this package (the app passes its own `-Dupdate-public-key=<hex>` through, and the
//! release workflow sets that from the repository variable
//! `TYPEBUD_UPDATE_PUBLIC_KEY`). The matching private key is the Actions secret
//! `TYPEBUD_UPDATE_SIGNING_KEY`; it is never committed or compiled in.
//!
//! Without a key (the default) `public_key` is null: the app runs without updates
//! (no network requests at all), `Updater.init` returns `error.UpdateKeyNotConfigured`,
//! and the tools need an explicit `--public-key` / `--expect-public-key`.

const options = @import("updater_build_options");

/// Lowercase hex as given to the build, or "" when the build has no key.
pub const public_key_hex: []const u8 = options.public_key_hex;

pub const configured: bool = public_key_hex.len != 0;

pub const public_key: ?[32]u8 = if (configured) decode(public_key_hex) else null;

/// Parses a 64-hex-character key (surrounding whitespace allowed). Null if malformed.
pub fn parseHex(hex: []const u8) ?[32]u8 {
    const t = std.mem.trim(u8, hex, " \t\r\n");
    if (t.len != 64) return null;
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, t) catch return null;
    return out;
}

const std = @import("std");

fn decode(comptime hex: []const u8) [32]u8 {
    @setEvalBranchQuota(10_000);
    if (hex.len != 64) @compileError("update public key must be 64 hex characters");
    var out: [32]u8 = undefined;
    for (&out, 0..) |*b, i| {
        b.* = (nibble(hex[2 * i]) << 4) | nibble(hex[2 * i + 1]);
    }
    return out;
}

fn nibble(comptime c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => @compileError("update public key: not a hex digit"),
    };
}

test parseHex {
    try std.testing.expect(parseHex("") == null);
    try std.testing.expect(parseHex("zz") == null);
    try std.testing.expect(parseHex("fb1d12a15e0f6d90f4ab2dfda78deee665b0d47276639977e9c29c8570c45f0g") == null);
    const k = parseHex(" fb1d12a15e0f6d90f4ab2dfda78deee665b0d47276639977e9c29c8570c45f09\n").?;
    try std.testing.expectEqual(@as(u8, 0xfb), k[0]);
}
