//! typebud build.
//!
//!   zig build                      app → zig-out/bin/typebud
//!   zig build run [-- args]        run it
//!   zig build smoke                run `typebud --smoke` (screenshots → zig-out/smoke/)
//!   zig build test                 unit tests
//!   zig build package              Typebud.app (macOS) / zip (Windows) / tarball + .desktop (Linux)
//!   zig build check                compile-only check for -Dtarget (macOS / Windows from any host)
//!
//! zpui (github.com/plyght/zpui) is a path dependency at ./zpui: run scripts/fetch-zpui.sh
//! once (it clones the pinned commit), or symlink an existing checkout there.

const std = @import("std");
const builtin = @import("builtin");

pub const zpui_commit = "d2074cd04a456fa109b9f2a7acf5926a0ab32e7d";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = b.option([]const u8, "version", "App version (semver, default from build.zig.zon)") orelse "0.1.0";
    const os = target.result.os.tag;
    const host_os = builtin.os.tag;
    // macOS frameworks can only be linked on a Mac; elsewhere -Dtarget=*-macos builds an object.
    const mac_cross = os == .macos and host_os != .macos;
    const zpui_dep = b.dependency("zpui", .{ .target = target, .optimize = optimize });
    const zpui = zpui_dep.module("zpui");

    // ---- embedded assets ---------------------------------------------------------------
    const gen = b.addExecutable(.{ .name = "gen-assets", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/gen_assets.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    }) });
    const gen_run = b.addRunArtifact(gen);
    gen_run.addDirectoryArg(b.path("."));
    const asset_dir = gen_run.addOutputDirectoryArg("assets");
    // The walk reads whatever is in art/, sounds/ and assets/ now: always re-run (cheap);
    // unchanged output keeps the compile cached.
    gen_run.has_side_effects = true;
    const asset_index = b.createModule(.{ .root_source_file = asset_dir.path(b, "assets.zig") });

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    options.addOption([]const u8, "zpui_commit", zpui_commit);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = os != .windows or true,
        .imports = &.{
            .{ .name = "zpui", .module = zpui },
            .{ .name = "asset_index", .module = asset_index },
            .{ .name = "build_options", .module = options.createModule() },
        },
    });
    addCDecoders(b, mod);

    if (mac_cross) {
        // No SDK: compile to an object (CI links on a Mac).
        const obj = b.addObject(.{ .name = "typebud", .root_module = mod });
        const install = b.addInstallFile(obj.getEmittedBin(), "typebud.o");
        b.getInstallStep().dependOn(&install.step);
        b.step("check", "Compile typebud for -Dtarget (object only)").dependOn(&install.step);
        return;
    }

    const exe = b.addExecutable(.{ .name = "typebud", .root_module = mod });
    if (os == .windows) exe.subsystem = .windows;
    b.installArtifact(exe);
    b.step("check", "Compile typebud for -Dtarget").dependOn(&exe.step);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    run.setCwd(b.path("."));
    b.step("run", "Run typebud").dependOn(&run.step);

    const smoke = b.addRunArtifact(exe);
    smoke.addArg("--smoke");
    smoke.addPassthruArgs();
    smoke.setCwd(b.path("."));
    smoke.has_side_effects = true;
    b.step("smoke", "Run the scripted smoke test (screenshots in zig-out/smoke/)").dependOn(&smoke.step);

    // ---- tests --------------------------------------------------------------------------
    const test_filters = b.option([]const []const u8, "test-filter", "Only run tests whose names contain this") orelse &.{};
    const tests = b.addTest(.{ .name = "typebud-test", .root_module = mod, .filters = test_filters });
    const run_tests = b.addRunArtifact(tests);
    run_tests.setCwd(b.path("."));
    b.step("test", "Run typebud unit tests").dependOn(&run_tests.step);

    // ---- packaging ----------------------------------------------------------------------
    @import("packaging/package.zig").addPackageStep(b, .{
        .exe = exe,
        .target = target,
        .version = version,
        .zpui = zpui,
        .asset_index = asset_index,
    });
}

/// stb_vorbis (OGG) and minimp3 (MP3) for importing Mechvibes / Thock packs.
fn addCDecoders(b: *std.Build, mod: *std.Build.Module) void {
    mod.addIncludePath(b.path("third_party"));
    const flags: []const []const u8 = &.{ "-std=c99", "-O2", "-fno-sanitize=undefined", "-Wno-tautological-compare", "-Wno-tautological-pointer-compare" };
    mod.addCSourceFile(.{ .file = b.path("third_party/decoders.c"), .flags = flags });
    mod.addCSourceFile(.{ .file = b.path("third_party/decoders_mp3.c"), .flags = flags });
}
