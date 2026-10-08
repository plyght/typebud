//! Pet placement math: moving an anchored overlay with the pointer and snapping it to the
//! nearest corner of the nearest display afterwards.

const std = @import("std");
const settings = @import("settings.zig");

pub const Point = struct { x: f32, y: f32 };
pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

/// New margins after dragging by `delta` from `start` (moving towards the anchored corner
/// shrinks that margin; never negative).
pub fn dragMargin(corner: settings.Corner, start: Point, delta: Point) Point {
    const sx: f32 = switch (corner) {
        .top_left, .bottom_left => 1,
        .top_right, .bottom_right => -1,
    };
    const sy: f32 = switch (corner) {
        .top_left, .top_right => 1,
        .bottom_left, .bottom_right => -1,
    };
    return .{ .x = @max(0, start.x + sx * delta.x), .y = @max(0, start.y + sy * delta.y) };
}

pub const Snap = struct { display: usize, corner: settings.Corner };

/// The display nearest to `p` (containing it, else the closest) and the corner of its
/// work area whose quadrant `p` is in.
pub fn snap(p: Point, displays: []const Rect) ?Snap {
    if (displays.len == 0) return null;
    var best: usize = 0;
    var best_d: f32 = std.math.floatMax(f32);
    for (displays, 0..) |b, i| {
        const cx = std.math.clamp(p.x, b.x, b.x + b.w);
        const cy = std.math.clamp(p.y, b.y, b.y + b.h);
        const d = (cx - p.x) * (cx - p.x) + (cy - p.y) * (cy - p.y);
        if (d < best_d) {
            best_d = d;
            best = i;
        }
    }
    const b = displays[best];
    const left = p.x < b.x + b.w / 2;
    const top = p.y < b.y + b.h / 2;
    return .{ .display = best, .corner = if (top) (if (left) .top_left else .top_right) else (if (left) .bottom_left else .bottom_right) };
}

test "dragging moves the margins away from / towards the anchored corner" {
    const m = dragMargin(.bottom_right, .{ .x = 16, .y = 16 }, .{ .x = -100, .y = -40 });
    try std.testing.expectEqual(@as(f32, 116), m.x);
    try std.testing.expectEqual(@as(f32, 56), m.y);
    const t = dragMargin(.top_left, .{ .x = 16, .y = 16 }, .{ .x = -100, .y = 30 });
    try std.testing.expectEqual(@as(f32, 0), t.x);
    try std.testing.expectEqual(@as(f32, 46), t.y);
}

test "snap picks the nearest display and quadrant" {
    const ds = [_]Rect{ .{ .x = 0, .y = 0, .w = 1440, .h = 900 }, .{ .x = 1440, .y = -200, .w = 1920, .h = 1080 } };
    const a = snap(.{ .x = 100, .y = 800 }, &ds).?;
    try std.testing.expectEqual(@as(usize, 0), a.display);
    try std.testing.expectEqual(settings.Corner.bottom_left, a.corner);
    const b = snap(.{ .x = 3300, .y = -150 }, &ds).?;
    try std.testing.expectEqual(@as(usize, 1), b.display);
    try std.testing.expectEqual(settings.Corner.top_right, b.corner);
    const c = snap(.{ .x = 5000, .y = 2000 }, &ds).?; // off-screen: nearest display
    try std.testing.expectEqual(@as(usize, 1), c.display);
    try std.testing.expectEqual(settings.Corner.bottom_right, c.corner);
    try std.testing.expect(snap(.{ .x = 0, .y = 0 }, &.{}) == null);
}
