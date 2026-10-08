//! TEST-ONLY Ed25519 keypair and signature vector.
//!
//! !!! NEVER USE THIS KEY FOR RELEASES !!!
//! The private seed is published right here in the repository, so anything
//! signed with it is forgeable by anyone. It exists only so unit tests can
//! sign and verify manifests. The real release key lives in release_key.zig
//! (public half) and the TYPEBUD_UPDATE_SIGNING_KEY Actions secret (private).
//! tools/sign.zig refuses to sign with a key that doesn't match release_key.zig.

const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;

pub const seed_hex = "22b0406b9506c69fc6f0804be997a3fece0ef3b3b49e5c2e22e8ceccdceb4f45";
pub const public_key_hex = "fb1d12a15e0f6d90f4ab2dfda78deee665b0d47276639977e9c29c8570c45f09";

pub const public_key: [32]u8 = blk: {
    @setEvalBranchQuota(10_000);
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, public_key_hex) catch unreachable;
    break :blk out;
};

pub fn keyPair() !Ed25519.KeyPair {
    var seed: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&seed, seed_hex);
    return Ed25519.KeyPair.generateDeterministic(seed);
}

/// Message and its signature (over manifest.signing_context ++ message) made
/// with the test key. Pins the signature format.
pub const vector_message = "typebud test vector: do not ship\n";
pub const vector_signature_hex = "fdb772b8d8e0067c64fcafd9c472ed3669ca62860b200f98279d5f7c8c331fb38d359667f136624709e6445525621ea23842e499a928e45da5eb8cf7b2e30703";

test "test seed derives the test public key" {
    const kp = try keyPair();
    try std.testing.expectEqualSlices(u8, &public_key, &kp.public_key.toBytes());
}
