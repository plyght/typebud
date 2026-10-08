//! `zig build package` — platform bundles, laid out under the install prefix the way
//! .github/workflows/release.yml (and the updater) expect:
//!
//!   macOS    <prefix>/Typebud.app            Contents/{Info.plist, PkgInfo, MacOS/typebud,
//!                                            Resources/typebud.icns}; -Dmacos-exe=<path>
//!                                            packages a prebuilt (e.g. lipo'd universal)
//!                                            executable, -Duniversal=true lipos one here
//!   Windows  <prefix>/typebud/typebud.exe    portable (assets embedded, icon in the .exe);
//!            <prefix>/typebud-windows-<arch>.zip when a zip tool is available
//!   Linux    <prefix>/typebud-linux-<arch>/  typebud, typebud.desktop, typebud.png,
//!                                            .typebud-install (updater marker)
//!            <prefix>/AppDir/                AppRun, typebud.desktop, typebud.png, usr/...
//!            <prefix>/typebud-linux-<arch>.tar.gz
//!
//! Icons come from packaging/icons/ (generated from art/cat/icon.svg by `zig build icons`).

const std = @import("std");
const builtin = @import("builtin");

pub const bundle_id = "lol.peril.typebud";

pub const Options = struct {
    exe: *std.Build.Step.Compile,
    /// Optional second-architecture executable (macOS universal builds).
    other_exe: ?*std.Build.Step.Compile = null,
    target: std.Build.ResolvedTarget,
    version: []const u8,
};

pub fn addPackageStep(b: *std.Build, o: Options) void {
    const step = b.step("package", "Bundle the app for this target (Typebud.app / portable zip / tarball + AppDir)");
    const os = o.target.result.os.tag;
    const arch = @tagName(o.target.result.cpu.arch);
    switch (os) {
        .macos => macos(b, step, o),
        .windows => windows(b, step, o, arch),
        .linux => linux(b, step, o, arch),
        else => step.dependOn(&b.addFail("packaging is only defined for macOS, Windows and Linux").step),
    }
}

fn prefixPath() std.Build.LazyPath {
    return .{ .relative = .{ .base = .install_prefix } };
}

fn install(b: *std.Build, step: *std.Build.Step, src: std.Build.LazyPath, dest: []const u8) *std.Build.Step {
    const i = b.addInstallFileWithDir(src, .prefix, dest);
    step.dependOn(&i.step);
    return &i.step;
}

fn macos(b: *std.Build, step: *std.Build.Step, o: Options) void {
    const prebuilt = b.option([]const u8, "macos-exe", "Package this executable (e.g. a universal binary) instead of building one");
    const exe_src: std.Build.LazyPath = if (prebuilt) |p| .{ .cwd_relative = p } else if (o.other_exe) |other| blk: {
        const lipo = b.addSystemCommand(&.{ "lipo", "-create", "-output" });
        const out = lipo.addOutputFileArg("typebud");
        lipo.addArtifactArg(o.exe);
        lipo.addArtifactArg(other);
        break :blk out;
    } else o.exe.getEmittedBin();
    const wf = b.addWriteFiles();
    const plist = wf.add("Info.plist", b.fmt(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>CFBundleDevelopmentRegion</key><string>en</string>
        \\  <key>CFBundleDisplayName</key><string>Typebud</string>
        \\  <key>CFBundleExecutable</key><string>typebud</string>
        \\  <key>CFBundleIconFile</key><string>typebud</string>
        \\  <key>CFBundleIdentifier</key><string>{s}</string>
        \\  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
        \\  <key>CFBundleName</key><string>Typebud</string>
        \\  <key>CFBundlePackageType</key><string>APPL</string>
        \\  <key>CFBundleShortVersionString</key><string>{s}</string>
        \\  <key>CFBundleVersion</key><string>{s}</string>
        \\  <key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
        \\  <key>LSMinimumSystemVersion</key><string>12.0</string>
        \\  <key>LSUIElement</key><true/>
        \\  <key>NSHighResolutionCapable</key><true/>
        \\  <key>NSHumanReadableCopyright</key><string>typebud contributors</string>
        \\  <key>NSInputMonitoringUsageDescription</key><string>Precise typing detection (optional) lets typebud tell which side of the keyboard you type on. typebud never records what you type.</string>
        \\</dict>
        \\</plist>
        \\
    , .{ bundle_id, o.version, o.version }));
    const pkginfo = wf.add("PkgInfo", "APPL????");
    _ = install(b, step, exe_src, "Typebud.app/Contents/MacOS/typebud");
    _ = install(b, step, plist, "Typebud.app/Contents/Info.plist");
    _ = install(b, step, pkginfo, "Typebud.app/Contents/PkgInfo");
    _ = install(b, step, b.path("packaging/icons/typebud.icns"), "Typebud.app/Contents/Resources/typebud.icns");
}

fn windows(b: *std.Build, step: *std.Build.Step, o: Options, arch: []const u8) void {
    const exe_step = install(b, step, o.exe.getEmittedBin(), "typebud/typebud.exe");
    const zip_name = b.fmt("typebud-windows-{s}.zip", .{arch});
    if (builtin.os.tag == .windows) {
        const z = b.addSystemCommand(&.{ "tar", "-a", "-c", "-f", zip_name, "-C", "typebud", "typebud.exe" });
        z.setCwd(prefixPath());
        z.step.dependOn(exe_step);
        step.dependOn(&z.step);
    } else if (b.findProgram(.{ .names = &.{"zip"} })) |zip| {
        const z = b.addSystemCommand(&.{ zip, "-j", "-q", zip_name, b.fmt("typebud{c}typebud.exe", .{std.fs.path.sep}) });
        z.setCwd(prefixPath());
        z.step.dependOn(exe_step);
        step.dependOn(&z.step);
    }
}

fn linux(b: *std.Build, step: *std.Build.Step, o: Options, arch: []const u8) void {
    const root = b.fmt("typebud-linux-{s}", .{arch});
    const wf = b.addWriteFiles();
    const desktop = wf.add("typebud.desktop",
        \\[Desktop Entry]
        \\Type=Application
        \\Name=typebud
        \\GenericName=Typing Companion
        \\Comment=A cozy pet that types along with you
        \\Exec=typebud
        \\Icon=typebud
        \\Terminal=false
        \\Categories=Utility;Amusement;
        \\StartupWMClass=typebud
        \\X-GNOME-Autostart-enabled=true
        \\
    );
    const apprun = wf.add("AppRun",
        \\#!/bin/sh
        \\HERE="$(dirname "$(readlink -f "$0")")"
        \\exec "$HERE/usr/bin/typebud" "$@"
        \\
    );
    const marker = wf.add(".typebud-install", "typebud tarball install; the updater only replaces directories carrying this file.\n");
    const icon = b.path("packaging/icons/typebud-256.png");
    var deps: std.ArrayList(*std.Build.Step) = .empty;
    const add = struct {
        fn f(list: *std.ArrayList(*std.Build.Step), bb: *std.Build, s: *std.Build.Step) void {
            list.append(bb.allocator, s) catch @panic("OOM");
        }
    }.f;
    // Tarball root.
    add(&deps, b, install(b, step, o.exe.getEmittedBin(), b.fmt("{s}/typebud", .{root})));
    add(&deps, b, install(b, step, desktop, b.fmt("{s}/typebud.desktop", .{root})));
    add(&deps, b, install(b, step, icon, b.fmt("{s}/typebud.png", .{root})));
    add(&deps, b, install(b, step, marker, b.fmt("{s}/.typebud-install", .{root})));
    // AppDir (appimagetool AppDir typebud.AppImage).
    add(&deps, b, install(b, step, apprun, "AppDir/AppRun"));
    add(&deps, b, install(b, step, desktop, "AppDir/typebud.desktop"));
    add(&deps, b, install(b, step, icon, "AppDir/typebud.png"));
    add(&deps, b, install(b, step, o.exe.getEmittedBin(), "AppDir/usr/bin/typebud"));
    add(&deps, b, install(b, step, desktop, "AppDir/usr/share/applications/typebud.desktop"));
    add(&deps, b, install(b, step, icon, "AppDir/usr/share/icons/hicolor/256x256/apps/typebud.png"));
    // Executable bits (install steps copy the source mode; WriteFiles files are 0644).
    const chmod = b.addSystemCommand(&.{ "chmod", "755", "AppDir/AppRun", b.fmt("{s}/typebud", .{root}), "AppDir/usr/bin/typebud" });
    chmod.setCwd(prefixPath());
    for (deps.items) |d| chmod.step.dependOn(d);
    const tar = b.addSystemCommand(&.{ "tar", "-czf", b.fmt("{s}.tar.gz", .{root}), root });
    tar.setCwd(prefixPath());
    tar.step.dependOn(&chmod.step);
    step.dependOn(&tar.step);
}
