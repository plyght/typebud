const std = @import("std");
pub const Error = error{ Unsupported, OutOfMemory };
pub fn importPack(gpa: std.mem.Allocator, io: std.Io, src: []const u8, dest_root: []const u8) anyerror![]u8 {
    _ = .{ gpa, io, src, dest_root };
    return error.Unsupported;
}
pub fn describe(e: anyerror) []const u8 {
    return @errorName(e);
}
