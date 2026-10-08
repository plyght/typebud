//! Timed scripts for the smoke test and the demo tour: a list of steps run on the main
//! loop through the platform dispatcher, plus a "typist" that injects synthetic key events
//! straight into the app (never into the OS).

const std = @import("std");
const zpui = @import("zpui");
const app_mod = @import("app.zig");

const Typebud = app_mod.Typebud;
const ms = std.time.ns_per_ms;

pub const Step = struct {
    /// Delay before this step runs, measured from the previous step.
    wait_ms: u32 = 0,
    run: *const fn (*Typebud) void,
};

pub const Runner = struct {
    tb: *Typebud,
    steps: []const Step,
    index: usize = 0,
    done: *const fn (*Typebud) void,
    start_ns: u64 = 0,

    pub fn start(r: *Runner) void {
        r.start_ns = r.tb.now();
        r.schedule();
    }

    fn schedule(r: *Runner) void {
        if (r.index >= r.steps.len) return r.done(r.tb);
        const wait: u64 = @as(u64, r.steps[r.index].wait_ms) * ms;
        r.tb.app.platform.dispatcher().dispatchAfter(@max(wait, 1), .{ .ctx = r, .run = tick });
    }

    fn tick(ctx: *anyopaque) void {
        const r: *Runner = @ptrCast(@alignCast(ctx));
        const step = r.steps[r.index];
        r.index += 1;
        step.run(r.tb);
        r.schedule();
    }

    pub fn elapsedS(r: *const Runner) f64 {
        return @as(f64, @floatFromInt(r.tb.now() - r.start_ns)) / std.time.ns_per_s;
    }
};

pub const Pattern = enum {
    /// Letters alternating left / right half of the board.
    alternate,
    /// Mostly letters with spaces every ~5 keys (prose).
    prose,
    /// Letters on the left half only.
    left,
    /// Letters on the right half only.
    right,
    /// Space bar only.
    space,
};

/// Injects `count` key presses `interval_ms` apart (each released 60 ms later).
pub const Typist = struct {
    tb: *Typebud = undefined,
    pattern: Pattern = .alternate,
    interval_ms: u32 = 120,
    left: u32 = 0,
    n: u32 = 0,
    rng: std.Random.DefaultPrng = .init(7),
    pending_up: [8]Up = undefined,
    up_index: usize = 0,
    /// Identifies the current run so a stale timer from a previous run stops.
    run_id: u32 = 0,
    timer_ctx: [4]TimerCtx = undefined,

    const Up = struct { tb: *Typebud, key: zpui.platform.GlobalKeyClass, x: f32 };
    const TimerCtx = struct { t: *Typist, run: u32 };

    pub fn start(t: *Typist, tb: *Typebud, pattern: Pattern, count: u32, interval_ms: u32) void {
        t.tb = tb;
        t.pattern = pattern;
        t.left = count;
        t.interval_ms = interval_ms;
        t.n = 0;
        t.run_id +%= 1;
        const c = &t.timer_ctx[t.run_id % t.timer_ctx.len];
        c.* = .{ .t = t, .run = t.run_id };
        t.press(c);
    }

    pub fn stop(t: *Typist) void {
        t.left = 0;
        t.run_id +%= 1;
    }

    pub fn busy(t: *const Typist) bool {
        return t.left > 0;
    }

    fn press(t: *Typist, c: *TimerCtx) void {
        if (c.run != t.run_id or t.left == 0) return;
        t.left -= 1;
        t.n += 1;
        const r = t.rng.random();
        var key: zpui.platform.GlobalKeyClass = .letter;
        var x: f32 = 0.5;
        switch (t.pattern) {
            .alternate => x = if (t.n % 2 == 0) 0.2 + r.float(f32) * 0.2 else 0.6 + r.float(f32) * 0.25,
            .left => x = 0.1 + r.float(f32) * 0.3,
            .right => x = 0.6 + r.float(f32) * 0.3,
            .space => key = .space,
            .prose => {
                if (t.n % 6 == 0) key = .space else x = r.float(f32) * 0.9 + 0.05;
                if (t.n % 37 == 0) key = .enter;
                if (t.n % 23 == 0) key = .backspace;
            },
        }
        t.tb.handleInput(.{ .kind = .key_down, .key = key, .key_x = x, .timestamp_ns = t.tb.now() });
        const up = &t.pending_up[t.up_index % t.pending_up.len];
        t.up_index += 1;
        up.* = .{ .tb = t.tb, .key = key, .x = x };
        t.tb.app.platform.dispatcher().dispatchAfter(60 * ms, .{ .ctx = up, .run = release });
        if (t.left > 0) {
            // ±15 % timing jitter so it reads like a person.
            const jit = @as(f32, @floatFromInt(t.interval_ms)) * (0.85 + r.float(f32) * 0.3);
            t.tb.app.platform.dispatcher().dispatchAfter(@as(u64, @intFromFloat(jit)) * ms, .{ .ctx = c, .run = onTimer });
        }
    }

    fn onTimer(ctx: *anyopaque) void {
        const c: *TimerCtx = @ptrCast(@alignCast(ctx));
        c.t.press(c);
    }

    fn release(ctx: *anyopaque) void {
        const up: *Up = @ptrCast(@alignCast(ctx));
        up.tb.handleInput(.{ .kind = .key_up, .key = up.key, .key_x = up.x, .timestamp_ns = up.tb.now() });
    }
};
