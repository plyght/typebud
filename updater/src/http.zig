//! Minimal HTTPS helpers over `std.http.Client`: conditional GET for the
//! GitHub API, bounded GET for small files, and resumable downloads.
//!
//! A `Session` (and its `std.http.Client`, TLS state and connection pool) is
//! created per check / per download and torn down afterwards, so nothing
//! stays open while the updater is idle.

const std = @import("std");
const Io = std.Io;
const http = std.http;

pub const user_agent_prefix = "typebud-updater/";

pub const Session = struct {
    client: http.Client,
    proxy_arena: std.heap.ArenaAllocator,
    user_agent: []const u8,
    /// Optional `Authorization` value ("Bearer ...") for the API (CI only).
    authorization: ?[]const u8 = null,

    pub fn init(
        self: *Session,
        gpa: std.mem.Allocator,
        io: Io,
        environ_map: ?*const std.process.Environ.Map,
        user_agent: []const u8,
    ) !void {
        self.* = .{
            .client = .{ .allocator = gpa, .io = io },
            .proxy_arena = .init(gpa),
            .user_agent = user_agent,
        };
        if (environ_map) |env| {
            // Honour HTTPS_PROXY / HTTP_PROXY like other tools on the system.
            self.client.initDefaultProxies(self.proxy_arena.allocator(), env) catch {};
        }
    }

    pub fn deinit(self: *Session) void {
        self.client.deinit();
        self.proxy_arena.deinit();
    }
};

pub const ConditionalResult = struct {
    status: http.Status,
    /// Owned by the caller's allocator; null when not provided.
    etag: ?[]u8 = null,
    /// Owned by the caller's allocator; empty for 304.
    body: []u8 = &.{},
};

pub const Error = error{
    HttpStatus,
    ResponseTooLarge,
    RangeMismatch,
    SizeMismatch,
    DownloadCanceled,
} || http.Client.RequestError || http.Client.Request.ReceiveHeadError || std.mem.Allocator.Error || Io.Writer.Error || Io.Reader.Error;

/// GET with `If-None-Match`. Returns 200 with body+etag, or 304 with no body.
/// Any other status is returned as-is with an empty body.
pub fn getConditional(
    s: *Session,
    gpa: std.mem.Allocator,
    url: []const u8,
    etag: ?[]const u8,
    max_bytes: usize,
) !ConditionalResult {
    const uri = try std.Uri.parse(url);
    var headers_buf: [4]http.Header = undefined;
    var nh: usize = 0;
    headers_buf[nh] = .{ .name = "Accept", .value = "application/vnd.github+json" };
    nh += 1;
    headers_buf[nh] = .{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" };
    nh += 1;
    if (etag) |e| if (e.len > 0) {
        headers_buf[nh] = .{ .name = "If-None-Match", .value = e };
        nh += 1;
    };
    var priv: [1]http.Header = undefined;
    var npriv: usize = 0;
    if (s.authorization) |a| {
        priv[0] = .{ .name = "Authorization", .value = a };
        npriv = 1;
    }

    var req = try s.client.request(.GET, uri, .{
        .headers = .{ .user_agent = .{ .override = s.user_agent } },
        .extra_headers = headers_buf[0..nh],
        .privileged_headers = priv[0..npriv],
        .keep_alive = false,
    });
    defer req.deinit();
    try req.sendBodiless();

    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    var result: ConditionalResult = .{ .status = response.head.status };
    var it = response.head.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "etag")) {
            result.etag = try gpa.dupe(u8, h.value);
            break;
        }
    }
    errdefer if (result.etag) |e| gpa.free(e);

    if (response.head.status != .ok) return result;

    const decompress_buf = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(decompress_buf);
    var transfer_buf: [64]u8 = undefined;
    var decompress: http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buf, &decompress, decompress_buf);
    result.body = reader.allocRemaining(gpa, .limited(max_bytes)) catch |err| switch (err) {
        error.StreamTooLong => return error.ResponseTooLarge,
        error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return result;
}

/// GET a small file (manifest / signature), following redirects.
pub fn getSmall(s: *Session, gpa: std.mem.Allocator, url: []const u8, max_bytes: usize) ![]u8 {
    const uri = try std.Uri.parse(url);
    var req = try s.client.request(.GET, uri, .{
        .headers = .{
            .user_agent = .{ .override = s.user_agent },
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = &.{.{ .name = "Accept", .value = "application/octet-stream" }},
        .keep_alive = false,
    });
    defer req.deinit();
    try req.sendBodiless();
    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);
    if (response.head.status != .ok) return error.HttpStatus;
    if (response.head.content_length) |len| if (len > max_bytes) return error.ResponseTooLarge;
    const reader = response.reader(&.{});
    return reader.allocRemaining(gpa, .limited(max_bytes)) catch |err| switch (err) {
        error.StreamTooLong => return error.ResponseTooLarge,
        error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

pub const Progress = struct {
    ctx: ?*anyopaque = null,
    /// Called from the download thread with bytes so far and the total.
    func: ?*const fn (ctx: ?*anyopaque, downloaded: u64, total: u64) void = null,

    pub fn report(p: Progress, done: u64, total: u64) void {
        if (p.func) |f| f(p.ctx, done, total);
    }
};

/// Parses `Content-Range: bytes <start>-<end>/<total>` and returns `start`.
pub fn parseContentRangeStart(value: []const u8) ?u64 {
    const v = std.mem.trim(u8, value, " ");
    if (!std.mem.startsWith(u8, v, "bytes ")) return null;
    const rest = v["bytes ".len..];
    const dash = std.mem.findScalar(u8, rest, '-') orelse return null;
    return std.fmt.parseInt(u64, rest[0..dash], 10) catch null;
}

/// Downloads `url` into `dir/part_name`, resuming from whatever is already
/// there (HTTP Range). Stops at `expected_size` bytes. The caller verifies the
/// SHA-256 afterwards and renames the file into place.
pub fn downloadResumable(
    s: *Session,
    io: Io,
    url: []const u8,
    dir: Io.Dir,
    part_name: []const u8,
    expected_size: u64,
    progress: Progress,
    cancel: *const std.atomic.Value(bool),
) !void {
    var attempts: u8 = 0;
    while (true) : (attempts += 1) {
        if (attempts >= 2) return error.RangeMismatch;
        const file = try dir.createFile(io, part_name, .{ .read = true, .truncate = false });
        defer file.close(io);
        var offset = try file.length(io);
        if (offset > expected_size) {
            try file.setLength(io, 0);
            offset = 0;
        }
        if (offset == expected_size) {
            progress.report(offset, expected_size);
            return;
        }

        const uri = try std.Uri.parse(url);
        var range_buf: [64]u8 = undefined;
        const range = try std.fmt.bufPrint(&range_buf, "bytes={d}-", .{offset});
        const extra: []const http.Header = if (offset > 0)
            &.{ .{ .name = "Accept", .value = "application/octet-stream" }, .{ .name = "Range", .value = range } }
        else
            &.{.{ .name = "Accept", .value = "application/octet-stream" }};
        var req = try s.client.request(.GET, uri, .{
            .headers = .{
                .user_agent = .{ .override = s.user_agent },
                .accept_encoding = .{ .override = "identity" },
            },
            .extra_headers = extra,
            .keep_alive = false,
        });
        defer req.deinit();
        try req.sendBodiless();
        var redirect_buf: [8 * 1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        switch (response.head.status) {
            .partial_content => {
                var start: ?u64 = null;
                var it = response.head.iterateHeaders();
                while (it.next()) |h| {
                    if (std.ascii.eqlIgnoreCase(h.name, "content-range")) start = parseContentRangeStart(h.value);
                }
                if (start != offset) {
                    // Server ignored our range in a way we can't use; start over.
                    try file.setLength(io, 0);
                    continue;
                }
            },
            .ok => {
                // Server sent the whole thing (no range support, or offset 0).
                try file.setLength(io, 0);
                offset = 0;
            },
            .range_not_satisfiable => {
                try file.setLength(io, 0);
                continue;
            },
            else => return error.HttpStatus,
        }

        var write_buf: [64 * 1024]u8 = undefined;
        var fw = file.writer(io, &write_buf);
        try fw.seekTo(offset);
        const reader = response.reader(&.{});
        var done = offset;
        progress.report(done, expected_size);
        while (done < expected_size) {
            if (cancel.load(.acquire)) {
                fw.interface.flush() catch {};
                return error.DownloadCanceled;
            }
            const remaining = expected_size - done;
            const n = reader.stream(&fw.interface, .limited64(@min(remaining, 256 * 1024))) catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => {
                    fw.interface.flush() catch {};
                    return response.bodyErr() orelse error.ReadFailed;
                },
                error.WriteFailed => return fw.err orelse error.WriteFailed,
            };
            done += n;
            progress.report(done, expected_size);
        }
        fw.interface.flush() catch |err| return fw.err orelse err;
        if (done != expected_size) return error.SizeMismatch;
        return;
    }
}

const testing = std.testing;

test "content-range parsing" {
    try testing.expectEqual(@as(?u64, 100), parseContentRangeStart("bytes 100-199/200"));
    try testing.expectEqual(@as(?u64, 0), parseContentRangeStart("bytes 0-0/1"));
    try testing.expectEqual(@as(?u64, null), parseContentRangeStart("bytes */200"));
    try testing.expectEqual(@as(?u64, null), parseContentRangeStart("items 1-2/3"));
}
