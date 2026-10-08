//! Window screenshots for the smoke / demo runs: X11 via ImageMagick `import` (Xvfb in CI),
//! macOS via CGWindowListCreateImage. Returns straight RGBA.

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");

pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []u8,
};

pub fn captureWindow(gpa: std.mem.Allocator, io: std.Io, w: *zpui.Window) !Image {
    return switch (builtin.os.tag) {
        .linux => captureX11(gpa, io, w.platform_window),
        .macos => captureMac(gpa, w.platform_window),
        else => error.CaptureUnsupported,
    };
}

fn captureX11(gpa: std.mem.Allocator, io: std.Io, pw: zpui.platform.Window) !Image {
    const b = pw.bounds();
    const scale = pw.scaleFactor();
    const content = pw.contentSize();
    var crop_buf: [64]u8 = undefined;
    const crop = try std.fmt.bufPrint(&crop_buf, "{d}x{d}+{d}+{d}", .{
        @as(u32, @intFromFloat(@round(content.width * scale))),
        @as(u32, @intFromFloat(@round(content.height * scale))),
        @max(@as(i32, @intFromFloat(@round(b.origin.x * scale))), 0),
        @max(@as(i32, @intFromFloat(@round(b.origin.y * scale))), 0),
    });
    const res = try std.process.run(gpa, io, .{
        .argv = &.{ "import", "-window", "root", "-crop", crop, "+repage", "-depth", "8", "ppm:-" },
        .stdout_limit = .limited(256 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    if (!res.term.success()) {
        std.debug.print("capture: import failed: {s}\n", .{res.stderr});
        return error.ImportFailed;
    }
    return parsePpm(gpa, res.stdout);
}
fn parsePpm(gpa: std.mem.Allocator, bytes: []const u8) !Image {
    if (bytes.len < 2 or !std.mem.eql(u8, bytes[0..2], "P6")) return error.NotPpm;
    var pos: usize = 2;
    var fields: [3]u32 = undefined;
    for (&fields) |*f| {
        while (pos < bytes.len and (std.ascii.isWhitespace(bytes[pos]) or bytes[pos] == '#')) {
            if (bytes[pos] == '#') {
                while (pos < bytes.len and bytes[pos] != '\n') pos += 1;
            } else pos += 1;
        }
        const s = pos;
        while (pos < bytes.len and std.ascii.isDigit(bytes[pos])) pos += 1;
        f.* = try std.fmt.parseInt(u32, bytes[s..pos], 10);
    }
    pos += 1;
    const n = @as(usize, fields[0]) * fields[1];
    if (fields[2] != 255 or bytes.len < pos + n * 3) return error.BadPpm;
    const pixels = try gpa.alloc(u8, n * 4);
    for (0..n) |i| {
        pixels[i * 4 ..][0..3].* = bytes[pos + i * 3 ..][0..3].*;
        pixels[i * 4 + 3] = 255;
    }
    return .{ .width = fields[0], .height = fields[1], .pixels = pixels };
}
fn captureMac(gpa: std.mem.Allocator, pw: zpui.platform.Window) !Image {
    if (builtin.os.tag != .macos) unreachable;
    const mac = zpui.mac_platform;
    const cf = mac.cf;
    const number = mac.MacWindow.fromWindow(pw).windowNumber();
    const create_image = cf.cgWindowListCreateImage() orelse return error.CGWindowListCreateImageUnavailable;
    const image = create_image(cf.CGRectNull, cf.kCGWindowListOptionIncludingWindow, number, cf.kCGWindowImageBoundsIgnoreFraming | cf.kCGWindowImageBestResolution) orelse
        return error.CGWindowListCreateImageReturnedNull;
    defer cf.CGImageRelease(image);
    const w = cf.CGImageGetWidth(image);
    const h = cf.CGImageGetHeight(image);
    if (w == 0 or h == 0) return error.EmptyWindowImage;
    const pixels = try gpa.alloc(u8, w * h * 4);
    errdefer gpa.free(pixels);
    @memset(pixels, 0);
    const space = cf.CGColorSpaceCreateDeviceRGB() orelse return error.ColorSpace;
    defer cf.CGColorSpaceRelease(space);
    const ctx = cf.CGBitmapContextCreate(pixels.ptr, w, h, 8, w * 4, space, cf.kCGImageAlphaPremultipliedLast | cf.kCGBitmapByteOrder32Big) orelse return error.BitmapContext;
    defer cf.CGContextRelease(ctx);
    cf.CGContextDrawImage(ctx, .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = @floatFromInt(w), .height = @floatFromInt(h) } }, image);
    var i: usize = 0;
    while (i + 4 <= pixels.len) : (i += 4) {
        const a: u32 = pixels[i + 3];
        if (a == 0 or a == 255) continue;
        for (pixels[i..][0..3]) |*c| c.* = @intCast(@min(255, (@as(u32, c.*) * 255 + a / 2) / a));
    }
    return .{ .width = @intCast(w), .height = @intCast(h), .pixels = pixels };
}
