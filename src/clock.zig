//! Process-wide clocks (monotonic + process CPU time) without threading `Io` everywhere.

const std = @import("std");
const builtin = @import("builtin");

var io_global: ?std.Io = null;

pub fn init(the_io: std.Io) void {
    io_global = the_io;
}

fn getIo() ?std.Io {
    if (io_global) |i| return i;
    if (builtin.is_test) return std.testing.io;
    return null;
}

/// Monotonic nanoseconds (0 before `init`).
pub fn nowNs() u64 {
    const i = getIo() orelse return 0;
    return @intCast(@max(std.Io.Clock.awake.now(i).nanoseconds, 0));
}

/// CPU time used by this process (user + system), nanoseconds.
pub fn cpuNs() u64 {
    const i = getIo() orelse return 0;
    return @intCast(@max(std.Io.Clock.cpu_process.now(i).nanoseconds, 0));
}

/// Wall-clock time (Unix epoch), nanoseconds.
pub fn realNs() i128 {
    const i = getIo() orelse return 0;
    return std.Io.Clock.real.now(i).nanoseconds;
}
