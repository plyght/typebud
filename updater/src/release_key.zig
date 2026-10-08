//! The Ed25519 public key that release manifests must be signed with.
//!
//! This is the ONLY key the shipped app trusts. Replace `public_key_hex` with
//! the value printed by `zig build keygen` (see docs/UPDATES.md), and put the
//! matching private key in the GitHub Actions secret
//! `TYPEBUD_UPDATE_SIGNING_KEY`. The private key must never be committed.
//!
//! While this is all zeros, `Updater.init` returns `error.UpdateKeyNotConfigured`
//! and CI's `sign` step refuses to sign (so nothing can ship that the app can't
//! verify).

pub const public_key_hex = "0000000000000000000000000000000000000000000000000000000000000000";

pub const public_key: [32]u8 = decode(public_key_hex);

pub const configured: bool = !isZero(public_key);

fn decode(comptime hex: []const u8) [32]u8 {
    @setEvalBranchQuota(10_000);
    if (hex.len != 64) @compileError("release_key.public_key_hex must be 64 hex characters");
    var out: [32]u8 = undefined;
    for (&out, 0..) |*b, i| {
        b.* = (nibble(hex[2 * i]) << 4) | nibble(hex[2 * i + 1]);
    }
    return out;
}

fn nibble(c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => @compileError("release_key.public_key_hex: not a hex digit"),
    };
}

fn isZero(k: [32]u8) bool {
    for (k) |b| if (b != 0) return false;
    return true;
}
