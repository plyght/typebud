//! typebud over-the-air updater.
//!
//! ```zig
//! const updater = @import("updater");
//! var u = try updater.Updater.init(gpa, io, .{
//!     .current_version = "0.1.0",
//!     .channel = .stable,
//!     .public_key = updater.release_key.public_key,
//!     .environ_map = init.environ_map,
//! });
//! defer u.deinit();
//! u.cleanupAfterUpdate();                 // once at startup
//! switch (try u.check()) {                // or u.checkIfDue() from a timer
//!     .up_to_date => {},
//!     .available => |a| { ... a.version, a.notes, a.size, a.support ... },
//! }
//! try u.download(.{ .func = onProgress });  // background thread, resumable
//! try u.waitForDownload();                   // or poll u.downloadState()
//! if (try u.applyAndRelaunch() == .relaunched) app.quit();
//! // or: u.applyOnQuit(); ... at quit: u.onQuit();
//! ```
//!
//! See docs/UPDATES.md for the design and threat model.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const semver = @import("semver.zig");
pub const manifest = @import("manifest.zig");
pub const github = @import("github.zig");
pub const platform = @import("platform.zig");
pub const plan = @import("plan.zig");
pub const apply = @import("apply.zig");
pub const state = @import("state.zig");
pub const http = @import("http.zig");
pub const release_key = @import("release_key.zig");

pub const Channel = manifest.Channel;
pub const Progress = http.Progress;

pub const Options = struct {
    owner: []const u8 = "plyght",
    repo: []const u8 = "typebud",
    /// Version of the running app (semver, no leading `v`).
    current_version: []const u8,
    channel: Channel = .stable,
    /// Ed25519 public key that release manifests must be signed with. Use
    /// `release_key.public_key`.
    public_key: [32]u8,
    /// Process environment (`std.process.Init.environ_map`). Used for proxy
    /// settings, default directories and install detection (`$APPIMAGE`).
    environ_map: ?*const std.process.Environ.Map = null,
    /// Where `update-state.json` lives. Default: per-OS app state dir.
    state_dir: ?[]const u8 = null,
    /// Where downloads are kept until applied. Default: per-OS cache dir.
    cache_dir: ?[]const u8 = null,
    /// Override the running executable's path (tests / CLI).
    exe_path: ?[]const u8 = null,
    /// Optional GitHub token for API requests (CI only; never ship one).
    github_token: ?[]const u8 = null,
    /// Testing / CI: pretend to be this host and install instead of detecting.
    host_override: ?platform.Host = null,
    install_override: ?platform.Install = null,
    /// Testing only: alternative API / download origins (e.g. a local mock server).
    api_base: []const u8 = github.default_api_base,
    download_base: []const u8 = github.default_download_base,
};

pub const Support = union(enum) {
    /// We can download and install this update ourselves.
    automatic,
    /// We can't replace this copy in place; show the reason and a link to the release page.
    needs_manual_update: []const u8,
    /// Installed via a package manager; tell the user to update through it.
    managed_by_package_manager,
};

pub const Available = struct {
    version: []const u8,
    /// Release notes (Markdown, from the GitHub release body; display only).
    notes: []const u8,
    /// Download size in bytes for this platform (0 if no build for this platform).
    size: u64,
    /// GitHub release page.
    release_url: []const u8,
    prerelease: bool,
    support: Support,
};

/// Slices are valid until the next `check*` call or `deinit`.
pub const Status = union(enum) {
    up_to_date,
    available: Available,
};

pub const DownloadState = struct {
    phase: Phase,
    downloaded: u64 = 0,
    total: u64 = 0,
    /// Set when `phase == .failed`.
    err: ?anyerror = null,

    pub const Phase = enum { idle, running, ready, failed };
};

pub const ApplyResult = enum {
    /// Installed and the new version was started; exit now.
    relaunched,
    /// Installed; it'll run next time the app starts.
    installed,
};

pub const Error = error{
    UpdateKeyNotConfigured,
    StateDirUnknown,
    NoUpdateAvailable,
    NotSupportedForThisInstall,
    DownloadInProgress,
    DownloadNotReady,
    ChecksumMismatch,
    RateLimited,
    HttpStatus,
};

pub const Updater = struct {
    gpa: std.mem.Allocator,
    io: Io,
    opts: Options,
    owner_repo: []u8,
    user_agent: []u8,
    state_dir: []u8,
    cache_dir: []u8,
    exe_path: []u8,
    /// Data for the most recent check (Status slices point here).
    check_arena: std.heap.ArenaAllocator,
    install: platform.Install,
    host: platform.Host,
    pending: ?Pending = null,
    dl: ?*Download = null,
    apply_on_quit: bool = false,
    bg_check: ?std.Thread = null,

    const Pending = struct {
        version: []const u8,
        artifact: manifest.Artifact,
        url: []const u8,
    };

    pub fn init(gpa: std.mem.Allocator, io: Io, opts: Options) !Updater {
        if (std.mem.allEqual(u8, &opts.public_key, 0)) return error.UpdateKeyNotConfigured;
        _ = std.crypto.sign.Ed25519.PublicKey.fromBytes(opts.public_key) catch return error.UpdateKeyNotConfigured;
        _ = try semver.parse(opts.current_version);

        const owner_repo = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ opts.owner, opts.repo });
        errdefer gpa.free(owner_repo);
        const user_agent = try std.fmt.allocPrint(gpa, http.user_agent_prefix ++ "{s} ({s}; {s})", .{ opts.current_version, @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) });
        errdefer gpa.free(user_agent);
        const state_dir = if (opts.state_dir) |d| try gpa.dupe(u8, d) else try defaultDir(gpa, opts.environ_map, .state);
        errdefer gpa.free(state_dir);
        const cache_dir = if (opts.cache_dir) |d| try gpa.dupe(u8, d) else try defaultDir(gpa, opts.environ_map, .cache);
        errdefer gpa.free(cache_dir);
        const exe_path: []u8 = if (opts.exe_path) |p| try gpa.dupe(u8, p) else try std.process.executablePathAlloc(io, gpa);
        errdefer gpa.free(exe_path);

        var u: Updater = .{
            .gpa = gpa,
            .io = io,
            .opts = opts,
            .owner_repo = owner_repo,
            .user_agent = user_agent,
            .state_dir = state_dir,
            .cache_dir = cache_dir,
            .exe_path = exe_path,
            .check_arena = .init(gpa),
            .host = opts.host_override orelse .current(),
            .install = undefined,
        };
        u.install = opts.install_override orelse u.detect();
        return u;
    }

    pub fn deinit(u: *Updater) void {
        if (u.bg_check) |t| t.join();
        if (u.dl) |d| {
            d.cancel.store(true, .release);
            d.destroy();
        }
        u.check_arena.deinit();
        u.gpa.free(u.owner_repo);
        u.gpa.free(u.user_agent);
        u.gpa.free(u.state_dir);
        u.gpa.free(u.cache_dir);
        u.gpa.free(u.exe_path);
        u.* = undefined;
    }

    fn env(u: *const Updater, name: []const u8) ?[]const u8 {
        const m = u.opts.environ_map orelse return null;
        return m.get(name);
    }

    fn detect(u: *Updater) platform.Install {
        var has_marker = false;
        if (u.host.os == .linux) {
            if (std.fs.path.dirname(u.exe_path)) |d| {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                if (std.fmt.bufPrint(&buf, "{s}/{s}", .{ d, platform.tarball_marker })) |p| {
                    has_marker = if (Io.Dir.accessAbsolute(u.io, p, .{})) |_| true else |_| false;
                } else |_| {}
            }
        }
        return platform.detectInstall(.{
            .host = u.host,
            .exe_path = u.exe_path,
            .appimage = u.env("APPIMAGE"),
            .sandboxed_package = u.env("FLATPAK_ID") != null or u.env("SNAP") != null,
            .has_tarball_marker = has_marker,
        });
    }

    /// How this copy is installed (for the settings UI).
    pub fn support(u: *const Updater) Support {
        return switch (u.install) {
            .managed_by_package_manager => .managed_by_package_manager,
            .needs_manual_update => |r| .{ .needs_manual_update = r },
            else => .automatic,
        };
    }

    fn now(u: *const Updater) i64 {
        return Io.Clock.real.now(u.io).toSeconds();
    }

    fn openStateDir(u: *Updater) !Io.Dir {
        const cwd = Io.Dir.cwd();
        return cwd.createDirPathOpen(u.io, u.state_dir, .{});
    }

    /// True if an automatic check is due (cheap: reads one small file).
    pub fn isCheckDue(u: *Updater) bool {
        return u.msUntilNextCheck() == 0;
    }

    /// Milliseconds until the next automatic check is due (0 = now). Arm a
    /// one-shot timer with this; no updater thread runs in the meantime.
    pub fn msUntilNextCheck(u: *Updater) u64 {
        var arena: std.heap.ArenaAllocator = .init(u.gpa);
        defer arena.deinit();
        var dir = u.openStateDir() catch return 0;
        defer dir.close(u.io);
        const s = state.load(arena.allocator(), u.io, dir);
        return @intCast(@max(0, state.secondsUntilDue(s, u.now())) * std.time.ms_per_s);
    }

    /// Runs `check` only if the 6 h (+ jitter) schedule says so.
    pub fn checkIfDue(u: *Updater) !?Status {
        if (!u.isCheckDue()) return null;
        return try u.check();
    }

    /// Checks GitHub now (e.g. "Check for updates" in settings). Conditional
    /// request (ETag), so repeated checks are cheap and don't burn rate limit.
    /// Blocks for the network round trips. Not thread-safe; don't call while a
    /// download is running.
    pub fn check(u: *Updater) !Status {
        if (u.dl) |d| if (d.phase() == .running) return error.DownloadInProgress;
        _ = u.check_arena.reset(.retain_capacity);
        u.pending = null;
        const arena = u.check_arena.allocator();

        var dir = try u.openStateDir();
        defer dir.close(u.io);
        var st = state.load(arena, u.io, dir);
        const same_scope = std.mem.eql(u8, st.channel, @tagName(u.opts.channel)) and std.mem.eql(u8, st.repo, u.owner_repo);
        if (!same_scope) st = .{};

        var session: http.Session = undefined;
        try session.init(u.gpa, u.io, u.opts.environ_map, u.user_agent);
        defer session.deinit();
        var auth_buf: [256]u8 = undefined;
        if (u.opts.github_token) |t| session.authorization = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{t}) catch null;

        const t = u.now();
        var rnd: [8]u8 = undefined;
        u.io.random(&rnd);
        var new_state: state.State = .{
            .channel = @tagName(u.opts.channel),
            .repo = u.owner_repo,
            .etag = st.etag,
            .last_check = t,
            .next_check = state.nextCheck(t, std.mem.readInt(u64, &rnd, .little)),
            .candidate = st.candidate,
        };

        var url_buf: [512]u8 = undefined;
        const url = try github.releasesUrl(&url_buf, u.opts.api_base, u.opts.owner, u.opts.repo);
        const res = http.getConditional(&session, arena, url, if (st.etag.len > 0) st.etag else null, github.max_releases_bytes) catch |err| {
            // Record the attempt so a scheduled check doesn't retry in a tight
            // loop while offline; the user can still check manually.
            state.save(u.gpa, u.io, dir, new_state) catch {};
            return err;
        };
        switch (res.status) {
            .ok => {
                new_state.candidate = try github.selectRelease(arena, res.body, .{ .owner = u.opts.owner, .repo = u.opts.repo, .channel = u.opts.channel, .download_base = u.opts.download_base });
                new_state.etag = res.etag orelse "";
            },
            .not_modified => {},
            .forbidden, .too_many_requests => {
                state.save(u.gpa, u.io, dir, new_state) catch {};
                return error.RateLimited;
            },
            else => return error.HttpStatus,
        }
        state.save(u.gpa, u.io, dir, new_state) catch |err| std.log.scoped(.updater).warn("saving update state: {t}", .{err});

        const cand = new_state.candidate orelse return .up_to_date;
        const offered = semver.parse(cand.version) catch return .up_to_date;
        if (!semver.isNewer(offered, try semver.parse(u.opts.current_version))) return .up_to_date;

        // Something newer is advertised: fetch and verify its signed manifest.
        const man_bytes = try http.getSmall(&session, arena, cand.manifest_url, manifest.max_manifest_bytes);
        const sig_bytes = try http.getSmall(&session, arena, cand.signature_url, 1024);
        const m = try manifest.verifyAndParse(arena, man_bytes, sig_bytes, u.opts.public_key);
        manifest.checkAcceptable(m, .{
            .current_version = u.opts.current_version,
            .channel = u.opts.channel,
            .tag_version = cand.version,
        }) catch |err| switch (err) {
            error.NotNewer => return .up_to_date,
            else => return err,
        };

        var sup = u.support();
        var size: u64 = 0;
        const prefs = platform.preferredArtifacts(u.host, u.install);
        if (manifest.selectArtifact(m, prefs)) |art| {
            size = art.size;
            if (sup == .automatic) {
                if (cand.assetUrl(art.name)) |asset_url| {
                    u.pending = .{ .version = m.version, .artifact = art, .url = asset_url };
                } else sup = .{ .needs_manual_update = "the release is missing the download for this platform" };
            }
        } else if (sup == .automatic) {
            sup = .{ .needs_manual_update = "this release has no build for your platform" };
        }

        return .{ .available = .{
            .version = m.version,
            .notes = cand.notes,
            .size = size,
            .release_url = cand.html_url,
            .prerelease = cand.prerelease,
            .support = sup,
        } };
    }

    /// Runs `check` on a short-lived thread and calls `cb` with the result on
    /// that thread. `u` must not move until the callback has run (or `deinit`).
    pub fn checkInBackground(u: *Updater, ctx: ?*anyopaque, cb: *const fn (ctx: ?*anyopaque, result: anyerror!Status) void) !void {
        if (u.bg_check) |t| t.join();
        u.bg_check = try std.Thread.spawn(.{}, struct {
            fn run(self: *Updater, c: ?*anyopaque, f: *const fn (?*anyopaque, anyerror!Status) void) void {
                f(c, self.check());
            }
        }.run, .{ u, ctx, cb });
    }

    // ------------------------------------------------------------ download

    /// Starts downloading the update found by the last `check` on a
    /// background thread (which exits when done). Resumes a previous partial
    /// download. `progress.func` is called on that thread.
    pub fn download(u: *Updater, progress: Progress) !void {
        const p = u.pending orelse return error.NoUpdateAvailable;
        if (u.support() != .automatic) return error.NotSupportedForThisInstall;
        if (u.dl) |d| {
            if (d.phase() == .running) return error.DownloadInProgress;
            d.destroy();
            u.dl = null;
        }
        const d = try Download.create(u, p, progress);
        errdefer d.destroy();
        d.thread = try std.Thread.spawn(.{}, Download.run, .{d});
        u.dl = d;
    }

    /// `download` + `waitForDownload` (blocks the caller; for CLIs/tests).
    pub fn downloadBlocking(u: *Updater, progress: Progress) !void {
        try u.download(progress);
        try u.waitForDownload();
    }

    pub fn downloadState(u: *const Updater) DownloadState {
        const d = u.dl orelse return .{ .phase = .idle };
        return .{
            .phase = d.phase(),
            .downloaded = d.downloaded.load(.monotonic),
            .total = d.artifact.size,
            .err = if (d.phase() == .failed) d.err else null,
        };
    }

    /// Blocks until the background download finishes; returns its error.
    pub fn waitForDownload(u: *Updater) !void {
        const d = u.dl orelse return error.DownloadNotReady;
        if (d.thread) |t| {
            t.join();
            d.thread = null;
        }
        if (d.err) |e| return e;
    }

    pub fn cancelDownload(u: *Updater) void {
        const d = u.dl orelse return;
        d.cancel.store(true, .release);
        if (d.thread) |t| {
            t.join();
            d.thread = null;
        }
    }

    // --------------------------------------------------------------- apply

    /// Installs the downloaded update and starts the new version. On
    /// `.relaunched` the caller must exit right away (the new instance is
    /// starting). On error nothing was changed (or everything was rolled back).
    pub fn applyAndRelaunch(u: *Updater) !ApplyResult {
        try u.installDownloaded();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        apply.relaunch(u.io, u.install, u.opts.current_version, &buf) catch |err| {
            std.log.scoped(.updater).warn("update installed but relaunch failed: {t}", .{err});
            return .installed;
        };
        return .relaunched;
    }

    /// Install the downloaded update when the app quits (call `onQuit` from
    /// the quit path).
    pub fn applyOnQuit(u: *Updater) void {
        u.apply_on_quit = true;
    }

    /// Call when the app is quitting. Installs a pending update (if
    /// `applyOnQuit` was requested and the download is ready); never relaunches.
    pub fn onQuit(u: *Updater) void {
        if (!u.apply_on_quit) return;
        const d = u.dl orelse return;
        if (d.phase() != .ready) return;
        u.installDownloaded() catch |err| std.log.scoped(.updater).warn("installing update on quit failed: {t}", .{err});
    }

    fn installDownloaded(u: *Updater) !void {
        const d = u.dl orelse return error.DownloadNotReady;
        try u.waitForDownload();
        if (d.phase() != .ready) return error.DownloadNotReady;

        var dir = try Io.Dir.cwd().openDir(u.io, d.dir_path, .{});
        defer dir.close(u.io);
        // Re-verify right before installing (the file sat on disk meanwhile).
        try verifyFile(u.io, dir, d.artifact.name, d.artifact.size, d.artifact.digest());

        var rnd: [6]u8 = undefined;
        u.io.random(&rnd);
        const suffix = std.fmt.bytesToHex(rnd, .lower);
        const art: apply.Artifact = .{ .dir = dir, .dir_path = d.dir_path, .name = d.artifact.name };
        switch (u.install) {
            .mac_bundle => |m| try apply.applyMac(u.gpa, u.io, art, m.parent_dir, m.bundle_name, &suffix),
            .windows_portable => |w| try apply.applyWindows(u.gpa, u.io, art, w.dir, w.exe_name),
            .linux_appimage => |a| try apply.applyAppImage(u.io, art, a.dir, a.file_name),
            .linux_tarball => |t| try apply.applyTarball(u.gpa, u.io, art, t.parent_dir, t.dir_name, t.exe_name, &suffix),
            else => return error.NotSupportedForThisInstall,
        }
        // Installed: the download is no longer needed.
        dir.deleteFile(u.io, d.artifact.name) catch {};
        u.apply_on_quit = false;
    }

    /// Call once at startup: removes `*.old` files (Windows), staging dirs and
    /// backups from earlier updates, and downloads for versions that are no
    /// longer newer than the running one.
    pub fn cleanupAfterUpdate(u: *Updater) void {
        apply.cleanupLeftovers(u.gpa, u.io, u.install);
        var dir = Io.Dir.cwd().openDir(u.io, u.cache_dir, .{ .iterate = true }) catch return;
        defer dir.close(u.io);
        const current = semver.parse(u.opts.current_version) catch return;
        var it = dir.iterate();
        var names: [8][128]u8 = undefined;
        var lens: [8]usize = undefined;
        var n: usize = 0;
        while (it.next(u.io) catch null) |e| {
            if (n == names.len or e.kind != .directory or e.name.len > 128) continue;
            const v = semver.parse(e.name) catch continue;
            if (semver.isNewer(v, current)) continue;
            @memcpy(names[n][0..e.name.len], e.name);
            lens[n] = e.name.len;
            n += 1;
        }
        for (0..n) |i| dir.deleteTree(u.io, names[i][0..lens[i]]) catch {};
    }
};

/// If the app was started by `applyAndRelaunch`, returns the version it was
/// updated from (to show "Updated to X"). Pass the process arguments.
pub fn relaunchedFrom(args: []const []const u8) ?[]const u8 {
    for (args) |a| {
        if (std.mem.startsWith(u8, a, apply.relaunch_flag)) return a[apply.relaunch_flag.len..];
    }
    return null;
}

/// Checks `dir/name` against the size and SHA-256 from the signed manifest.
pub fn verifyFile(io: Io, dir: Io.Dir, name: []const u8, size: u64, digest: [32]u8) !void {
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);
    if (try file.length(io) != size) return error.ChecksumMismatch;
    var buf: [64 * 1024]u8 = undefined;
    var fr = file.reader(io, &buf);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    while (true) {
        const chunk = fr.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return fr.err.?,
        };
        h.update(chunk);
        fr.interface.toss(chunk.len);
    }
    const got = h.finalResult();
    if (!std.crypto.timing_safe.eql([32]u8, got, digest)) return error.ChecksumMismatch;
}

/// Background download state, heap-allocated so `Updater` may move.
const Download = struct {
    gpa: std.mem.Allocator,
    io: Io,
    environ_map: ?*const std.process.Environ.Map,
    user_agent: []u8,
    url: []u8,
    dir_path: []u8,
    artifact: manifest.Artifact,
    progress: Progress,
    /// Strings backing `artifact`.
    strings: std.heap.ArenaAllocator,
    thread: ?std.Thread = null,
    cancel: std.atomic.Value(bool) = .init(false),
    downloaded: std.atomic.Value(u64) = .init(0),
    state: std.atomic.Value(u8) = .init(@backingInt(DownloadState.Phase.running)),
    err: ?anyerror = null,

    fn create(u: *Updater, p: Updater.Pending, progress: Progress) !*Download {
        const d = try u.gpa.create(Download);
        errdefer u.gpa.destroy(d);
        d.* = .{
            .gpa = u.gpa,
            .io = u.io,
            .environ_map = u.opts.environ_map,
            .user_agent = undefined,
            .url = undefined,
            .dir_path = undefined,
            .artifact = undefined,
            .progress = progress,
            .strings = .init(u.gpa),
        };
        errdefer d.strings.deinit();
        const a = d.strings.allocator();
        d.user_agent = try a.dupe(u8, u.user_agent);
        d.url = try a.dupe(u8, p.url);
        d.dir_path = try std.fs.path.join(a, &.{ u.cache_dir, p.version });
        d.artifact = .{
            .platform = try a.dupe(u8, p.artifact.platform),
            .name = try a.dupe(u8, p.artifact.name),
            .size = p.artifact.size,
            .sha256 = try a.dupe(u8, p.artifact.sha256),
        };
        return d;
    }

    fn destroy(d: *Download) void {
        if (d.thread) |t| t.join();
        d.strings.deinit();
        d.gpa.destroy(d);
    }

    fn phase(d: *const Download) DownloadState.Phase {
        return @fromBackingInt(@intCast(d.state.load(.acquire)));
    }

    fn run(d: *Download) void {
        if (d.work()) |_| {
            d.state.store(@backingInt(DownloadState.Phase.ready), .release);
        } else |err| {
            d.err = err;
            d.state.store(@backingInt(DownloadState.Phase.failed), .release);
        }
    }

    fn onProgress(ctx: ?*anyopaque, done: u64, total: u64) void {
        const d: *Download = @ptrCast(@alignCast(ctx.?));
        d.downloaded.store(done, .monotonic);
        d.progress.report(done, total);
    }

    fn work(d: *Download) !void {
        const io = d.io;
        var dir = try Io.Dir.cwd().createDirPathOpen(io, d.dir_path, .{});
        defer dir.close(io);

        // Already downloaded and verified earlier?
        if (verifyFile(io, dir, d.artifact.name, d.artifact.size, d.artifact.digest())) |_| {
            d.downloaded.store(d.artifact.size, .monotonic);
            d.progress.report(d.artifact.size, d.artifact.size);
            return;
        } else |_| {}

        var part_buf: [300]u8 = undefined;
        const part = try std.fmt.bufPrint(&part_buf, "{s}.part", .{d.artifact.name});

        var session: http.Session = undefined;
        try session.init(d.gpa, io, d.environ_map, d.user_agent);
        defer session.deinit();

        var restarts: u8 = 0;
        var transient: u8 = 0;
        while (true) {
            http.downloadResumable(&session, io, d.url, dir, part, d.artifact.size, .{ .ctx = d, .func = onProgress }, &d.cancel) catch |err| switch (err) {
                error.DownloadCanceled, error.HttpStatus, error.OutOfMemory => return err,
                else => {
                    // Dropped connection etc.: resume from what we have.
                    transient += 1;
                    if (transient > 4) return err;
                    continue;
                },
            };
            if (verifyFile(io, dir, part, d.artifact.size, d.artifact.digest())) |_| break else |err| {
                // Corrupt data (e.g. a stale partial file): start over once.
                dir.deleteFile(io, part) catch {};
                restarts += 1;
                if (restarts > 1) return err;
            }
        }
        try dir.rename(part, dir, d.artifact.name, io);
    }
};

const Dirs = enum { state, cache };

fn defaultDir(gpa: std.mem.Allocator, environ_map: ?*const std.process.Environ.Map, which: Dirs) ![]u8 {
    const m = environ_map orelse return error.StateDirUnknown;
    switch (builtin.os.tag) {
        .macos => {
            const home = m.get("HOME") orelse return error.StateDirUnknown;
            return switch (which) {
                .state => std.fs.path.join(gpa, &.{ home, "Library", "Application Support", "typebud" }),
                .cache => std.fs.path.join(gpa, &.{ home, "Library", "Caches", "typebud", "updates" }),
            };
        },
        .windows => {
            const base = m.get("LOCALAPPDATA") orelse return error.StateDirUnknown;
            return switch (which) {
                .state => std.fs.path.join(gpa, &.{ base, "typebud" }),
                .cache => std.fs.path.join(gpa, &.{ base, "typebud", "updates" }),
            };
        },
        else => {
            const home = m.get("HOME");
            switch (which) {
                .state => {
                    if (m.get("XDG_STATE_HOME")) |x| if (x.len > 0) return std.fs.path.join(gpa, &.{ x, "typebud" });
                    return std.fs.path.join(gpa, &.{ home orelse return error.StateDirUnknown, ".local", "state", "typebud" });
                },
                .cache => {
                    if (m.get("XDG_CACHE_HOME")) |x| if (x.len > 0) return std.fs.path.join(gpa, &.{ x, "typebud", "updates" });
                    return std.fs.path.join(gpa, &.{ home orelse return error.StateDirUnknown, ".cache", "typebud", "updates" });
                },
            }
        },
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(Updater);
    _ = semver;
    _ = manifest;
    _ = github;
    _ = platform;
    _ = plan;
    _ = apply;
    _ = state;
    _ = http;
    _ = @import("test_keys.zig");
}

test "init refuses an unconfigured key" {
    try testing.expectError(error.UpdateKeyNotConfigured, Updater.init(testing.allocator, testing.io, .{
        .current_version = "0.1.0",
        .public_key = @splat(0),
        .state_dir = "x",
        .cache_dir = "y",
        .exe_path = "/x/typebud",
    }));
}

test "init detects install and support" {
    const test_keys = @import("test_keys.zig");
    var u = try Updater.init(testing.allocator, testing.io, .{
        .current_version = "0.1.0",
        .public_key = test_keys.public_key,
        .state_dir = ".zig-cache/tmp/updater-test-state",
        .cache_dir = ".zig-cache/tmp/updater-test-cache",
        .exe_path = "/usr/bin/typebud",
    });
    defer u.deinit();
    if (builtin.os.tag == .linux) try testing.expect(u.support() == .managed_by_package_manager);
    try testing.expectError(error.NoUpdateAvailable, u.download(.{}));
    try testing.expectEqual(DownloadState.Phase.idle, u.downloadState().phase);
}

test "verifyFile checks size and digest" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a", .data = "hello" });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("hello", &digest, .{});
    try verifyFile(testing.io, tmp.dir, "a", 5, digest);
    try testing.expectError(error.ChecksumMismatch, verifyFile(testing.io, tmp.dir, "a", 6, digest));
    digest[0] ^= 1;
    try testing.expectError(error.ChecksumMismatch, verifyFile(testing.io, tmp.dir, "a", 5, digest));
}

test "relaunchedFrom" {
    try testing.expectEqualStrings("0.1.0", relaunchedFrom(&.{ "typebud", "--typebud-updated-from=0.1.0" }).?);
    try testing.expect(relaunchedFrom(&.{"typebud"}) == null);
}

test "default dirs" {
    var m: std.process.Environ.Map = .init(testing.allocator);
    defer m.deinit();
    try m.put("HOME", "/home/me");
    try m.put("LOCALAPPDATA", "C:\\Users\\me\\AppData\\Local");
    const s = try defaultDir(testing.allocator, &m, .state);
    defer testing.allocator.free(s);
    try testing.expect(std.mem.find(u8, s, "typebud") != null);
    try testing.expectError(error.StateDirUnknown, defaultDir(testing.allocator, null, .cache));
}
