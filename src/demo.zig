const app_mod = @import("app.zig");
pub fn start(tb: *app_mod.Typebud, code: *u8) void {
    _ = code;
    tb.launch();
}
