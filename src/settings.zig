//! User settings: the model, validation, and JSON persistence in the platform config dir
//! (~/Library/Application Support/typebud, %APPDATA%\typebud, $XDG_CONFIG_HOME/typebud).
//! Writes are atomic (temp file + rename); the app debounces them.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const art = @import("art.zig");

pub const file_name = "settings.json";

/// Fixed-capacity string (settings stay a plain value type: copyable, no allocator).
pub fn Str(comptime cap: usize) type {
    return struct {
        buf: [cap]u8 = undefined,
        len: u16 = 0,

        const Self = @This();
        pub fn init(s: []const u8) Self {
            var r: Self = .{};
            r.set(s);
            return r;
        }
        pub fn set(self: *Self, s: []const u8) void {
            const n = @min(s.len, cap);
            @memcpy(self.buf[0..n], s[0..n]);
            self.len = @intCast(n);
        }
        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }
        pub fn eql(self: *const Self, s: []const u8) bool {
            return std.mem.eql(u8, self.slice(), s);
        }
    };
}

pub const Corner = enum { top_left, top_right, bottom_left, bottom_right };
pub const Sensitivity = enum {
    relaxed,
    normal,
    eager,

    pub const labels = [_][]const u8{ "Relaxed", "Normal", "Eager" };
    /// Words per minute that count as "fast".
    pub fn wpm(s: Sensitivity) f32 {
        return switch (s) {
            .relaxed => 95,
            .normal => 70,
            .eager => 50,
        };
    }
};
pub const VisibilityMode = enum {
    everywhere,
    only_in,
    hide_in,

    pub const labels = [_][]const u8{ "Everywhere", "Only in These Apps", "Hide in These Apps" };
};

pub const AppEntry = struct {
    id: Str(128) = .{},
    name: Str(64) = .{},
};

pub const max_apps = 32;
pub const min_size: f32 = 96;
pub const max_size: f32 = 512;
pub const size_presets = [_]f32{ 128, 176, 256 };

pub const Settings = struct {
    // Character
    animal: Str(32) = Str(32).init("cat"),
    vibe: art.Vibe = .dark,
    // Accessories
    keyboard: bool = true,
    head: art.HeadItem = .none,
    held: art.HeldItem = .none,
    desk_lamp: bool = false,
    desk_plant: bool = false,
    desk_mug: bool = false,
    sparkles: bool = false,
    // Behavior
    size: f32 = 176,
    corner: Corner = .bottom_right,
    margin_x: f32 = 16,
    margin_y: f32 = 16,
    /// Display index in the platform's list (0 = primary/first).
    display: u32 = 0,
    animations: bool = true,
    /// Seconds; 0 = never.
    sleep_after: u32 = 60,
    sensitivity: Sensitivity = .normal,
    // Sounds
    sound: bool = true,
    pack: Str(64) = Str(64).init("nk-cream"),
    volume: f32 = 0.6,
    key_up: bool = true,
    mute_other_audio: bool = false,
    mute_mic: bool = true,
    // Visibility
    visibility: VisibilityMode = .everywhere,
    apps: [max_apps]AppEntry = @splat(.{}),
    app_count: u32 = 0,
    remember_visible: bool = true,
    visible: bool = true,
    // System
    launch_at_login: bool = false,
    precise_input: bool = false,
    auto_update: bool = true,

    pub fn outfit(s: *const Settings) art.Outfit {
        return .{
            .keyboard = s.keyboard,
            .sparkles = s.sparkles,
            .desk = .{ .lamp = s.desk_lamp, .plant = s.desk_plant, .mug = s.desk_mug },
            .head = s.head,
            .held = s.held,
        };
    }

    pub fn appList(s: *const Settings) []const AppEntry {
        return s.apps[0..s.app_count];
    }

    pub fn hasApp(s: *const Settings, id: []const u8) bool {
        for (s.appList()) |a| if (a.id.eql(id)) return true;
        return false;
    }

    pub fn addApp(s: *Settings, id: []const u8, name: []const u8) bool {
        if (id.len == 0 or s.hasApp(id) or s.app_count == max_apps) return false;
        s.apps[s.app_count] = .{ .id = .init(id), .name = .init(if (name.len > 0) name else id) };
        s.app_count += 1;
        return true;
    }

    pub fn removeApp(s: *Settings, index: usize) void {
        if (index >= s.app_count) return;
        var i = index;
        while (i + 1 < s.app_count) : (i += 1) s.apps[i] = s.apps[i + 1];
        s.app_count -= 1;
    }

    /// Clamp everything to valid ranges.
    pub fn sanitize(s: *Settings) void {
        if (!(s.size >= min_size)) s.size = min_size;
        if (s.size > max_size) s.size = max_size;
        s.volume = std.math.clamp(if (std.math.isNan(s.volume)) 0.6 else s.volume, 0, 1);
        s.margin_x = std.math.clamp(if (std.math.isNan(s.margin_x)) 16 else s.margin_x, 0, 4096);
        s.margin_y = std.math.clamp(if (std.math.isNan(s.margin_y)) 16 else s.margin_y, 0, 4096);
        s.sleep_after = @min(s.sleep_after, 3600);
        s.app_count = @min(s.app_count, max_apps);
    }
};

// ---- JSON -----------------------------------------------------------------------------

/// On-disk shape (slices instead of fixed buffers; every field optional on read).
const Json = struct {
    version: u32 = 1,
    animal: []const u8 = "cat",
    vibe: art.Vibe = .dark,
    keyboard: bool = true,
    head: art.HeadItem = .none,
    held: art.HeldItem = .none,
    desk_lamp: bool = false,
    desk_plant: bool = false,
    desk_mug: bool = false,
    sparkles: bool = false,
    size: f32 = 176,
    corner: Corner = .bottom_right,
    margin_x: f32 = 16,
    margin_y: f32 = 16,
    display: u32 = 0,
    animations: bool = true,
    sleep_after: u32 = 60,
    sensitivity: Sensitivity = .normal,
    sound: bool = true,
    pack: []const u8 = "nk-cream",
    volume: f32 = 0.6,
    key_up: bool = true,
    mute_other_audio: bool = false,
    mute_mic: bool = true,
    visibility: VisibilityMode = .everywhere,
    apps: []const struct { id: []const u8, name: []const u8 = "" } = &.{},
    remember_visible: bool = true,
    visible: bool = true,
    launch_at_login: bool = false,
    precise_input: bool = false,
    auto_update: bool = true,
};

pub fn fromJson(gpa: Allocator, bytes: []const u8) !Settings {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const j = try std.json.parseFromSliceLeaky(Json, arena.allocator(), bytes, .{ .ignore_unknown_fields = true });
    var s: Settings = .{};
    inline for (@typeInfo(Json).@"struct".field_names) |name| {
        if (comptime std.mem.eql(u8, name, "version") or std.mem.eql(u8, name, "animal") or std.mem.eql(u8, name, "pack") or std.mem.eql(u8, name, "apps")) continue;
        @field(s, name) = @field(j, name);
    }
    s.animal.set(j.animal);
    s.pack.set(j.pack);
    for (j.apps) |a| _ = s.addApp(a.id, a.name);
    s.sanitize();
    return s;
}

pub fn toJson(gpa: Allocator, s: *const Settings) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var j: Json = .{};
    inline for (@typeInfo(Json).@"struct".field_names) |name| {
        if (comptime std.mem.eql(u8, name, "version") or std.mem.eql(u8, name, "animal") or std.mem.eql(u8, name, "pack") or std.mem.eql(u8, name, "apps")) continue;
        @field(j, name) = @field(s, name);
    }
    j.animal = s.animal.slice();
    j.pack = s.pack.slice();
    const Entry = @typeInfo(@TypeOf(j.apps)).pointer.child;
    const apps = try arena.allocator().alloc(Entry, s.app_count);
    for (s.appList(), apps) |a, *o| o.* = .{ .id = a.id.slice(), .name = a.name.slice() };
    j.apps = apps;
    return std.json.Stringify.valueAlloc(gpa, j, .{ .whitespace = .indent_2 });
}

// ---- files ------------------------------------------------------------------------------

/// The platform config directory for typebud (caller frees). `env` is the process
/// environment.
pub fn configDir(gpa: Allocator, env: *const std.process.Environ.Map) ![]u8 {
    switch (builtin.os.tag) {
        .macos => {
            const home = env.get("HOME") orelse return error.NoHome;
            return std.fs.path.join(gpa, &.{ home, "Library", "Application Support", "typebud" });
        },
        .windows => {
            const appdata = env.get("APPDATA") orelse return error.NoHome;
            return std.fs.path.join(gpa, &.{ appdata, "typebud" });
        },
        else => {
            if (env.get("XDG_CONFIG_HOME")) |x| if (x.len > 0) return std.fs.path.join(gpa, &.{ x, "typebud" });
            const home = env.get("HOME") orelse return error.NoHome;
            return std.fs.path.join(gpa, &.{ home, ".config", "typebud" });
        },
    }
}

/// Load `dir/settings.json`; defaults when it is missing or unreadable (logged).
pub fn load(gpa: Allocator, io: Io, dir: []const u8) Settings {
    var d = Io.Dir.cwd().openDir(io, dir, .{}) catch return .{};
    defer d.close(io);
    const bytes = d.readFileAlloc(io, file_name, gpa, .limited(1 << 20)) catch |e| {
        if (e != error.FileNotFound) std.log.warn("settings: cannot read {s}/{s}: {t}", .{ dir, file_name, e });
        return .{};
    };
    defer gpa.free(bytes);
    return fromJson(gpa, bytes) catch |e| {
        std.log.warn("settings: {s}/{s} is invalid ({t}); using defaults", .{ dir, file_name, e });
        return .{};
    };
}

/// Atomically write `dir/settings.json` (creating `dir`).
pub fn save(gpa: Allocator, io: Io, dir: []const u8, s: *const Settings) !void {
    const json = try toJson(gpa, s);
    defer gpa.free(json);
    try writeAtomic(io, dir, file_name, json);
}

pub fn writeAtomic(io: Io, dir: []const u8, name: []const u8, data: []const u8) !void {
    var d = try Io.Dir.cwd().createDirPathOpen(io, dir, .{});
    defer d.close(io);
    var tmp_buf: [128]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{name});
    try d.writeFile(io, .{ .sub_path = tmp, .data = data });
    try d.rename(tmp, d, name, io);
}

// ---- tests ------------------------------------------------------------------------------

test "settings JSON round-trip" {
    const gpa = std.testing.allocator;
    var s: Settings = .{};
    s.animal.set("capybara");
    s.vibe = .pink;
    s.head = .yuzu;
    s.held = .boba;
    s.desk_plant = true;
    s.size = 300;
    s.corner = .top_left;
    s.sleep_after = 120;
    s.sensitivity = .eager;
    s.pack.set("topre");
    s.volume = 0.25;
    s.visibility = .hide_in;
    _ = s.addApp("org.mozilla.firefox", "Firefox");
    _ = s.addApp("com.apple.Terminal", "Terminal");
    s.precise_input = true;
    const json = try toJson(gpa, &s);
    defer gpa.free(json);
    const r = try fromJson(gpa, json);
    try std.testing.expectEqualStrings("capybara", r.animal.slice());
    try std.testing.expectEqual(art.Vibe.pink, r.vibe);
    try std.testing.expectEqual(art.HeadItem.yuzu, r.head);
    try std.testing.expectEqual(art.HeldItem.boba, r.held);
    try std.testing.expect(r.desk_plant and !r.desk_lamp);
    try std.testing.expectEqual(@as(f32, 300), r.size);
    try std.testing.expectEqual(Corner.top_left, r.corner);
    try std.testing.expectEqual(@as(u32, 120), r.sleep_after);
    try std.testing.expectEqualStrings("topre", r.pack.slice());
    try std.testing.expectEqual(@as(u32, 2), r.app_count);
    try std.testing.expectEqualStrings("Terminal", r.apps[1].name.slice());
    try std.testing.expect(r.precise_input);
    try std.testing.expectEqual(VisibilityMode.hide_in, r.visibility);
}

test "settings: unknown fields ignored, missing ones default, values clamped" {
    const gpa = std.testing.allocator;
    const r = try fromJson(gpa, "{\"size\": 9000, \"volume\": -2, \"future_thing\": [1,2], \"vibe\": \"bright\"}");
    try std.testing.expectEqual(max_size, r.size);
    try std.testing.expectEqual(@as(f32, 0), r.volume);
    try std.testing.expectEqual(art.Vibe.bright, r.vibe);
    try std.testing.expectEqualStrings("cat", r.animal.slice());
    try std.testing.expect(r.keyboard);
}

test "settings save/load through the filesystem" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [512]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const dir = try std.fs.path.join(gpa, &.{ path_buf[0..n], "cfg" });
    defer gpa.free(dir);
    var s: Settings = .{};
    s.vibe = .bright;
    s.sleep_after = 0;
    try save(gpa, io, dir, &s);
    try save(gpa, io, dir, &s); // overwrite works
    const r = load(gpa, io, dir);
    try std.testing.expectEqual(art.Vibe.bright, r.vibe);
    try std.testing.expectEqual(@as(u32, 0), r.sleep_after);
    const missing = load(gpa, io, "/nonexistent/typebud-test");
    try std.testing.expectEqual(art.Vibe.dark, missing.vibe);
}
