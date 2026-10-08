//! Generates the Ed25519 keypair used to sign typebud release manifests.
//!
//!   zig build keygen                         # print both keys
//!   zig build keygen -- --write-public-key src/release_key.zig
//!
//! The public key is printed as a Zig literal for `src/release_key.zig` (and can
//! be written there directly with `--write-public-key`). The private key is
//! printed ONCE to stdout for you to paste into the GitHub Actions secret
//! `TYPEBUD_UPDATE_SIGNING_KEY`. This tool never writes the private key to disk.

const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var write_public_key_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--write-public-key")) {
            i += 1;
            if (i >= args.len) fatal("--write-public-key needs a path", .{});
            write_public_key_path = args[i];
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            std.debug.print("usage: keygen [--write-public-key path/to/release_key.zig]\n", .{});
            return;
        } else fatal("unknown argument: {s}", .{a});
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
        \\## Public key -> updater/src/release_key.zig (commit this)
        \\pub const public_key_hex = "{s}";
        \\
        \\## Private key -> GitHub repo secret TYPEBUD_UPDATE_SIGNING_KEY
        \\## Settings > Secrets and variables > Actions > New repository secret.
        \\## Store an offline backup (password manager). Do NOT commit it, paste it
        \\## anywhere else, or keep it in shell history. Losing it means shipping a
        \\## new app build with a new public key that users must install manually.
        \\{s}
        \\
    , .{ &pk_hex, &seed_hex });
    try out.flush();

    if (write_public_key_path) |p| {
        try writePublicKey(io, arena, p, &pk_hex);
        std.debug.print("updated public key in {s}\n", .{p});
    }
}

fn writePublicKey(io: std.Io, arena: std.mem.Allocator, path: []const u8, pk_hex: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const src = try cwd.readFileAlloc(io, path, arena, .limited(1 << 20));
    const marker = "pub const public_key_hex = \"";
    const start = (std.mem.find(u8, src, marker) orelse fatal("{s}: no `{s}` line found", .{ path, marker })) + marker.len;
    const end = std.mem.findScalarPos(u8, src, start, '"') orelse fatal("{s}: unterminated public_key_hex", .{path});
    const new = try std.mem.concat(arena, u8, &.{ src[0..start], pk_hex, src[end..] });
    try cwd.writeFile(io, .{ .sub_path = path, .data = new });
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("keygen: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}
