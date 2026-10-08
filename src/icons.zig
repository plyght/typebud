//! App icons generated from art/cat/icon.svg (`typebud --write-icons <dir>`, run by
//! `zig build icons`): the face on a soft rounded tile, as PNGs (16–1024 px), a macOS
//! .icns and a Windows .ico. The results are committed in packaging/icons/ so packaging
//! also works for cross builds.

const std = @import("std");
const zpui = @import("zpui");
const art = @import("art.zig");
const assets = @import("assets.zig");

pub const icon_animal = "cat";

/// The app icon as an SVG document (1024 viewBox): rounded tile + recoloured face.
fn iconSvg(gpa: std.mem.Allocator, catalog: *const art.Catalog) ![]u8 {
    const ai = catalog.indexOf(icon_animal) orelse 0;
    var pb: [64]u8 = undefined;
    const src = assets.get(try std.fmt.bufPrint(&pb, "art/{s}/icon.svg", .{catalog.animals[ai].name})) orelse return error.MissingIcon;
    const recolored = try gpa.alloc(u8, src.len);
    defer gpa.free(recolored);
    art.recolorInto(recolored, src, &catalog.colorMap(ai, .bright));
    const open = std.mem.indexOf(u8, recolored, "<svg") orelse return error.BadIcon;
    const gt = std.mem.indexOfScalarPos(u8, recolored, open, '>') orelse return error.BadIcon;
    const end = std.mem.lastIndexOf(u8, recolored, "</svg>") orelse return error.BadIcon;
    return std.fmt.allocPrint(gpa,
        \\<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
        \\<defs><linearGradient id="tile-bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFF4E2"/><stop offset="1" stop-color="#FFDDE6"/></linearGradient></defs>
        \\<rect x="100" y="100" width="824" height="824" rx="186" fill="url(#tile-bg)" stroke="#3B2A1E" stroke-opacity="0.12" stroke-width="6"/>
        \\<g transform="matrix(2.6 0 0 2.6 179 179)">{s}</g></svg>
    , .{recolored[gt + 1 .. end]});
}

const sizes = [_]u32{ 16, 24, 32, 48, 64, 128, 256, 512, 1024 };

fn pngFor(pngs: *const [sizes.len][]u8, px: u32) []const u8 {
    for (sizes, 0..) |s, i| if (s == px) return pngs[i];
    unreachable;
}

fn png(gpa: std.mem.Allocator, svg: []const u8, px: u32) ![]u8 {
    var pm = try zpui.image.svg.rasterizeBgra(gpa, svg, .{ .size = .{ .width = @intCast(px), .height = @intCast(px) } }, 0xFF000000);
    defer pm.deinit(gpa);
    return zpui.image.encodePng(gpa, pm.bytes, pm.width, pm.height, .bgra);
}

pub fn writeAll(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8) !void {
    const catalog = try art.Catalog.init(gpa);
    defer catalog.deinit(gpa);
    const svg = try iconSvg(gpa, catalog);
    defer gpa.free(svg);
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = "typebud.svg", .data = svg });

    var pngs: [sizes.len][]u8 = undefined;
    var made: usize = 0;
    defer for (pngs[0..made]) |p| gpa.free(p);
    for (sizes, 0..) |s, i| {
        pngs[i] = try png(gpa, svg, s);
        made += 1;
        var nb: [32]u8 = undefined;
        try dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&nb, "typebud-{d}.png", .{s}), .data = pngs[i] });
    }

    // .icns: PNG-encoded entries (macOS 10.7+).
    const icns_entries = [_]struct { tag: *const [4]u8, px: u32 }{
        .{ .tag = "icp4", .px = 16 },  .{ .tag = "icp5", .px = 32 },  .{ .tag = "icp6", .px = 64 },
        .{ .tag = "ic07", .px = 128 }, .{ .tag = "ic08", .px = 256 }, .{ .tag = "ic09", .px = 512 },
        .{ .tag = "ic10", .px = 1024 }, .{ .tag = "ic11", .px = 32 }, .{ .tag = "ic12", .px = 64 },
        .{ .tag = "ic13", .px = 256 }, .{ .tag = "ic14", .px = 512 },
    };
    var icns: std.ArrayList(u8) = .empty;
    defer icns.deinit(gpa);
    try icns.appendSlice(gpa, "icns\x00\x00\x00\x00");
    for (icns_entries) |e| {
        const data = pngFor(&pngs, e.px);
        try icns.appendSlice(gpa, e.tag);
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(data.len + 8), .big);
        try icns.appendSlice(gpa, &len);
        try icns.appendSlice(gpa, data);
    }
    std.mem.writeInt(u32, icns.items[4..8], @intCast(icns.items.len), .big);
    try dir.writeFile(io, .{ .sub_path = "typebud.icns", .data = icns.items });

    // .ico: PNG-compressed entries (Vista+).
    const ico_px = [_]u32{ 16, 24, 32, 48, 64, 128, 256 };
    var ico: std.ArrayList(u8) = .empty;
    defer ico.deinit(gpa);
    var hdr: [6]u8 = .{ 0, 0, 1, 0, 0, 0 };
    std.mem.writeInt(u16, hdr[4..6], ico_px.len, .little);
    try ico.appendSlice(gpa, &hdr);
    var offset: u32 = 6 + 16 * ico_px.len;
    for (ico_px) |s| {
        const data = pngFor(&pngs, s);
        var ent: [16]u8 = @splat(0);
        ent[0] = if (s >= 256) 0 else @intCast(s);
        ent[1] = if (s >= 256) 0 else @intCast(s);
        std.mem.writeInt(u16, ent[4..6], 1, .little);
        std.mem.writeInt(u16, ent[6..8], 32, .little);
        std.mem.writeInt(u32, ent[8..12], @intCast(data.len), .little);
        std.mem.writeInt(u32, ent[12..16], offset, .little);
        offset += @intCast(data.len);
        try ico.appendSlice(gpa, &ent);
    }
    for (ico_px) |s| try ico.appendSlice(gpa, pngFor(&pngs, s));
    try dir.writeFile(io, .{ .sub_path = "typebud.ico", .data = ico.items });
}
