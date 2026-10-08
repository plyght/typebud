//! Per-platform install of a verified artifact, and relaunch.
//!
//! Every function here assumes the artifact has already been verified against
//! the signed manifest (size + SHA-256). The swap itself is a `plan.zig` plan
//! executed relative to the directory containing the install, so all renames
//! stay on one filesystem.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const plan = @import("plan.zig");
const platform = @import("platform.zig");

pub const Error = error{
    /// The install location isn't writable (or otherwise can't be replaced in place).
    NeedsManualUpdate,
    /// The archive doesn't have the layout we expect.
    ArchiveLayoutUnexpected,
    /// Extraction tool failed (macOS ditto).
    ExtractFailed,
    /// macOS: the new bundle's code signature doesn't verify.
    CodeSignatureInvalid,
    /// Swapping files failed; everything was rolled back.
    ApplyFailed,
    /// Swapping files failed and rollback failed too.
    ApplyFailedRollbackFailed,
};

/// Prefix of the staging directory we create next to the install.
pub const staging_prefix = ".typebud-update-";
/// Infix of the backup name for swapped directories: `.<name>.old-<suffix>`.
pub const backup_infix = ".old-";
/// Windows uses a fixed staging dir inside the install dir.
pub const windows_staging = ".typebud-update";
/// Argument passed to the relaunched process.
pub const relaunch_flag = "--typebud-updated-from=";

pub const Artifact = struct {
    /// Directory that holds the verified download, and its absolute path.
    dir: Io.Dir,
    dir_path: []const u8,
    name: []const u8,
};

fn isAccessError(err: anyerror) bool {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => true,
        else => false,
    };
}

fn mapExecute(err: plan.ExecuteError) Error {
    return switch (err) {
        error.ApplyFailed => error.ApplyFailed,
        error.ApplyFailedRollbackFailed => error.ApplyFailedRollbackFailed,
    };
}

/// Creates `<parent>/<name>` for staging, mapping permission errors to
/// `NeedsManualUpdate`.
fn createStaging(io: Io, parent: Io.Dir, name: []const u8) !void {
    parent.deleteTree(io, name) catch {};
    parent.createDir(io, name, .default_dir) catch |err| {
        if (isAccessError(err)) return error.NeedsManualUpdate;
        return err;
    };
}

fn openInstallParent(io: Io, path: []const u8) !Io.Dir {
    return Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch |err| {
        if (isAccessError(err)) return error.NeedsManualUpdate;
        return err;
    };
}

// ------------------------------------------------------------- extraction

pub fn extractZip(io: Io, src_dir: Io.Dir, src_name: []const u8, dest: Io.Dir) !void {
    const file = try src_dir.openFile(io, src_name, .{});
    defer file.close(io);
    var buf: [16 * 1024]u8 = undefined;
    var fr = file.reader(io, &buf);
    try std.zip.extract(dest, &fr, .{ .allow_backslashes = true });
}

pub fn extractTarGz(io: Io, src_dir: Io.Dir, src_name: []const u8, dest: Io.Dir) !void {
    const file = try src_dir.openFile(io, src_name, .{});
    defer file.close(io);
    var buf: [16 * 1024]u8 = undefined;
    var fr = file.reader(io, &buf);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var gz: std.compress.flate.Decompress = .init(&fr.interface, .gzip, &window);
    try std.tar.extract(io, dest, &gz.reader, .{ .mode_mode = .executable_bit_only });
}

/// Returns the single directory entry in `dir` whose name ends in `suffix`
/// (or any directory if `suffix` is empty), if there is exactly one entry.
fn singleSubdir(io: Io, dir: Io.Dir, buf: []u8, suffix: []const u8) !?[]const u8 {
    var it = dir.iterate();
    var found: ?[]const u8 = null;
    var count: usize = 0;
    while (try it.next(io)) |e| {
        count += 1;
        if (e.kind == .directory and std.mem.endsWith(u8, e.name, suffix)) {
            if (found != null) return null;
            @memcpy(buf[0..e.name.len], e.name);
            found = buf[0..e.name.len];
        }
    }
    if (suffix.len == 0 and count != 1) return null;
    return found;
}

// ------------------------------------------------------------------ macOS

pub fn applyMac(
    gpa: std.mem.Allocator,
    io: Io,
    art: Artifact,
    parent_path: []const u8,
    bundle_name: []const u8,
    suffix: []const u8,
) !void {
    var parent = try openInstallParent(io, parent_path);
    defer parent.close(io);

    var name_buf: [256]u8 = undefined;
    const staging = try std.fmt.bufPrint(&name_buf, staging_prefix ++ "{s}", .{suffix});
    try createStaging(io, parent, staging);
    var ok = false;
    defer if (!ok) parent.deleteTree(io, staging) catch {};

    const zip_path = try std.fs.path.join(gpa, &.{ art.dir_path, art.name });
    defer gpa.free(zip_path);
    const staging_abs = try std.fs.path.join(gpa, &.{ parent_path, staging });
    defer gpa.free(staging_abs);

    // ditto preserves extended attributes, symlinks inside frameworks and the
    // code signature's resource forks; unzip(1) and std.zip don't.
    try runTool(gpa, io, &.{ "/usr/bin/ditto", "-x", "-k", zip_path, staging_abs });

    var staged_dir = try parent.openDir(io, staging, .{ .iterate = true });
    var app_buf: [256]u8 = undefined;
    const app_name = (try singleSubdir(io, staged_dir, &app_buf, ".app")) orelse {
        staged_dir.close(io);
        return error.ArchiveLayoutUnexpected;
    };
    staged_dir.close(io);

    const staged_rel = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ staging, app_name });
    defer gpa.free(staged_rel);
    const staged_abs = try std.fs.path.join(gpa, &.{ staging_abs, app_name });
    defer gpa.free(staged_abs);

    {
        const plist = try std.fmt.allocPrint(gpa, "{s}/Contents/Info.plist", .{staged_rel});
        defer gpa.free(plist);
        parent.access(io, plist, .{}) catch return error.ArchiveLayoutUnexpected;
    }

    // We downloaded this ourselves over TLS and verified it against the signed
    // manifest, so drop any quarantine flag ditto may have carried over.
    runTool(gpa, io, &.{ "/usr/bin/xattr", "-dr", "com.apple.quarantine", staged_abs }) catch {};
    // A bundle with a broken code signature won't launch on Apple Silicon:
    // refuse to swap it in rather than leave the user with a dead app.
    runTool(gpa, io, &.{ "/usr/bin/codesign", "--verify", "--deep", "--strict", staged_abs }) catch
        return error.CodeSignatureInvalid;

    const backup = try std.fmt.allocPrint(gpa, ".{s}" ++ backup_infix ++ "{s}", .{ bundle_name, suffix });
    defer gpa.free(backup);

    var steps_buf: [5]plan.Step = undefined;
    const steps = plan.macSwapPlan(&steps_buf, bundle_name, staged_rel, backup, staging);
    var dfs: plan.DirFs = .{ .io = io, .dir = parent };
    var res: plan.ExecuteResult = .{};
    plan.execute(steps, dfs.fs(), &res) catch |err| {
        if (res.err) |e| if (isAccessError(e)) return error.NeedsManualUpdate;
        return mapExecute(err);
    };
    ok = true;
}

fn runTool(gpa: std.mem.Allocator, io: Io, argv: []const []const u8) !void {
    const r = std.process.run(gpa, io, .{ .argv = argv, .stdout_limit = .limited(1 << 20), .stderr_limit = .limited(1 << 20) }) catch
        return error.ExtractFailed;
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    if (!r.term.success()) {
        std.log.scoped(.updater).warn("{s} failed: {s}", .{ argv[0], r.stderr });
        return error.ExtractFailed;
    }
}

// ---------------------------------------------------------------- Windows

pub fn applyWindows(
    gpa: std.mem.Allocator,
    io: Io,
    art: Artifact,
    install_dir_path: []const u8,
    exe_name: []const u8,
) !void {
    var install = try openInstallParent(io, install_dir_path);
    defer install.close(io);
    try applyWindowsInDir(gpa, io, art, install, exe_name);
}

/// Separated from `applyWindows` so it can be tested on any host.
pub fn applyWindowsInDir(gpa: std.mem.Allocator, io: Io, art: Artifact, install: Io.Dir, exe_name: []const u8) !void {
    try createStaging(io, install, windows_staging);
    var ok = false;
    defer if (!ok) install.deleteTree(io, windows_staging) catch {};

    {
        var staging = try install.openDir(io, windows_staging, .{});
        defer staging.close(io);
        try extractZip(io, art.dir, art.name, staging);
    }

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Accept either files at the zip root or one top-level folder.
    var root: []const u8 = windows_staging;
    {
        var staging = try install.openDir(io, windows_staging, .{ .iterate = true });
        defer staging.close(io);
        staging.access(io, exe_name, .{}) catch {
            var b: [256]u8 = undefined;
            const sub = (try singleSubdir(io, staging, &b, "")) orelse return error.ArchiveLayoutUnexpected;
            root = try std.fmt.allocPrint(arena, "{s}/{s}", .{ windows_staging, sub });
        };
    }

    var files: std.ArrayList([]const u8) = .empty;
    var exists: std.ArrayList(bool) = .empty;
    var has_exe = false;
    {
        var root_dir = try install.openDir(io, root, .{ .iterate = true });
        defer root_dir.close(io);
        var walker = try root_dir.walk(arena);
        defer walker.deinit();
        while (try walker.next(io)) |e| {
            if (e.kind == .directory) continue;
            const rel = try arena.dupe(u8, e.path);
            std.mem.replaceScalar(u8, rel, '\\', '/');
            if (std.mem.eql(u8, rel, exe_name)) has_exe = true;
            try files.append(arena, rel);
            try exists.append(arena, if (install.access(io, rel, .{})) |_| true else |_| false);
        }
    }
    if (!has_exe) return error.ArchiveLayoutUnexpected;

    const steps = try plan.windowsReplacePlan(arena, root, files.items, exists.items);
    // When the zip had a top-level folder, the plan's final cleanup removes
    // only that folder; remove the staging root too.
    const all = try arena.alloc(plan.Step, steps.len + 1);
    @memcpy(all[0..steps.len], steps);
    all[steps.len] = .{ .op = .{ .delete_tree = windows_staging }, .critical = false };

    var dfs: plan.DirFs = .{ .io = io, .dir = install };
    var res: plan.ExecuteResult = .{};
    plan.execute(all, dfs.fs(), &res) catch |err| {
        if (res.err) |e| if (isAccessError(e)) return error.NeedsManualUpdate;
        return mapExecute(err);
    };
    ok = true;
}

// ------------------------------------------------------------------ Linux

pub fn applyAppImage(io: Io, art: Artifact, dir_path: []const u8, file_name: []const u8) !void {
    var dir = try openInstallParent(io, dir_path);
    defer dir.close(io);
    try applyAppImageInDir(io, art, dir, file_name);
}

pub fn applyAppImageInDir(io: Io, art: Artifact, dir: Io.Dir, file_name: []const u8) !void {
    var name_buf: [512]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&name_buf, ".{s}.update", .{file_name});
    const perms: Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o755);
    Io.Dir.copyFile(art.dir, art.name, dir, tmp, io, .{ .permissions = perms }) catch |err| {
        if (isAccessError(err)) return error.NeedsManualUpdate;
        return err;
    };
    var steps_buf: [1]plan.Step = undefined;
    var dfs: plan.DirFs = .{ .io = io, .dir = dir };
    plan.execute(plan.appImagePlan(&steps_buf, file_name, tmp), dfs.fs(), null) catch |err| {
        dir.deleteFile(io, tmp) catch {};
        return mapExecute(err);
    };
}

pub fn applyTarball(gpa: std.mem.Allocator, io: Io, art: Artifact, parent_path: []const u8, dir_name: []const u8, exe_name: []const u8, suffix: []const u8) !void {
    var parent = try openInstallParent(io, parent_path);
    defer parent.close(io);
    try applyTarballInDir(gpa, io, art, parent, dir_name, exe_name, suffix);
}

pub fn applyTarballInDir(gpa: std.mem.Allocator, io: Io, art: Artifact, parent: Io.Dir, dir_name: []const u8, exe_name: []const u8, suffix: []const u8) !void {
    var name_buf: [256]u8 = undefined;
    const staging = try std.fmt.bufPrint(&name_buf, staging_prefix ++ "{s}", .{suffix});
    try createStaging(io, parent, staging);
    var ok = false;
    defer if (!ok) parent.deleteTree(io, staging) catch {};

    {
        var sd = try parent.openDir(io, staging, .{});
        defer sd.close(io);
        try extractTarGz(io, art.dir, art.name, sd);
    }

    // The tarball holds one top-level directory (or the files directly).
    var staged: []const u8 = staging;
    var staged_buf: [600]u8 = undefined;
    {
        var sd = try parent.openDir(io, staging, .{ .iterate = true });
        defer sd.close(io);
        sd.access(io, platform.tarball_marker, .{}) catch {
            var b: [256]u8 = undefined;
            const sub = (try singleSubdir(io, sd, &b, "")) orelse return error.ArchiveLayoutUnexpected;
            staged = try std.fmt.bufPrint(&staged_buf, "{s}/{s}", .{ staging, sub });
        };
    }
    {
        var nd = try parent.openDir(io, staged, .{});
        defer nd.close(io);
        nd.access(io, platform.tarball_marker, .{}) catch return error.ArchiveLayoutUnexpected;
        nd.access(io, exe_name, .{}) catch return error.ArchiveLayoutUnexpected;
    }

    const backup = try std.fmt.allocPrint(gpa, ".{s}" ++ backup_infix ++ "{s}", .{ dir_name, suffix });
    defer gpa.free(backup);
    var steps_buf: [5]plan.Step = undefined;
    const same = std.mem.eql(u8, staged, staging);
    const steps = plan.dirSwapPlan(&steps_buf, dir_name, staged, backup, if (same) null else staging);
    var dfs: plan.DirFs = .{ .io = io, .dir = parent };
    var res: plan.ExecuteResult = .{};
    plan.execute(steps, dfs.fs(), &res) catch |err| {
        if (res.err) |e| if (isAccessError(e)) return error.NeedsManualUpdate;
        return mapExecute(err);
    };
    ok = true;
}

// ---------------------------------------------------------------- cleanup

/// Whether `name` (an entry in the directory that holds the install) is a
/// leftover from a previous update that can be deleted.
pub fn isLeftover(install: platform.Install, name: []const u8) bool {
    switch (install) {
        .mac_bundle => |m| return std.mem.startsWith(u8, name, staging_prefix) or isBackupOf(name, m.bundle_name),
        .linux_tarball => |t| return std.mem.startsWith(u8, name, staging_prefix) or isBackupOf(name, t.dir_name),
        .linux_appimage => |a| {
            return name.len == a.file_name.len + ".update".len + 1 and name[0] == '.' and
                std.mem.startsWith(u8, name[1..], a.file_name) and std.mem.endsWith(u8, name, ".update");
        },
        .windows_portable => return std.mem.endsWith(u8, name, plan.windows_old_suffix) or std.mem.eql(u8, name, windows_staging),
        else => return false,
    }
}

fn isBackupOf(name: []const u8, target: []const u8) bool {
    // .<target>.old-<suffix>
    if (name.len < 1 + target.len + backup_infix.len + 1) return false;
    return name[0] == '.' and std.mem.startsWith(u8, name[1..], target) and
        std.mem.startsWith(u8, name[1 + target.len ..], backup_infix);
}

/// Deletes leftovers of earlier updates (Windows `*.old`, staging dirs,
/// backups). Best effort; call once at startup.
pub fn cleanupLeftovers(gpa: std.mem.Allocator, io: Io, install: platform.Install) void {
    const dir_path = switch (install) {
        .mac_bundle => |m| m.parent_dir,
        .linux_tarball => |t| t.parent_dir,
        .linux_appimage => |a| a.dir,
        .windows_portable => |w| w.dir,
        else => return,
    };
    var dir = Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    if (install == .windows_portable) {
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var paths: std.ArrayList([]const u8) = .empty;
        var walker = dir.walk(arena) catch return;
        defer walker.deinit();
        while (walker.next(io) catch null) |e| {
            if (e.kind == .directory) continue;
            paths.append(arena, arena.dupe(u8, e.path) catch return) catch return;
        }
        const steps = plan.windowsCleanupPlan(arena, paths.items) catch return;
        var dfs: plan.DirFs = .{ .io = io, .dir = dir };
        plan.execute(steps, dfs.fs(), null) catch {};
        dir.deleteTree(io, windows_staging) catch {};
        return;
    }
    var it = dir.iterate();
    var names: [16][256]u8 = undefined;
    var lens: [16]usize = undefined;
    var n: usize = 0;
    while (it.next(io) catch null) |e| {
        if (n == names.len) break;
        if (e.name.len > 256 or !isLeftover(install, e.name)) continue;
        @memcpy(names[n][0..e.name.len], e.name);
        lens[n] = e.name.len;
        n += 1;
    }
    for (0..n) |i| dir.deleteTree(io, names[i][0..lens[i]]) catch {};
}

// --------------------------------------------------------------- relaunch

/// Starts the freshly installed copy. The caller must exit promptly after.
pub fn relaunch(io: Io, install: platform.Install, from_version: []const u8, path_buf: []u8) !void {
    var flag_buf: [96]u8 = undefined;
    const flag = try std.fmt.bufPrint(&flag_buf, relaunch_flag ++ "{s}", .{from_version});
    const sep = std.fs.path.sep_str;
    switch (install) {
        .mac_bundle => |m| {
            const bundle = try std.fmt.bufPrint(path_buf, "{s}/{s}", .{ m.parent_dir, m.bundle_name });
            // -n: open a new instance even though this one is still running.
            try spawnDetached(io, &.{ "/usr/bin/open", "-n", bundle, "--args", flag });
        },
        .windows_portable => |w| {
            const exe = try std.fmt.bufPrint(path_buf, "{s}" ++ sep ++ "{s}", .{ w.dir, w.exe_name });
            try spawnDetached(io, &.{ exe, flag });
        },
        .linux_appimage => |a| {
            const exe = try std.fmt.bufPrint(path_buf, "{s}/{s}", .{ a.dir, a.file_name });
            try spawnDetached(io, &.{ exe, flag });
        },
        .linux_tarball => |t| {
            const exe = try std.fmt.bufPrint(path_buf, "{s}/{s}/{s}", .{ t.parent_dir, t.dir_name, t.exe_name });
            try spawnDetached(io, &.{ exe, flag });
        },
        else => return error.NeedsManualUpdate,
    }
}

fn spawnDetached(io: Io, argv: []const []const u8) !void {
    _ = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = if (builtin.os.tag == .windows) null else 0,
    });
    // Intentionally not waited for: the new instance outlives us.
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const tio = testing.io;

fn expectFile(dir: Io.Dir, path: []const u8, want: []const u8) !void {
    const got = try dir.readFileAlloc(tio, path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

fn put(dir: Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try dir.createDirPath(tio, d);
    try dir.writeFile(tio, .{ .sub_path = path, .data = data });
}

test "windows apply from a real zip (temp dir)" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try put(tmp.dir, "cache/typebud-windows-x86_64.zip", @embedFile("testdata/windows-portable.zip"));
    try put(tmp.dir, "install/typebud.exe", "old-exe");
    try put(tmp.dir, "install/data/sounds.pack", "old-sounds");
    try put(tmp.dir, "install/settings.json", "mine");
    var cache = try tmp.dir.openDir(tio, "cache", .{});
    defer cache.close(tio);
    var install = try tmp.dir.openDir(tio, "install", .{ .iterate = true });
    defer install.close(tio);

    try applyWindowsInDir(testing.allocator, tio, .{ .dir = cache, .dir_path = "", .name = "typebud-windows-x86_64.zip" }, install, "typebud.exe");
    try expectFile(install, "typebud.exe", "new-exe");
    try expectFile(install, "typebud.exe.old", "old-exe");
    try expectFile(install, "data/sounds.pack", "new-sounds");
    try expectFile(install, "data/new/extra.bin", "extra");
    try expectFile(install, "settings.json", "mine");
    try testing.expectError(error.FileNotFound, install.access(tio, windows_staging, .{}));

    // next start
    try testing.expect(isLeftover(.{ .windows_portable = .{ .dir = "", .exe_name = "typebud.exe" } }, "typebud.exe.old"));
}

test "tarball apply swaps the install dir (temp dir)" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try put(tmp.dir, "cache/typebud-linux-x86_64.tar.gz", @embedFile("testdata/linux-tarball.tar.gz"));
    try put(tmp.dir, "opt/typebud/typebud", "old-bin");
    try put(tmp.dir, "opt/typebud/.typebud-install", "");
    try put(tmp.dir, "opt/unrelated.txt", "keep");
    var cache = try tmp.dir.openDir(tio, "cache", .{});
    defer cache.close(tio);
    var parent = try tmp.dir.openDir(tio, "opt", .{ .iterate = true });
    defer parent.close(tio);

    try applyTarballInDir(testing.allocator, tio, .{ .dir = cache, .dir_path = "", .name = "typebud-linux-x86_64.tar.gz" }, parent, "typebud", "typebud", "t1");
    try expectFile(parent, "typebud/typebud", "new-bin");
    try expectFile(parent, "typebud/share/typebud/a.txt", "asset");
    try expectFile(parent, "unrelated.txt", "keep");
    try testing.expectError(error.FileNotFound, parent.access(tio, ".typebud.old-t1", .{}));
    try testing.expectError(error.FileNotFound, parent.access(tio, staging_prefix ++ "t1", .{}));
    if (builtin.os.tag != .windows) {
        const st = try parent.statFile(tio, "typebud/typebud", .{});
        try testing.expect(st.permissions.toMode() & 0o100 != 0);
    }
}

test "appimage apply (temp dir)" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try put(tmp.dir, "cache/typebud-linux-x86_64.AppImage", "new-appimage");
    try put(tmp.dir, "apps/Typebud.AppImage", "old-appimage");
    var cache = try tmp.dir.openDir(tio, "cache", .{});
    defer cache.close(tio);
    var apps = try tmp.dir.openDir(tio, "apps", .{});
    defer apps.close(tio);
    try applyAppImageInDir(tio, .{ .dir = cache, .dir_path = "", .name = "typebud-linux-x86_64.AppImage" }, apps, "Typebud.AppImage");
    try expectFile(apps, "Typebud.AppImage", "new-appimage");
    try testing.expectError(error.FileNotFound, apps.access(tio, ".Typebud.AppImage.update", .{}));
    if (builtin.os.tag != .windows) {
        const st = try apps.statFile(tio, "Typebud.AppImage", .{});
        try testing.expect(st.permissions.toMode() & 0o111 == 0o111);
    }
}

test "corrupt tarball is refused and staging cleaned up" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // Build a tarball-like staging by using the windows zip as a bogus tar: extraction fails.
    try put(tmp.dir, "cache/bad.tar.gz", @embedFile("testdata/windows-portable.zip"));
    try put(tmp.dir, "opt/typebud/typebud", "old-bin");
    var cache = try tmp.dir.openDir(tio, "cache", .{});
    defer cache.close(tio);
    var parent = try tmp.dir.openDir(tio, "opt", .{ .iterate = true });
    defer parent.close(tio);
    try testing.expect(std.meta.isError(applyTarballInDir(testing.allocator, tio, .{ .dir = cache, .dir_path = "", .name = "bad.tar.gz" }, parent, "typebud", "typebud", "t2")));
    try expectFile(parent, "typebud/typebud", "old-bin");
    try testing.expectError(error.FileNotFound, parent.access(tio, staging_prefix ++ "t2", .{}));
}

test "leftover detection" {
    const mac: platform.Install = .{ .mac_bundle = .{ .parent_dir = "/Applications", .bundle_name = "Typebud.app" } };
    try testing.expect(isLeftover(mac, ".typebud-update-abcd"));
    try testing.expect(isLeftover(mac, ".Typebud.app.old-abcd"));
    try testing.expect(!isLeftover(mac, "Typebud.app"));
    try testing.expect(!isLeftover(mac, "Safari.app"));
    try testing.expect(!isLeftover(mac, ".Typebud.app.old-"));
    const ai: platform.Install = .{ .linux_appimage = .{ .dir = "/x", .file_name = "Typebud.AppImage" } };
    try testing.expect(isLeftover(ai, ".Typebud.AppImage.update"));
    try testing.expect(!isLeftover(ai, "Typebud.AppImage"));
    try testing.expect(!isLeftover(ai, ".Other.AppImage.update"));
    try testing.expect(!isLeftover(.managed_by_package_manager, ".typebud-update-x"));
}
