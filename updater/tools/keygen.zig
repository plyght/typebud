//! Generates the Ed25519 keypair used to sign typebud release manifests.
//!
//!   zig build keygen
//!
//! Prints both halves once, to stdout:
//!   * the PUBLIC key  -> GitHub repository *variable* TYPEBUD_UPDATE_PUBLIC_KEY.
//!     Not secret. Release builds compile it in (-Dupdate-public-key), which is
//!     what switches automatic updates on.
//!   * the PRIVATE key -> GitHub repository *secret* TYPEBUD_UPDATE_SIGNING_KEY,
//!     plus an offline backup. The release workflow signs manifest.json with it.
//! Nothing is written to disk and nothing in the repository changes.

const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            std.debug.print("usage: keygen   (prints a new keypair; writes nothing)\n", .{});
            return;
        }
        fatal("unknown argument: {s}", .{a});
    }

    const kp = Ed25519.KeyPair.generate(io);
    const seed = kp.secret_key.seed();
    const pk_hex = std.fmt.bytesToHex(kp.public_key.toBytes(), .lower);
    const seed_hex = std.fmt.bytesToHex(seed, .lower);

    var buf: [4096]u8 = undefined;
    var fw: std.Io.File.Writer = .init(.stdout(), io, &buf);
    const out = &fw.interface;

    try out.print(
        \\# typebud update signing keypair (Ed25519)
        \\
        \\## 1. PUBLIC key -> repository VARIABLE  TYPEBUD_UPDATE_PUBLIC_KEY
        \\##    GitHub > plyght/typebud > Settings > Secrets and variables > Actions > Variables
        \\##    (or: gh variable set TYPEBUD_UPDATE_PUBLIC_KEY --body <key>)
        \\##    Not secret. Release builds compile it in; that switches updates on.
        \\{s}
        \\
        \\## 2. PRIVATE key -> repository SECRET  TYPEBUD_UPDATE_SIGNING_KEY
        \\##    Settings > Secrets and variables > Actions > Secrets
        \\##    (or: gh secret set TYPEBUD_UPDATE_SIGNING_KEY, which prompts for it)
        \\##    Keep an offline backup (password manager). Never commit it or paste it
        \\##    anywhere else. Losing it means shipping a build with a new public key
        \\##    that every user has to install by hand.
        \\{s}
        \\
        \\## Then clear this terminal's scrollback.
        \\
    , .{ &pk_hex, &seed_hex });
    try out.flush();
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("keygen: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}
