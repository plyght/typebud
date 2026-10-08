//! Platform identification, artifact selection and install-location detection.
//!
//! Everything here is a pure function of its inputs (OS tag, CPU arch, the
//! running executable's path and a couple of environment variables) so it can
//! be unit-tested on any host.

const std = @import("std");
const builtin = @import("builtin");

pub const Os = enum { macos, windows, linux };
pub const Arch = enum { x86_64, aarch64 };

pub const Host = struct {
    os: Os,
    arch: Arch,

    pub fn current() Host {
        return .{
            .os = switch (builtin.os.tag) {
                .macos => .macos,
                .windows => .windows,
                .linux => .linux,
                else => @compileError("typebud updater: unsupported OS"),
            },
            .arch = switch (builtin.cpu.arch) {
                .x86_64 => .x86_64,
                .aarch64 => .aarch64,
                else => @compileError("typebud updater: unsupported CPU architecture"),
            },
        };
    }
};

/// Platform keys used in `manifest.json` (`artifacts[].platform`).
/// Artifact file names are fixed by the release pipeline; see docs/UPDATES.md.
pub const PlatformKey = enum {
    @"macos-universal",
    @"windows-x86_64",
    @"windows-aarch64",
    @"linux-x86_64-appimage",
    @"linux-x86_64-tarball",
    @"linux-aarch64-appimage",
    @"linux-aarch64-tarball",

    pub fn artifactName(k: PlatformKey) []const u8 {
        return switch (k) {
            .@"macos-universal" => "typebud-macos-universal.zip",
            .@"windows-x86_64" => "typebud-windows-x86_64.zip",
            .@"windows-aarch64" => "typebud-windows-aarch64.zip",
            .@"linux-x86_64-appimage" => "typebud-linux-x86_64.AppImage",
            .@"linux-x86_64-tarball" => "typebud-linux-x86_64.tar.gz",
            .@"linux-aarch64-appimage" => "typebud-linux-aarch64.AppImage",
            .@"linux-aarch64-tarball" => "typebud-linux-aarch64.tar.gz",
        };
    }

    pub fn format(k: PlatformKey) ArchiveFormat {
        return switch (k) {
            .@"macos-universal", .@"windows-x86_64", .@"windows-aarch64" => .zip,
            .@"linux-x86_64-appimage", .@"linux-aarch64-appimage" => .appimage,
            .@"linux-x86_64-tarball", .@"linux-aarch64-tarball" => .tar_gz,
        };
    }

    /// Maps an artifact file name back to its platform key (used by tools/mkmanifest).
    pub fn fromArtifactName(name: []const u8) ?PlatformKey {
        inline for (@typeInfo(PlatformKey).@"enum".field_names) |f| {
            const k = @field(PlatformKey, f);
            if (std.mem.eql(u8, name, k.artifactName())) return k;
        }
        return null;
    }
};

pub const ArchiveFormat = enum { zip, tar_gz, appimage };

const PosixPath = struct {
    const dirname = std.fs.path.dirnamePosix;
    const basename = std.fs.path.basenamePosix;
    const isAbsolute = std.fs.path.isAbsolutePosix;
};
const WindowsPath = struct {
    const dirname = std.fs.path.dirnameWindows;
    const basename = std.fs.path.basenameWindows;
};

/// How the running copy of typebud is installed. Decides which artifact we
/// want and how (or whether) we can replace it.
pub const Install = union(enum) {
    /// `<parent_dir>/<bundle_name>` is the running `.app` bundle.
    mac_bundle: struct { parent_dir: []const u8, bundle_name: []const u8 },
    /// Portable per-user install; `dir` holds `exe_name` and its resources.
    windows_portable: struct { dir: []const u8, exe_name: []const u8 },
    /// `<dir>/<file_name>` is the AppImage (`$APPIMAGE`).
    linux_appimage: struct { dir: []const u8, file_name: []const u8 },
    /// `<parent_dir>/<dir_name>` is an extracted tarball (contains the marker file).
    linux_tarball: struct { parent_dir: []const u8, dir_name: []const u8, exe_name: []const u8 },
    /// Installed by a package manager (distro package, Flatpak, Snap, Nix, MS Store).
    managed_by_package_manager,
    /// We can't safely replace this copy; the string explains why (user-facing).
    needs_manual_update: []const u8,
};

/// Marker file shipped at the root of the Linux tarball. We only ever replace a
/// directory that contains it, so a binary copied into e.g. `~/bin` can never
/// cause us to swap out an unrelated directory.
pub const tarball_marker = ".typebud-install";

pub const DetectInput = struct {
    host: Host,
    /// Absolute path of the running executable (resolved, no symlinks).
    exe_path: []const u8,
    /// `$APPIMAGE` (set by the AppImage runtime), if any.
    appimage: ?[]const u8 = null,
    /// True if `$FLATPAK_ID` or `$SNAP` is set.
    sandboxed_package: bool = false,
    /// True if `tarball_marker` exists next to the executable (Linux only).
    has_tarball_marker: bool = false,
};

/// Pure install-kind detection. Returned slices borrow from `in`.
pub fn detectInstall(in: DetectInput) Install {
    switch (in.host.os) {
        .macos => return detectMac(in.exe_path),
        .windows => return detectWindows(in.exe_path),
        .linux => return detectLinux(in),
    }
}

fn detectMac(exe_path: []const u8) Install {
    // Expect <parent>/<Name>.app/Contents/MacOS/<exe>
    const p = PosixPath;
    const macos_dir = p.dirname(exe_path) orelse return .{ .needs_manual_update = "typebud is not running from an app bundle" };
    const contents_dir = p.dirname(macos_dir) orelse return .{ .needs_manual_update = "typebud is not running from an app bundle" };
    const bundle = p.dirname(contents_dir) orelse return .{ .needs_manual_update = "typebud is not running from an app bundle" };
    if (!std.mem.eql(u8, p.basename(macos_dir), "MacOS") or !std.mem.eql(u8, p.basename(contents_dir), "Contents") or
        !std.mem.endsWith(u8, bundle, ".app"))
    {
        return .{ .needs_manual_update = "typebud is not running from an app bundle" };
    }
    const parent = p.dirname(bundle) orelse return .{ .needs_manual_update = "typebud is not running from an app bundle" };
    if (std.mem.find(u8, bundle, "/AppTranslocation/") != null) {
        return .{ .needs_manual_update = "macOS is running typebud from a temporary location. Move Typebud to your Applications folder, then open it again." };
    }
    if (std.mem.startsWith(u8, bundle, "/Volumes/")) {
        return .{ .needs_manual_update = "typebud is running from a disk image or external volume. Copy it to your Applications folder first." };
    }
    if (std.mem.startsWith(u8, bundle, "/nix/store/") or std.mem.find(u8, bundle, "/Caskroom/") != null) {
        return .managed_by_package_manager;
    }
    return .{ .mac_bundle = .{ .parent_dir = parent, .bundle_name = p.basename(bundle) } };
}

fn detectWindows(exe_path: []const u8) Install {
    const p = WindowsPath;
    const dir = p.dirname(exe_path) orelse return .{ .needs_manual_update = "unable to determine install directory" };
    if (containsIgnoreCase(exe_path, "\\WindowsApps\\")) return .managed_by_package_manager;
    if (containsIgnoreCase(exe_path, "\\scoop\\apps\\") or containsIgnoreCase(exe_path, "\\chocolatey\\")) return .managed_by_package_manager;
    return .{ .windows_portable = .{ .dir = dir, .exe_name = p.basename(exe_path) } };
}

fn detectLinux(in: DetectInput) Install {
    const p = PosixPath;
    if (in.sandboxed_package) return .managed_by_package_manager;
    if (in.appimage) |ai| {
        if (ai.len > 0 and p.isAbsolute(ai)) {
            const dir = p.dirname(ai) orelse return .{ .needs_manual_update = "unable to determine AppImage location" };
            return .{ .linux_appimage = .{ .dir = dir, .file_name = p.basename(ai) } };
        }
    }
    const managed_prefixes = [_][]const u8{ "/usr/", "/nix/store/", "/gnu/store/", "/snap/", "/app/", "/var/lib/flatpak/" };
    for (managed_prefixes) |pre| {
        if (std.mem.startsWith(u8, in.exe_path, pre)) return .managed_by_package_manager;
    }
    const dir = p.dirname(in.exe_path) orelse return .{ .needs_manual_update = "unable to determine install directory" };
    if (!in.has_tarball_marker) {
        return .{ .needs_manual_update = "this copy of typebud was not installed from the official tarball or AppImage" };
    }
    const parent = p.dirname(dir) orelse return .{ .needs_manual_update = "typebud is installed at the filesystem root" };
    return .{ .linux_tarball = .{ .parent_dir = parent, .dir_name = p.basename(dir), .exe_name = p.basename(in.exe_path) } };
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

/// Platform keys we'd accept for this host/install, in order of preference.
/// Returns an empty slice for installs we don't self-update.
pub fn preferredArtifacts(host: Host, install: Install) []const PlatformKey {
    return switch (host.os) {
        .macos => &.{.@"macos-universal"},
        .windows => switch (host.arch) {
            // x86_64 builds run under emulation on Windows on Arm.
            .aarch64 => &.{ .@"windows-aarch64", .@"windows-x86_64" },
            .x86_64 => &.{.@"windows-x86_64"},
        },
        .linux => switch (install) {
            .linux_appimage => switch (host.arch) {
                .x86_64 => &.{.@"linux-x86_64-appimage"},
                .aarch64 => &.{.@"linux-aarch64-appimage"},
            },
            .linux_tarball => switch (host.arch) {
                .x86_64 => &.{.@"linux-x86_64-tarball"},
                .aarch64 => &.{.@"linux-aarch64-tarball"},
            },
            else => &.{},
        },
    };
}

const testing = std.testing;

test "artifact names round-trip" {
    inline for (@typeInfo(PlatformKey).@"enum".field_names) |f| {
        const k = @field(PlatformKey, f);
        try testing.expectEqual(k, PlatformKey.fromArtifactName(k.artifactName()).?);
    }
    try testing.expect(PlatformKey.fromArtifactName("manifest.json") == null);
    try testing.expectEqual(ArchiveFormat.zip, PlatformKey.@"macos-universal".format());
    try testing.expectEqual(ArchiveFormat.tar_gz, PlatformKey.@"linux-x86_64-tarball".format());
}

test "detect macOS bundle in /Applications and ~/Applications" {
    const host: Host = .{ .os = .macos, .arch = .aarch64 };
    const a = detectInstall(.{ .host = host, .exe_path = "/Applications/Typebud.app/Contents/MacOS/typebud" });
    try testing.expectEqualStrings("/Applications", a.mac_bundle.parent_dir);
    try testing.expectEqualStrings("Typebud.app", a.mac_bundle.bundle_name);
    const b = detectInstall(.{ .host = host, .exe_path = "/Users/me/Applications/Typebud.app/Contents/MacOS/typebud" });
    try testing.expectEqualStrings("/Users/me/Applications", b.mac_bundle.parent_dir);
}

test "detect macOS unsupported locations" {
    const host: Host = .{ .os = .macos, .arch = .x86_64 };
    try testing.expect(detectInstall(.{ .host = host, .exe_path = "/private/var/folders/xy/T/AppTranslocation/ABC/d/Typebud.app/Contents/MacOS/typebud" }) == .needs_manual_update);
    try testing.expect(detectInstall(.{ .host = host, .exe_path = "/Volumes/Typebud/Typebud.app/Contents/MacOS/typebud" }) == .needs_manual_update);
    try testing.expect(detectInstall(.{ .host = host, .exe_path = "/usr/local/bin/typebud" }) == .needs_manual_update);
    try testing.expect(detectInstall(.{ .host = host, .exe_path = "/opt/homebrew/Caskroom/typebud/1/Typebud.app/Contents/MacOS/typebud" }) == .managed_by_package_manager);
}

test "detect Windows installs" {
    const host: Host = .{ .os = .windows, .arch = .x86_64 };
    const a = detectInstall(.{ .host = host, .exe_path = "C:\\Users\\me\\AppData\\Local\\Programs\\typebud\\typebud.exe" });
    try testing.expectEqualStrings("C:\\Users\\me\\AppData\\Local\\Programs\\typebud", a.windows_portable.dir);
    try testing.expectEqualStrings("typebud.exe", a.windows_portable.exe_name);
    try testing.expect(detectInstall(.{ .host = host, .exe_path = "C:\\Program Files\\WindowsApps\\Typebud_1.0\\typebud.exe" }) == .managed_by_package_manager);
}

test "detect Linux installs" {
    const host: Host = .{ .os = .linux, .arch = .x86_64 };
    const ai = detectInstall(.{ .host = host, .exe_path = "/tmp/.mount_typebXYZ/usr/bin/typebud", .appimage = "/home/me/Apps/Typebud.AppImage" });
    try testing.expectEqualStrings("/home/me/Apps", ai.linux_appimage.dir);
    try testing.expectEqualStrings("Typebud.AppImage", ai.linux_appimage.file_name);

    try testing.expect(detectInstall(.{ .host = host, .exe_path = "/usr/bin/typebud" }) == .managed_by_package_manager);
    try testing.expect(detectInstall(.{ .host = host, .exe_path = "/usr/lib/typebud/typebud", .has_tarball_marker = true }) == .managed_by_package_manager);
    try testing.expect(detectInstall(.{ .host = host, .exe_path = "/home/me/typebud/typebud", .sandboxed_package = true }) == .managed_by_package_manager);
    try testing.expect(detectInstall(.{ .host = host, .exe_path = "/home/me/bin/typebud" }) == .needs_manual_update);

    const tb = detectInstall(.{ .host = host, .exe_path = "/home/me/.local/opt/typebud/typebud", .has_tarball_marker = true });
    try testing.expectEqualStrings("/home/me/.local/opt", tb.linux_tarball.parent_dir);
    try testing.expectEqualStrings("typebud", tb.linux_tarball.dir_name);
}

test "preferred artifacts per platform" {
    const mac: Host = .{ .os = .macos, .arch = .aarch64 };
    try testing.expectEqualSlices(PlatformKey, &.{.@"macos-universal"}, preferredArtifacts(mac, .{ .mac_bundle = .{ .parent_dir = "/Applications", .bundle_name = "Typebud.app" } }));
    const winarm: Host = .{ .os = .windows, .arch = .aarch64 };
    try testing.expectEqualSlices(PlatformKey, &.{ .@"windows-aarch64", .@"windows-x86_64" }, preferredArtifacts(winarm, .{ .windows_portable = .{ .dir = "C:\\x", .exe_name = "typebud.exe" } }));
    const lin: Host = .{ .os = .linux, .arch = .x86_64 };
    try testing.expectEqualSlices(PlatformKey, &.{.@"linux-x86_64-appimage"}, preferredArtifacts(lin, .{ .linux_appimage = .{ .dir = "/a", .file_name = "b" } }));
    try testing.expectEqualSlices(PlatformKey, &.{.@"linux-x86_64-tarball"}, preferredArtifacts(lin, .{ .linux_tarball = .{ .parent_dir = "/a", .dir_name = "b", .exe_name = "typebud" } }));
    try testing.expectEqual(@as(usize, 0), preferredArtifacts(lin, .managed_by_package_manager).len);
}
