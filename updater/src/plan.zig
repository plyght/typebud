//! File-swap plans and their executor.
//!
//! Applying an update is expressed as a list of `Step`s computed by pure
//! functions (`macSwapPlan`, `windowsReplacePlan`, ...), then run by `execute`
//! against a small `Fs` interface. The planners are unit-tested as pure
//! functions; the executor is tested on a real temp dir (and with injected
//! faults to check rollback) on any host.
//!
//! All paths in a plan are relative to one base directory (the directory that
//! contains the bundle / install dir / AppImage), so every rename stays on one
//! filesystem and is atomic.

const std = @import("std");

pub const Op = union(enum) {
    rename: struct { from: []const u8, to: []const u8 },
    delete_tree: []const u8,
    delete_file: []const u8,
    make_path: []const u8,

    pub fn format(op: Op, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (op) {
            .rename => |r| try w.print("rename {s} -> {s}", .{ r.from, r.to }),
            .delete_tree => |p| try w.print("delete_tree {s}", .{p}),
            .delete_file => |p| try w.print("delete_file {s}", .{p}),
            .make_path => |p| try w.print("make_path {s}", .{p}),
        }
    }
};

pub const Step = struct {
    op: Op,
    /// If false, failure is ignored (best-effort cleanup).
    critical: bool = true,
    /// Inverse operation used to roll back if a later critical step fails.
    undo: ?Op = null,
};

/// Minimal filesystem interface used by `execute`. Paths are relative to the
/// implementation's base directory. Missing paths must not be an error for
/// `deleteTree` / `deleteFile`.
pub const Fs = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        rename: *const fn (ctx: *anyopaque, from: []const u8, to: []const u8) anyerror!void,
        deleteTree: *const fn (ctx: *anyopaque, path: []const u8) anyerror!void,
        deleteFile: *const fn (ctx: *anyopaque, path: []const u8) anyerror!void,
        makePath: *const fn (ctx: *anyopaque, path: []const u8) anyerror!void,
    };

    pub fn run(fs: Fs, op: Op) anyerror!void {
        return switch (op) {
            .rename => |r| fs.vtable.rename(fs.ctx, r.from, r.to),
            .delete_tree => |p| fs.vtable.deleteTree(fs.ctx, p),
            .delete_file => |p| fs.vtable.deleteFile(fs.ctx, p),
            .make_path => |p| fs.vtable.makePath(fs.ctx, p),
        };
    }
};

/// `Fs` over a real directory.
pub const DirFs = struct {
    io: std.Io,
    dir: std.Io.Dir,

    pub fn fs(self: *DirFs) Fs {
        return .{ .ctx = self, .vtable = &.{
            .rename = rename,
            .deleteTree = deleteTree,
            .deleteFile = deleteFile,
            .makePath = makePath,
        } };
    }

    fn cast(ctx: *anyopaque) *DirFs {
        return @ptrCast(@alignCast(ctx));
    }
    fn rename(ctx: *anyopaque, from: []const u8, to: []const u8) anyerror!void {
        const s = cast(ctx);
        try s.dir.rename(from, s.dir, to, s.io);
    }
    fn deleteTree(ctx: *anyopaque, path: []const u8) anyerror!void {
        const s = cast(ctx);
        try s.dir.deleteTree(s.io, path);
    }
    fn deleteFile(ctx: *anyopaque, path: []const u8) anyerror!void {
        const s = cast(ctx);
        s.dir.deleteFile(s.io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
    fn makePath(ctx: *anyopaque, path: []const u8) anyerror!void {
        const s = cast(ctx);
        try s.dir.createDirPath(s.io, path);
    }
};

pub const ExecuteError = error{
    /// A critical step failed and every completed step was rolled back.
    ApplyFailed,
    /// A critical step failed AND rollback failed: the install may be broken.
    ApplyFailedRollbackFailed,
};

pub const ExecuteResult = struct {
    /// Index of the step that failed (if any) and its error.
    failed_step: ?usize = null,
    err: ?anyerror = null,
};

/// Runs `steps` in order. On the first failing critical step, runs the `undo`
/// of every completed critical step in reverse order.
pub fn execute(steps: []const Step, fs: Fs, result: ?*ExecuteResult) ExecuteError!void {
    for (steps, 0..) |step, i| {
        fs.run(step.op) catch |err| {
            if (!step.critical) continue;
            if (result) |r| r.* = .{ .failed_step = i, .err = err };
            var rollback_ok = true;
            var j = i;
            while (j > 0) {
                j -= 1;
                const prev = steps[j];
                if (!prev.critical) continue;
                if (prev.undo) |u| fs.run(u) catch {
                    rollback_ok = false;
                };
            }
            return if (rollback_ok) error.ApplyFailed else error.ApplyFailedRollbackFailed;
        };
    }
}

// ------------------------------------------------------------- planners

/// Atomically replace directory `target` with `staged` (macOS `.app` bundle,
/// Linux tarball install dir). `backup` must be an unused sibling name and
/// `staging_root` (if any) is removed afterwards.
///
///   1. rm -rf backup                 (best effort, leftovers from a crash)
///   2. mv target -> backup           (undo: mv backup -> target)
///   3. mv staged -> target           (undo: mv target -> staged)
///   4. rm -rf backup                 (best effort)
///   5. rm -rf staging_root           (best effort)
///
/// Between 2 and 3 the app is briefly absent; both are single rename(2) calls
/// on the same filesystem. The running process keeps its open files.
pub fn dirSwapPlan(buf: *[5]Step, target: []const u8, staged: []const u8, backup: []const u8, staging_root: ?[]const u8) []const Step {
    var n: usize = 0;
    buf[n] = .{ .op = .{ .delete_tree = backup }, .critical = false };
    n += 1;
    buf[n] = .{ .op = .{ .rename = .{ .from = target, .to = backup } }, .undo = .{ .rename = .{ .from = backup, .to = target } } };
    n += 1;
    buf[n] = .{ .op = .{ .rename = .{ .from = staged, .to = target } }, .undo = .{ .rename = .{ .from = target, .to = staged } } };
    n += 1;
    buf[n] = .{ .op = .{ .delete_tree = backup }, .critical = false };
    n += 1;
    if (staging_root) |s| {
        buf[n] = .{ .op = .{ .delete_tree = s }, .critical = false };
        n += 1;
    }
    return buf[0..n];
}

/// macOS: replace `<parent>/<bundle_name>` with `<parent>/<staging>/<staged_bundle>`.
pub const macSwapPlan = dirSwapPlan;

/// AppImage: `new_file` (already in the same directory, chmod +x) atomically
/// replaces `target` via a single rename. No backup is needed: rename(2)
/// replaces the directory entry atomically and the running AppImage keeps its
/// open inode.
pub fn appImagePlan(buf: *[1]Step, target: []const u8, new_file: []const u8) []const Step {
    buf[0] = .{ .op = .{ .rename = .{ .from = new_file, .to = target } } };
    return buf[0..1];
}

pub const windows_old_suffix = ".old";

/// Windows portable install: replace files in place. A running .exe (and
/// loaded DLLs) can't be overwritten or deleted but can be renamed, so each
/// existing file is first renamed to `<name>.old` (deleted on next start by
/// `windowsCleanupPlan`), then the new file is moved in from the staging dir.
///
/// `files` are paths relative to `staging` (forward slashes), `exists[i]`
/// says whether `files[i]` already exists in the install dir. Paths in the
/// returned plan are allocated from `arena`.
pub fn windowsReplacePlan(
    arena: std.mem.Allocator,
    staging: []const u8,
    files: []const []const u8,
    exists: []const bool,
) error{OutOfMemory}![]const Step {
    std.debug.assert(files.len == exists.len);
    var steps: std.ArrayList(Step) = .empty;
    for (files, exists) |f, ex| {
        const staged = try std.fmt.allocPrint(arena, "{s}/{s}", .{ staging, f });
        if (ex) {
            const old = try std.fmt.allocPrint(arena, "{s}" ++ windows_old_suffix, .{f});
            try steps.append(arena, .{ .op = .{ .delete_file = old }, .critical = false });
            try steps.append(arena, .{
                .op = .{ .rename = .{ .from = f, .to = old } },
                .undo = .{ .rename = .{ .from = old, .to = f } },
            });
        } else if (dirnameFwd(f)) |parent| {
            try steps.append(arena, .{ .op = .{ .make_path = parent } });
        }
        try steps.append(arena, .{
            .op = .{ .rename = .{ .from = staged, .to = f } },
            .undo = .{ .rename = .{ .from = f, .to = staged } },
        });
    }
    try steps.append(arena, .{ .op = .{ .delete_tree = staging }, .critical = false });
    return steps.items;
}

/// Next start after a Windows update: delete every `*.old` left behind.
/// `paths` are all files under the install dir (relative).
pub fn windowsCleanupPlan(arena: std.mem.Allocator, paths: []const []const u8) error{OutOfMemory}![]const Step {
    var steps: std.ArrayList(Step) = .empty;
    for (paths) |p| {
        if (std.mem.endsWith(u8, p, windows_old_suffix)) {
            try steps.append(arena, .{ .op = .{ .delete_file = p }, .critical = false });
        }
    }
    return steps.items;
}

fn dirnameFwd(p: []const u8) ?[]const u8 {
    const i = std.mem.findScalarLast(u8, p, '/') orelse return null;
    if (i == 0) return null;
    return p[0..i];
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const tio = testing.io;

fn expectOps(steps: []const Step, want: []const []const u8) !void {
    try testing.expectEqual(want.len, steps.len);
    for (steps, want) |s, w| {
        var buf: [256]u8 = undefined;
        const got = try std.fmt.bufPrint(&buf, "{f}{s}", .{ s.op, if (s.critical) "" else " (best-effort)" });
        try testing.expectEqualStrings(w, got);
    }
}

test "mac swap plan shape" {
    var buf: [5]Step = undefined;
    const steps = macSwapPlan(&buf, "Typebud.app", ".typebud-update-ab12/Typebud.app", ".Typebud.app.old-ab12", ".typebud-update-ab12");
    try expectOps(steps, &.{
        "delete_tree .Typebud.app.old-ab12 (best-effort)",
        "rename Typebud.app -> .Typebud.app.old-ab12",
        "rename .typebud-update-ab12/Typebud.app -> Typebud.app",
        "delete_tree .Typebud.app.old-ab12 (best-effort)",
        "delete_tree .typebud-update-ab12 (best-effort)",
    });
    try testing.expect(steps[1].undo != null and steps[2].undo != null);
}

test "windows rename plan shape" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const steps = try windowsReplacePlan(arena.allocator(), ".update", &.{ "typebud.exe", "data/new.bin", "data/sounds.pack" }, &.{ true, false, true });
    try expectOps(steps, &.{
        "delete_file typebud.exe.old (best-effort)",
        "rename typebud.exe -> typebud.exe.old",
        "rename .update/typebud.exe -> typebud.exe",
        "make_path data",
        "rename .update/data/new.bin -> data/new.bin",
        "delete_file data/sounds.pack.old (best-effort)",
        "rename data/sounds.pack -> data/sounds.pack.old",
        "rename .update/data/sounds.pack -> data/sounds.pack",
        "delete_tree .update (best-effort)",
    });
}

test "windows cleanup plan only touches .old files" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const steps = try windowsCleanupPlan(arena.allocator(), &.{ "typebud.exe", "typebud.exe.old", "data/a.old", "data/old", "golden.txt" });
    try expectOps(steps, &.{ "delete_file typebud.exe.old (best-effort)", "delete_file data/a.old (best-effort)" });
}

test "appimage plan is one atomic rename" {
    var buf: [1]Step = undefined;
    try expectOps(appImagePlan(&buf, "Typebud.AppImage", ".Typebud.AppImage.update"), &.{"rename .Typebud.AppImage.update -> Typebud.AppImage"});
}

fn writeFile(dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try dir.createDirPath(tio, d);
    try dir.writeFile(tio, .{ .sub_path = path, .data = data });
}

fn readFile(dir: std.Io.Dir, path: []const u8) ![]u8 {
    return dir.readFileAlloc(tio, path, testing.allocator, .limited(1 << 20));
}

fn expectFile(dir: std.Io.Dir, path: []const u8, want: []const u8) !void {
    const got = try readFile(dir, path);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

fn expectMissing(dir: std.Io.Dir, path: []const u8) !void {
    try testing.expectError(error.FileNotFound, dir.access(tio, path, .{}));
}

test "execute mac swap on a temp dir" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "Typebud.app/Contents/MacOS/typebud", "old");
    try writeFile(tmp.dir, ".stage/Typebud.app/Contents/MacOS/typebud", "new");
    var dfs: DirFs = .{ .io = tio, .dir = tmp.dir };
    var buf: [5]Step = undefined;
    try execute(macSwapPlan(&buf, "Typebud.app", ".stage/Typebud.app", ".Typebud.app.old", ".stage"), dfs.fs(), null);
    try expectFile(tmp.dir, "Typebud.app/Contents/MacOS/typebud", "new");
    try expectMissing(tmp.dir, ".Typebud.app.old");
    try expectMissing(tmp.dir, ".stage");
}

/// Wraps an Fs and fails the Nth operation.
const FaultyFs = struct {
    inner: Fs,
    fail_at: usize,
    count: usize = 0,

    fn fs(self: *FaultyFs) Fs {
        return .{ .ctx = self, .vtable = &.{ .rename = rename, .deleteTree = deleteTree, .deleteFile = deleteFile, .makePath = makePath } };
    }
    fn tick(ctx: *anyopaque) !*FaultyFs {
        const s: *FaultyFs = @ptrCast(@alignCast(ctx));
        defer s.count += 1;
        if (s.count == s.fail_at) return error.AccessDenied;
        return s;
    }
    fn rename(ctx: *anyopaque, a: []const u8, b: []const u8) anyerror!void {
        const s = try tick(ctx);
        return s.inner.vtable.rename(s.inner.ctx, a, b);
    }
    fn deleteTree(ctx: *anyopaque, p: []const u8) anyerror!void {
        const s = try tick(ctx);
        return s.inner.vtable.deleteTree(s.inner.ctx, p);
    }
    fn deleteFile(ctx: *anyopaque, p: []const u8) anyerror!void {
        const s = try tick(ctx);
        return s.inner.vtable.deleteFile(s.inner.ctx, p);
    }
    fn makePath(ctx: *anyopaque, p: []const u8) anyerror!void {
        const s = try tick(ctx);
        return s.inner.vtable.makePath(s.inner.ctx, p);
    }
};

test "mac swap rolls back when placing the new bundle fails" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "Typebud.app/Contents/MacOS/typebud", "old");
    try writeFile(tmp.dir, ".stage/Typebud.app/Contents/MacOS/typebud", "new");
    var dfs: DirFs = .{ .io = tio, .dir = tmp.dir };
    var faulty: FaultyFs = .{ .inner = dfs.fs(), .fail_at = 2 }; // step 3: mv staged -> target
    var buf: [5]Step = undefined;
    var res: ExecuteResult = .{};
    try testing.expectError(error.ApplyFailed, execute(macSwapPlan(&buf, "Typebud.app", ".stage/Typebud.app", ".Typebud.app.old", ".stage"), faulty.fs(), &res));
    try testing.expectEqual(@as(?usize, 2), res.failed_step);
    try expectFile(tmp.dir, "Typebud.app/Contents/MacOS/typebud", "old");
    try expectMissing(tmp.dir, ".Typebud.app.old");
}

test "best-effort failures don't abort" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "Typebud.app/x", "old");
    try writeFile(tmp.dir, ".stage/Typebud.app/x", "new");
    var dfs: DirFs = .{ .io = tio, .dir = tmp.dir };
    var faulty: FaultyFs = .{ .inner = dfs.fs(), .fail_at = 0 }; // initial backup cleanup
    var buf: [5]Step = undefined;
    try execute(macSwapPlan(&buf, "Typebud.app", ".stage/Typebud.app", ".Typebud.app.old", ".stage"), faulty.fs(), null);
    try expectFile(tmp.dir, "Typebud.app/x", "new");
}

test "execute windows replace plan on a temp dir, then cleanup" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "typebud.exe", "old-exe");
    try writeFile(tmp.dir, "data/sounds.pack", "old-sounds");
    try writeFile(tmp.dir, "user-settings.json", "keep me");
    try writeFile(tmp.dir, ".update/typebud.exe", "new-exe");
    try writeFile(tmp.dir, ".update/data/sounds.pack", "new-sounds");
    try writeFile(tmp.dir, ".update/data/new/extra.bin", "extra");

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const files: []const []const u8 = &.{ "typebud.exe", "data/sounds.pack", "data/new/extra.bin" };
    const steps = try windowsReplacePlan(arena.allocator(), ".update", files, &.{ true, true, false });
    var dfs: DirFs = .{ .io = tio, .dir = tmp.dir };
    try execute(steps, dfs.fs(), null);

    try expectFile(tmp.dir, "typebud.exe", "new-exe");
    try expectFile(tmp.dir, "typebud.exe.old", "old-exe");
    try expectFile(tmp.dir, "data/sounds.pack", "new-sounds");
    try expectFile(tmp.dir, "data/new/extra.bin", "extra");
    try expectFile(tmp.dir, "user-settings.json", "keep me");
    try expectMissing(tmp.dir, ".update");

    const cleanup = try windowsCleanupPlan(arena.allocator(), &.{ "typebud.exe", "typebud.exe.old", "data/sounds.pack.old", "user-settings.json" });
    try execute(cleanup, dfs.fs(), null);
    try expectMissing(tmp.dir, "typebud.exe.old");
    try expectMissing(tmp.dir, "data/sounds.pack.old");
    try expectFile(tmp.dir, "typebud.exe", "new-exe");
}

test "windows replace rolls back every file on failure" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "typebud.exe", "old-exe");
    try writeFile(tmp.dir, "a.dll", "old-dll");
    try writeFile(tmp.dir, ".update/typebud.exe", "new-exe");
    try writeFile(tmp.dir, ".update/a.dll", "new-dll");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const steps = try windowsReplacePlan(arena.allocator(), ".update", &.{ "typebud.exe", "a.dll" }, &.{ true, true });
    // ops: 0 del exe.old, 1 mv exe->old, 2 mv new exe, 3 del dll.old, 4 mv dll->old, 5 mv new dll (fail)
    var dfs: DirFs = .{ .io = tio, .dir = tmp.dir };
    var faulty: FaultyFs = .{ .inner = dfs.fs(), .fail_at = 5 };
    try testing.expectError(error.ApplyFailed, execute(steps, faulty.fs(), null));
    try expectFile(tmp.dir, "typebud.exe", "old-exe");
    try expectFile(tmp.dir, "a.dll", "old-dll");
    try expectFile(tmp.dir, ".update/typebud.exe", "new-exe");
    try expectMissing(tmp.dir, "typebud.exe.old");
}

test "appimage replace on a temp dir" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "Typebud.AppImage", "old");
    try writeFile(tmp.dir, ".Typebud.AppImage.update", "new");
    var dfs: DirFs = .{ .io = tio, .dir = tmp.dir };
    var buf: [1]Step = undefined;
    try execute(appImagePlan(&buf, "Typebud.AppImage", ".Typebud.AppImage.update"), dfs.fs(), null);
    try expectFile(tmp.dir, "Typebud.AppImage", "new");
    try expectMissing(tmp.dir, ".Typebud.AppImage.update");
}
