const std = @import("std");

const cross_targets = [_][]const u8{
    "x86_64-windows-gnu",
    "aarch64-windows-gnu",
    "aarch64-macos",
    "x86_64-macos",
    "x86_64-linux-musl",
    "aarch64-linux-musl",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The module the app imports: `@import("updater")`.
    const mod = b.addModule("updater", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // typebud-update-check (CI smoke test / debugging).
    const cli = addTool(b, "typebud-update-check", "src/cli.zig", mod, target, optimize);
    b.installArtifact(cli);

    // Release tooling.
    const keygen = addTool(b, "typebud-keygen", "tools/keygen.zig", mod, target, optimize);
    const sign = addTool(b, "typebud-sign", "tools/sign.zig", mod, target, optimize);
    const mkmanifest = addTool(b, "typebud-mkmanifest", "tools/mkmanifest.zig", mod, target, optimize);
    b.installArtifact(keygen);
    b.installArtifact(sign);
    b.installArtifact(mkmanifest);

    const keygen_run = b.addRunArtifact(keygen);
    keygen_run.setCwd(b.path("."));
    keygen_run.addPassthruArgs();
    b.step("keygen", "Generate the release signing keypair (prints the private key; never writes it)").dependOn(&keygen_run.step);

    const check_run = b.addRunArtifact(cli);
    check_run.addPassthruArgs();
    b.step("check", "Run typebud-update-check (pass args after --)").dependOn(&check_run.step);

    // Tests.
    const test_step = b.step("test", "Run updater unit tests and the release-tooling round trip");
    const unit = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(unit).step);
    test_step.dependOn(&cli.step);
    test_step.dependOn(&keygen.step);
    addToolRoundTrip(b, test_step, mkmanifest, sign, cli);

    // Cross-compile the module and CLI for every shipped platform.
    const cross_step = b.step("cross", "Cross-compile the updater for all release targets");
    for (cross_targets) |triple| {
        const t = b.resolveTargetQuery(std.Target.Query.parse(.{ .arch_os_abi = triple }) catch unreachable);
        const m = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = t, .optimize = optimize });
        const tests = b.addTest(.{ .name = b.fmt("updater-test-{s}", .{triple}), .root_module = m });
        cross_step.dependOn(&tests.step);
        const c = addTool(b, b.fmt("typebud-update-check-{s}", .{triple}), "src/cli.zig", m, t, optimize);
        cross_step.dependOn(&c.step);
    }
}

fn addTool(
    b: *std.Build,
    name: []const u8,
    path: []const u8,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "updater", .module = mod }},
        }),
    });
}

/// mkmanifest -> sign (with the TEST key) -> typebud-update-check verify, on
/// fixture artifacts. Exercises the exact CI pipeline offline.
fn addToolRoundTrip(
    b: *std.Build,
    test_step: *std.Build.Step,
    mkmanifest: *std.Build.Step.Compile,
    sign: *std.Build.Step.Compile,
    cli: *std.Build.Step.Compile,
) void {
    const test_seed = "22b0406b9506c69fc6f0804be997a3fece0ef3b3b49e5c2e22e8ceccdceb4f45"; // src/test_keys.zig (TEST ONLY)
    const test_pub = "fb1d12a15e0f6d90f4ab2dfda78deee665b0d47276639977e9c29c8570c45f09";

    const wf = b.addWriteFiles();
    const tarball = wf.addCopyFile(b.path("src/testdata/linux-tarball.tar.gz"), "typebud-linux-x86_64.tar.gz");
    const zip = wf.addCopyFile(b.path("src/testdata/windows-portable.zip"), "typebud-windows-x86_64.zip");
    const appimage = wf.add("typebud-linux-x86_64.AppImage", "not really an AppImage\n");

    const mk = b.addRunArtifact(mkmanifest);
    mk.addArgs(&.{ "--version", "v1.2.3" });
    mk.addArg("-o");
    const manifest_json = mk.addOutputFileArg("manifest.json");
    mk.addFileArg(tarball);
    mk.addFileArg(zip);
    mk.addFileArg(appimage);
    mk.expectStdErrMatch("typebud 1.2.3 (stable), 3 artifacts");

    const sg = b.addRunArtifact(sign);
    sg.setEnvironmentVariable("TYPEBUD_UPDATE_SIGNING_KEY", test_seed);
    sg.addFileArg(manifest_json);
    sg.addArgs(&.{ "--expect-public-key", test_pub, "-o" });
    const sig = sg.addOutputFileArg("manifest.json.sig");
    sg.expectStdErrMatch("signed ");

    const vf = b.addRunArtifact(cli);
    vf.addArgs(&.{ "verify", "--public-key", test_pub, "--expect-version", "1.2.3", "--manifest" });
    vf.addFileArg(manifest_json);
    vf.addArg("--sig");
    vf.addFileArg(sig);
    vf.addArg("--artifacts");
    vf.addDirectoryArg(wf.getDirectory());
    vf.expectStdErrMatch("ok    typebud-windows-x86_64.zip");
    vf.expectExitCode(0);
    test_step.dependOn(&vf.step);

    // Signing with a key that doesn't match the pinned public key must fail.
    const bad = b.addRunArtifact(sign);
    bad.setEnvironmentVariable("TYPEBUD_UPDATE_SIGNING_KEY", "1111111111111111111111111111111111111111111111111111111111111111");
    bad.addFileArg(manifest_json);
    bad.addArgs(&.{ "--expect-public-key", test_pub, "-o" });
    _ = bad.addOutputFileArg("bad.sig");
    bad.expectStdErrMatch("does not match the public key embedded in the app");
    bad.expectExitCode(1);
    test_step.dependOn(&bad.step);

    // A manifest verified against the wrong key must be rejected.
    const wrong = b.addRunArtifact(cli);
    wrong.addArgs(&.{ "verify", "--public-key", "0dbb8d6e52b6f2c4f1a7d1c8a0f6d6b2c7b5a0e9f3d2c1b0a9f8e7d6c5b4a392", "--manifest" });
    wrong.addFileArg(manifest_json);
    wrong.addArg("--sig");
    wrong.addFileArg(sig);
    wrong.expectStdErrMatch("SignatureInvalid");
    wrong.expectExitCode(1);
    test_step.dependOn(&wrong.step);
}
