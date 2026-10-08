const std = @import("std");
pub const Options = struct {
    exe: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    version: []const u8,
    zpui: *std.Build.Module,
    asset_index: *std.Build.Module,
};
pub fn addPackageStep(b: *std.Build, o: Options) void {
    _ = o;
    _ = b.step("package", "Package the app");
}
