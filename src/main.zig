const std = @import("std");
const zpui = @import("zpui");
const art = @import("art.zig");
const assets = @import("assets.zig");
const legends = @import("legends.zig");
const snapshot = @import("snapshot.zig");
const clock = @import("clock.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    clock.init(init.io);
    const cat = try art.Catalog.init(gpa);
    defer cat.deinit(gpa);
    const pts = try zpui.text.createPlatformTextSystem(gpa);
    var ts = zpui.text.TextSystem.init(gpa, pts);
    defer ts.deinit();
    try ts.addFont(assets.get("assets/fonts/Nunito-ExtraBold.ttf").?);
    const fid = try ts.resolveFont(.{ .family = "Nunito ExtraLight" });
    std.debug.print("font id {any} glyph a={any}\n", .{ fid, ts.platform.vtable.glyphForChar(ts.platform.ptr, fid, 'a') });
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const keys = try legends.Keys.parse(arena.allocator(), assets.get("art/_shared/keyboard_keys.json").?, legends.os_name);
    var s = snapshot.Snapshotter.init(gpa, cat, &ts, fid, &keys);
    defer s.deinit();
    {
        const rgba = try s.renderRgba(.{ .animal = cat.indexOf("cat").?, .vibe = .bright, .frame = .idle, .outfit = .{ .keyboard = true }, .origin = .{ 0, 0 }, .size = 1024, .raster_px = 1024, .legend_size = 1024 });
        defer gpa.free(rgba);
        try snapshot.writeRgbaPng(gpa, init.io, "zig-out/dev/kb1024.png", rgba, 1024, 1024);
    }
    for (cat.list(), 0..) |a, i| {
        var buf: [128]u8 = undefined;
        try snapshot.animalSheet(&s, init.io, i, 512, try std.fmt.bufPrint(&buf, "zig-out/dev/{s}_sheet.png", .{a.name}));
    }
}
test {
    _ = @import("assets.zig");
    _ = @import("art.zig");
    _ = @import("raster.zig");
    _ = @import("legends.zig");
    _ = @import("pet_state.zig");
}
