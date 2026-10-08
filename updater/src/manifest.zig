//! `manifest.json` + `manifest.json.sig`: the signed description of a release.
//!
//! Trust chain: the Ed25519 public key compiled into the app verifies the
//! manifest signature; the manifest pins the size and SHA-256 of every
//! artifact. Nothing downloaded is trusted until it matches the manifest, and
//! the manifest is never parsed before its signature has been verified.
//!
//! Format (schema 1):
//! ```json
//! {
//!   "schema": 1,
//!   "product": "typebud",
//!   "version": "0.2.0",
//!   "channel": "stable",
//!   "artifacts": [
//!     { "platform": "macos-universal", "name": "typebud-macos-universal.zip",
//!       "size": 12345678, "sha256": "<64 lowercase hex>" }
//!   ]
//! }
//! ```
//! `manifest.json.sig` is the 64-byte Ed25519 signature, lowercase hex (128
//! characters, optional trailing newline), over `signing_context ++ manifest bytes`.

const std = @import("std");
const semver = @import("semver.zig");
const platform = @import("platform.zig");
const Ed25519 = std.crypto.sign.Ed25519;

pub const product_name = "typebud";
pub const schema_version = 1;
pub const manifest_asset_name = "manifest.json";
pub const signature_asset_name = "manifest.json.sig";
/// Domain separation: signatures made for typebud manifests can't be confused
/// with signatures over anything else, even if the key were ever reused.
pub const signing_context = "typebud-update-manifest-v1\n";
/// Upper bound on manifest size we'll download / parse.
pub const max_manifest_bytes = 64 * 1024;

pub const Channel = enum {
    stable,
    beta,

    /// Whether a release published on `release_channel` may be offered to a
    /// user subscribed to `self`.
    pub fn accepts(self: Channel, release_channel: Channel) bool {
        return switch (self) {
            .stable => release_channel == .stable,
            .beta => true,
        };
    }
};

pub const Artifact = struct {
    platform: []const u8,
    name: []const u8,
    size: u64,
    sha256: []const u8,

    pub fn digest(a: Artifact) [32]u8 {
        var out: [32]u8 = undefined;
        // Validated in `parse`.
        _ = std.fmt.hexToBytes(&out, a.sha256) catch unreachable;
        return out;
    }
};

pub const Manifest = struct {
    schema: u32,
    product: []const u8,
    version: []const u8,
    channel: Channel,
    artifacts: []const Artifact,
};

pub const VerifyError = error{ SignatureMalformed, SignatureInvalid, PublicKeyInvalid };

pub const ParseError = error{
    ManifestMalformed,
    ManifestWrongSchema,
    ManifestWrongProduct,
    ManifestBadVersion,
    ManifestBadArtifact,
    OutOfMemory,
};

pub const AcceptError = error{
    /// The signed version is not newer than what is running (downgrade or replay).
    NotNewer,
    /// The release's signed channel isn't one this install subscribes to.
    ChannelMismatch,
    /// The GitHub tag says one version, the signed manifest another.
    TagMismatch,
    /// A pre-release version number published on the stable channel.
    PrereleaseOnStable,
};

pub fn decodeSignature(sig_text: []const u8) VerifyError![Ed25519.Signature.encoded_length]u8 {
    const trimmed = std.mem.trim(u8, sig_text, " \t\r\n");
    if (trimmed.len != Ed25519.Signature.encoded_length * 2) return error.SignatureMalformed;
    var out: [Ed25519.Signature.encoded_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, trimmed) catch return error.SignatureMalformed;
    return out;
}

pub fn encodeSignature(sig: [Ed25519.Signature.encoded_length]u8) [Ed25519.Signature.encoded_length * 2]u8 {
    return std.fmt.bytesToHex(sig, .lower);
}

/// Verifies `sig_text` over `manifest_bytes` with `public_key`.
pub fn verifySignature(manifest_bytes: []const u8, sig_text: []const u8, public_key: [32]u8) VerifyError!void {
    const sig_bytes = try decodeSignature(sig_text);
    const pk = Ed25519.PublicKey.fromBytes(public_key) catch return error.PublicKeyInvalid;
    const sig = Ed25519.Signature.fromBytes(sig_bytes);
    var v = sig.verifier(pk) catch return error.SignatureInvalid;
    v.update(signing_context);
    v.update(manifest_bytes);
    v.verifyStrict() catch return error.SignatureInvalid;
}

/// Produces the hex signature for `manifest_bytes` (used by tools/sign.zig and
/// tests). Deterministic (RFC 8032) signing.
pub fn sign(gpa: std.mem.Allocator, manifest_bytes: []const u8, key_pair: Ed25519.KeyPair) ![Ed25519.Signature.encoded_length * 2]u8 {
    const msg = try std.mem.concat(gpa, u8, &.{ signing_context, manifest_bytes });
    defer gpa.free(msg);
    const sig = try key_pair.sign(msg, null);
    return encodeSignature(sig.toBytes());
}

const RawArtifact = struct {
    platform: []const u8,
    name: []const u8,
    size: u64,
    sha256: []const u8,
};

const RawManifest = struct {
    schema: u32,
    product: []const u8,
    version: []const u8,
    channel: []const u8,
    artifacts: []const RawArtifact,
};

/// Parses and validates manifest JSON. Only call on bytes whose signature has
/// already been verified (see `verifyAndParse`). Allocations go to `arena`.
pub fn parse(arena: std.mem.Allocator, bytes: []const u8) ParseError!Manifest {
    if (bytes.len > max_manifest_bytes) return error.ManifestMalformed;
    const raw = std.json.parseFromSliceLeaky(RawManifest, arena, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ManifestMalformed,
    };
    if (raw.schema != schema_version) return error.ManifestWrongSchema;
    if (!std.mem.eql(u8, raw.product, product_name)) return error.ManifestWrongProduct;
    const v = semver.parse(raw.version) catch return error.ManifestBadVersion;
    const channel = std.meta.stringToEnum(Channel, raw.channel) orelse return error.ManifestMalformed;
    _ = v;

    const artifacts = try arena.alloc(Artifact, raw.artifacts.len);
    for (raw.artifacts, 0..) |a, i| {
        const key = std.meta.stringToEnum(platform.PlatformKey, a.platform) orelse return error.ManifestBadArtifact;
        if (!std.mem.eql(u8, a.name, key.artifactName())) return error.ManifestBadArtifact;
        if (a.size == 0) return error.ManifestBadArtifact;
        if (a.sha256.len != 64) return error.ManifestBadArtifact;
        for (a.sha256) |c| switch (c) {
            '0'...'9', 'a'...'f' => {},
            else => return error.ManifestBadArtifact,
        };
        for (artifacts[0..i]) |prev| {
            if (std.mem.eql(u8, prev.platform, a.platform)) return error.ManifestBadArtifact;
        }
        artifacts[i] = .{ .platform = a.platform, .name = a.name, .size = a.size, .sha256 = a.sha256 };
    }
    return .{
        .schema = raw.schema,
        .product = raw.product,
        .version = std.mem.trim(u8, raw.version, " "),
        .channel = channel,
        .artifacts = artifacts,
    };
}

/// Verify-then-parse. The only entry point the updater uses for untrusted input.
pub fn verifyAndParse(
    arena: std.mem.Allocator,
    manifest_bytes: []const u8,
    sig_text: []const u8,
    public_key: [32]u8,
) (VerifyError || ParseError)!Manifest {
    try verifySignature(manifest_bytes, sig_text, public_key);
    return parse(arena, manifest_bytes);
}

pub const AcceptInput = struct {
    current_version: []const u8,
    channel: Channel,
    /// Version derived from the GitHub release tag, if known.
    tag_version: ?[]const u8 = null,
};

/// Policy checks on a verified manifest: refuse downgrades/replays, channel
/// confusion and tag/manifest disagreement.
pub fn checkAcceptable(m: Manifest, in: AcceptInput) (AcceptError || semver.ParseError)!void {
    const offered = try semver.parse(m.version);
    const current = try semver.parse(in.current_version);
    if (!in.channel.accepts(m.channel)) return error.ChannelMismatch;
    if (m.channel == .stable and semver.isPrerelease(offered)) return error.PrereleaseOnStable;
    if (in.tag_version) |t| {
        const tv = try semver.parse(t);
        if (tv.order(offered) != .eq) return error.TagMismatch;
    }
    if (!semver.isNewer(offered, current)) return error.NotNewer;
}

/// Picks the first artifact matching `prefs` (in preference order).
pub fn selectArtifact(m: Manifest, prefs: []const platform.PlatformKey) ?Artifact {
    for (prefs) |want| {
        for (m.artifacts) |a| {
            if (std.mem.eql(u8, a.platform, @tagName(want))) return a;
        }
    }
    return null;
}

/// Serializes a manifest (used by tools/mkmanifest.zig and tests).
pub fn write(w: *std.Io.Writer, m: Manifest) std.Io.Writer.Error!void {
    try w.print("{{\n  \"schema\": {d},\n  \"product\": \"{s}\",\n  \"version\": \"{s}\",\n  \"channel\": \"{s}\",\n  \"artifacts\": [", .{
        m.schema, m.product, m.version, @tagName(m.channel),
    });
    for (m.artifacts, 0..) |a, i| {
        try w.print("{s}\n    {{ \"platform\": \"{s}\", \"name\": \"{s}\", \"size\": {d}, \"sha256\": \"{s}\" }}", .{
            if (i == 0) "" else ",", a.platform, a.name, a.size, a.sha256,
        });
    }
    try w.writeAll("\n  ]\n}\n");
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const test_keys = @import("test_keys.zig");

const sample_manifest =
    \\{
    \\  "schema": 1,
    \\  "product": "typebud",
    \\  "version": "0.2.0",
    \\  "channel": "stable",
    \\  "released_at": "2026-10-01T00:00:00Z",
    \\  "artifacts": [
    \\    { "platform": "macos-universal", "name": "typebud-macos-universal.zip", "size": 100, "sha256": "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824" },
    \\    { "platform": "windows-x86_64", "name": "typebud-windows-x86_64.zip", "size": 200, "sha256": "486ea46224d1bb4fb680f34f7c9ad96a8f24ec88be73ea8e5a6c65260e9cb8a7" },
    \\    { "platform": "linux-x86_64-appimage", "name": "typebud-linux-x86_64.AppImage", "size": 300, "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
    \\    { "platform": "linux-x86_64-tarball", "name": "typebud-linux-x86_64.tar.gz", "size": 400, "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" }
    \\  ]
    \\}
;

test "parse sample manifest" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const m = try parse(arena.allocator(), sample_manifest);
    try testing.expectEqualStrings("0.2.0", m.version);
    try testing.expectEqual(Channel.stable, m.channel);
    try testing.expectEqual(@as(usize, 4), m.artifacts.len);
    try testing.expectEqual(@as(u64, 200), m.artifacts[1].size);
    const d = m.artifacts[0].digest();
    try testing.expectEqual(@as(u8, 0x2c), d[0]);
}

test "parse rejects malformed manifests" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.ManifestMalformed, parse(a, "not json"));
    try testing.expectError(error.ManifestMalformed, parse(a, "{}"));
    try testing.expectError(error.ManifestWrongSchema, parse(a,
        \\{"schema":2,"product":"typebud","version":"1.0.0","channel":"stable","artifacts":[]}
    ));
    try testing.expectError(error.ManifestWrongProduct, parse(a,
        \\{"schema":1,"product":"other","version":"1.0.0","channel":"stable","artifacts":[]}
    ));
    try testing.expectError(error.ManifestBadVersion, parse(a,
        \\{"schema":1,"product":"typebud","version":"one","channel":"stable","artifacts":[]}
    ));
    try testing.expectError(error.ManifestMalformed, parse(a,
        \\{"schema":1,"product":"typebud","version":"1.0.0","channel":"nightly","artifacts":[]}
    ));
    // name must match the platform key
    try testing.expectError(error.ManifestBadArtifact, parse(a,
        \\{"schema":1,"product":"typebud","version":"1.0.0","channel":"stable","artifacts":[
        \\ {"platform":"macos-universal","name":"evil.zip","size":1,"sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"}]}
    ));
    // bad digest
    try testing.expectError(error.ManifestBadArtifact, parse(a,
        \\{"schema":1,"product":"typebud","version":"1.0.0","channel":"stable","artifacts":[
        \\ {"platform":"macos-universal","name":"typebud-macos-universal.zip","size":1,"sha256":"E3B0"}]}
    ));
    // duplicate platform
    try testing.expectError(error.ManifestBadArtifact, parse(a,
        \\{"schema":1,"product":"typebud","version":"1.0.0","channel":"stable","artifacts":[
        \\ {"platform":"windows-x86_64","name":"typebud-windows-x86_64.zip","size":1,"sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},
        \\ {"platform":"windows-x86_64","name":"typebud-windows-x86_64.zip","size":2,"sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"}]}
    ));
}

test "write then parse round-trips" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const m = try parse(arena.allocator(), sample_manifest);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, m);
    const m2 = try parse(arena.allocator(), out.written());
    try testing.expectEqualStrings(m.version, m2.version);
    try testing.expectEqual(m.artifacts.len, m2.artifacts.len);
    try testing.expectEqualStrings(m.artifacts[3].sha256, m2.artifacts[3].sha256);
}

test "signature: good signature verifies" {
    const kp = try test_keys.keyPair();
    const sig = try sign(testing.allocator, sample_manifest, kp);
    try verifySignature(sample_manifest, &sig, test_keys.public_key);
    // trailing newline (as written by tools/sign) is fine
    try verifySignature(sample_manifest, &sig ++ "\n", test_keys.public_key);
}

test "signature: known test vector" {
    // Fixed vector so a change to the signing format is caught.
    try verifySignature(test_keys.vector_message, test_keys.vector_signature_hex, test_keys.public_key);
}

test "signature: tampered manifest is rejected" {
    const kp = try test_keys.keyPair();
    const sig = try sign(testing.allocator, sample_manifest, kp);
    var tampered: [sample_manifest.len]u8 = sample_manifest.*;
    const idx = std.mem.find(u8, &tampered, "\"size\": 100").?;
    tampered[idx + 8] = '9';
    try testing.expectError(error.SignatureInvalid, verifySignature(&tampered, &sig, test_keys.public_key));
}

test "signature: bad signatures are rejected" {
    const kp = try test_keys.keyPair();
    var sig = try sign(testing.allocator, sample_manifest, kp);
    // flipped bit in signature
    sig[10] = if (sig[10] == '0') '1' else '0';
    try testing.expectError(error.SignatureInvalid, verifySignature(sample_manifest, &sig, test_keys.public_key));
    // wrong length / not hex / empty
    const zz: [128]u8 = @splat('z');
    try testing.expectError(error.SignatureMalformed, verifySignature(sample_manifest, "abcd", test_keys.public_key));
    try testing.expectError(error.SignatureMalformed, verifySignature(sample_manifest, "", test_keys.public_key));
    try testing.expectError(error.SignatureMalformed, verifySignature(sample_manifest, &zz, test_keys.public_key));
    // signed by a different key
    const other = try Ed25519.KeyPair.generateDeterministic(@splat(7));
    const other_sig = try sign(testing.allocator, sample_manifest, other);
    try testing.expectError(error.SignatureInvalid, verifySignature(sample_manifest, &other_sig, test_keys.public_key));
    // signature without the domain-separation prefix
    const raw_sig = try kp.sign(sample_manifest, null);
    const raw_hex = encodeSignature(raw_sig.toBytes());
    try testing.expectError(error.SignatureInvalid, verifySignature(sample_manifest, &raw_hex, test_keys.public_key));
}

test "verifyAndParse never parses unsigned input" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // Garbage JSON with a bad signature must fail on the signature, not the parser.
    try testing.expectError(error.SignatureMalformed, verifyAndParse(arena.allocator(), "garbage", "", test_keys.public_key));
    const kp = try test_keys.keyPair();
    const sig = try sign(testing.allocator, sample_manifest, kp);
    const m = try verifyAndParse(arena.allocator(), sample_manifest, &sig, test_keys.public_key);
    try testing.expectEqualStrings("0.2.0", m.version);
}

test "downgrade and replay refusal" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const m = try parse(arena.allocator(), sample_manifest); // 0.2.0 stable
    try checkAcceptable(m, .{ .current_version = "0.1.0", .channel = .stable, .tag_version = "v0.2.0" });
    try testing.expectError(error.NotNewer, checkAcceptable(m, .{ .current_version = "0.2.0", .channel = .stable }));
    try testing.expectError(error.NotNewer, checkAcceptable(m, .{ .current_version = "0.3.0", .channel = .stable }));
    try testing.expectError(error.NotNewer, checkAcceptable(m, .{ .current_version = "0.2.1-beta.1", .channel = .beta }));
    // an old signed manifest re-attached to a newer tag
    try testing.expectError(error.TagMismatch, checkAcceptable(m, .{ .current_version = "0.1.0", .channel = .stable, .tag_version = "v9.0.0" }));
}

test "channel filtering on signed manifest" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const beta = try parse(arena.allocator(),
        \\{"schema":1,"product":"typebud","version":"0.3.0-beta.1","channel":"beta","artifacts":[]}
    );
    try testing.expectError(error.ChannelMismatch, checkAcceptable(beta, .{ .current_version = "0.2.0", .channel = .stable }));
    try checkAcceptable(beta, .{ .current_version = "0.2.0", .channel = .beta });
    const mislabeled = try parse(arena.allocator(),
        \\{"schema":1,"product":"typebud","version":"0.3.0-rc.1","channel":"stable","artifacts":[]}
    );
    try testing.expectError(error.PrereleaseOnStable, checkAcceptable(mislabeled, .{ .current_version = "0.2.0", .channel = .stable }));
    try testing.expect(Channel.beta.accepts(.stable));
    try testing.expect(!Channel.stable.accepts(.beta));
}

test "platform artifact selection from manifest" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const m = try parse(arena.allocator(), sample_manifest);
    const mac = selectArtifact(m, &.{.@"macos-universal"}).?;
    try testing.expectEqualStrings("typebud-macos-universal.zip", mac.name);
    // Windows on Arm falls back to x86_64 when no native build is published.
    const win = selectArtifact(m, &.{ .@"windows-aarch64", .@"windows-x86_64" }).?;
    try testing.expectEqualStrings("typebud-windows-x86_64.zip", win.name);
    const tar = selectArtifact(m, &.{.@"linux-x86_64-tarball"}).?;
    try testing.expectEqual(@as(u64, 400), tar.size);
    try testing.expect(selectArtifact(m, &.{.@"linux-aarch64-appimage"}) == null);
    try testing.expect(selectArtifact(m, &.{}) == null);
}
