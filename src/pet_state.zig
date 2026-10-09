//! The pet's animation state machine, driven by global input events and a clock. Pure: no
//! timers or windows here. The app feeds events (`onKey`), asks which frame to show
//! (`frame`), how the body moves (`motion`), whether something animates continuously
//! (`animating`) and when the next state change is due (`nextDeadline`) so it arms exactly
//! one timer — nothing runs while the pet is idle and nothing changes.

const std = @import("std");
const art = @import("art.zig");

const ms = std.time.ns_per_ms;
const s = std.time.ns_per_s;

pub const Timing = struct {
    /// Typing frame → idle after this long without a key.
    idle_after: u64 = 400 * ms,
    /// Keys closer than this count as a chord / burst (both paws).
    burst: u64 = 45 * ms,
    peek_min: u64 = 4 * s,
    peek_max: u64 = 8 * s,
    peek_len: u64 = 150 * ms,
    sip_min: u64 = 5 * s,
    sip_max: u64 = 9 * s,
    sip_len: u64 = 1200 * ms,
    wake_len: u64 = 600 * ms,
    /// Typing must stay above the WPM threshold this long before `excited`.
    excited_after: u64 = 2500 * ms,
    /// Window the typing rate is measured over.
    rate_window: u64 = 3 * s,
    /// Length of the per-keystroke squash.
    bump_len: u64 = 140 * ms,
};

pub const Config = struct {
    /// false: reduce motion — static idle + paw swap only (no peek, sip, sleep, excited, bob).
    animations: bool = true,
    /// 0 = never sleep.
    sleep_after: u64 = 60 * s,
    /// Words per minute (5 keys per word) that count as fast typing.
    excited_wpm: f32 = 75,
    /// A held item is enabled: idle shows `hold` (and sips) instead of `idle` (and peeks).
    holding: bool = false,
};

pub const Mode = enum { idle, typing, excited, sleeping, waking };

pub const KeyClass = enum { letter, digit, space, enter, backspace, tab, modifier, arrow, other };

pub const KeyEvent = struct {
    key: KeyClass = .other,
    /// 0 = far left … 1 = far right; null when the backend cannot tell (alternate paws).
    key_x: ?f32 = null,
    t: u64,
};

const ring_len = 64;

pub const PetState = struct {
    timing: Timing = .{},
    config: Config = .{},
    mode: Mode = .idle,
    paw: enum { left, right, both } = .left,
    alternate: bool = false,
    last_key: u64 = 0,
    /// Last thing that kept the pet awake (key or config change).
    last_activity: u64 = 0,
    /// Start of the current fast-typing streak (0 = none).
    fast_since: u64 = 0,
    wake_until: u64 = 0,
    peek_at: u64 = 0,
    peek_until: u64 = 0,
    sip_at: u64 = 0,
    sip_until: u64 = 0,
    bump_at: u64 = 0,
    keys: [ring_len]u64 = @splat(0),
    key_head: usize = 0,
    key_count: usize = 0,
    rng: std.Random.DefaultPrng = .init(0x7e9bd),
    /// Counts state transitions (lets callers detect a change cheaply).
    generation: u64 = 0,

    pub fn init(now: u64, config: Config) PetState {
        var p: PetState = .{ .config = config, .last_activity = now };
        p.rng = .init(now ^ 0x7e9bd);
        p.scheduleIdleExtras(now);
        return p;
    }

    pub fn setConfig(p: *PetState, now: u64, config: Config) void {
        p.config = config;
        if (!config.animations) {
            if (p.mode == .excited or p.mode == .sleeping or p.mode == .waking) p.mode = .idle;
            p.fast_since = 0;
        }
        p.last_activity = now;
        p.scheduleIdleExtras(now);
        p.generation += 1;
    }

    fn jitter(p: *PetState, lo: u64, hi: u64) u64 {
        return lo + p.rng.random().uintLessThan(u64, @max(hi - lo, 1));
    }

    fn scheduleIdleExtras(p: *PetState, now: u64) void {
        p.peek_until = 0;
        p.sip_until = 0;
        p.peek_at = now + p.jitter(p.timing.peek_min, p.timing.peek_max);
        p.sip_at = now + p.jitter(p.timing.sip_min, p.timing.sip_max);
    }

    fn pushKey(p: *PetState, t: u64) void {
        p.keys[p.key_head] = t;
        p.key_head = (p.key_head + 1) % ring_len;
        p.key_count = @min(p.key_count + 1, ring_len);
    }

    /// Keys per second over the last `window` before `now`.
    pub fn rate(p: *const PetState, now: u64, window: u64) f32 {
        var n: usize = 0;
        for (0..p.key_count) |i| {
            const t = p.keys[(p.key_head + ring_len - 1 - i) % ring_len];
            if (now -| t > window) break;
            n += 1;
        }
        return @as(f32, @floatFromInt(n)) / (@as(f32, @floatFromInt(window)) / s);
    }

    pub fn wpm(p: *const PetState, now: u64) f32 {
        return p.rate(now, p.timing.rate_window) * 60.0 / 5.0;
    }

    /// A key went down (key-ups don't animate).
    pub fn onKey(p: *PetState, e: KeyEvent) void {
        const now = e.t;
        const since_last = now -| p.last_key;
        const was_recent = p.last_key != 0 and since_last < p.timing.burst;
        p.pushKey(now);
        p.last_key = now;
        p.last_activity = now;
        p.peek_until = 0;
        p.sip_until = 0;
        p.generation += 1;
        if (p.config.animations) p.bump_at = now;

        // Paw: space and bursts use both; known positions pick a side; unknown alternates.
        if (e.key == .space or e.key == .enter or was_recent) {
            p.paw = .both;
        } else if (e.key_x) |x| {
            p.paw = if (x < 0.5) .left else .right;
        } else {
            p.alternate = !p.alternate;
            p.paw = if (p.alternate) .left else .right;
        }

        switch (p.mode) {
            .sleeping => {
                if (p.config.animations) {
                    p.mode = .waking;
                    p.wake_until = now + p.timing.wake_len;
                } else p.mode = .typing;
                p.fast_since = 0;
                return;
            },
            .waking => return,
            else => {},
        }
        p.updateExcited(now);
        if (p.mode != .excited) p.mode = .typing;
    }

    fn updateExcited(p: *PetState, now: u64) void {
        if (!p.config.animations) {
            p.fast_since = 0;
            return;
        }
        const fast = p.wpm(now) >= p.config.excited_wpm;
        if (fast) {
            if (p.fast_since == 0) p.fast_since = now;
            if (p.mode != .excited and now - p.fast_since >= p.timing.excited_after) {
                p.mode = .excited;
                p.generation += 1;
            }
        } else if (p.mode == .excited) {
            // Hysteresis: leave once the short-term rate drops below 80 % of the threshold.
            if (p.rate(now, 1500 * ms) * 12.0 < p.config.excited_wpm * 0.8) {
                p.mode = .typing;
                p.fast_since = 0;
                p.generation += 1;
            }
        } else p.fast_since = 0;
    }

    /// Advance time-driven transitions to `now`. Returns true when the shown frame may differ.
    pub fn update(p: *PetState, now: u64) bool {
        const before = p.frame(now);
        const gen = p.generation;
        switch (p.mode) {
            .waking => if (now >= p.wake_until) {
                p.mode = if (now - p.last_key < p.timing.idle_after) .typing else .idle;
                p.last_activity = now;
                p.scheduleIdleExtras(now);
                p.generation += 1;
            },
            .typing, .excited => {
                // A fast streak becomes excited at its deadline (`nextDeadline`) even when
                // no key lands exactly then; excited calms down once the rate drops.
                if (p.mode == .excited or p.fast_since != 0) p.updateExcited(now);
                if (now - p.last_key >= p.timing.idle_after) {
                    p.mode = .idle;
                    p.fast_since = 0;
                    p.scheduleIdleExtras(now);
                    p.generation += 1;
                }
            },
            .idle => {
                if (p.config.animations and p.config.sleep_after > 0 and now - p.last_activity >= p.config.sleep_after) {
                    p.mode = .sleeping;
                    p.peek_until = 0;
                    p.sip_until = 0;
                    p.generation += 1;
                } else if (p.config.animations) {
                    if (p.config.holding) {
                        if (p.sip_until != 0 and now >= p.sip_until) {
                            p.sip_until = 0;
                            p.sip_at = now + p.jitter(p.timing.sip_min, p.timing.sip_max);
                        } else if (p.sip_until == 0 and now >= p.sip_at) {
                            p.sip_until = now + p.timing.sip_len;
                        }
                    } else {
                        if (p.peek_until != 0 and now >= p.peek_until) {
                            p.peek_until = 0;
                            p.peek_at = now + p.jitter(p.timing.peek_min, p.timing.peek_max);
                        } else if (p.peek_until == 0 and now >= p.peek_at) {
                            p.peek_until = now + p.timing.peek_len;
                        }
                    }
                }
            },
            .sleeping => {},
        }
        return gen != p.generation or before != p.frame(now);
    }

    /// The frame to show at `now` (call `update` first).
    pub fn frame(p: *const PetState, now: u64) art.Frame {
        return switch (p.mode) {
            .sleeping => .sleep,
            .waking => .wake,
            .excited => .excited,
            .typing => switch (p.paw) {
                .left => .type_left,
                .right => .type_right,
                .both => .type_both,
            },
            .idle => if (p.config.holding)
                (if (p.sip_until != 0 and now < p.sip_until) art.Frame.sip else art.Frame.hold)
            else if (p.peek_until != 0 and now < p.peek_until) .peek else .idle,
        };
    }

    /// When the next time-driven transition is due (null = nothing scheduled: fully idle).
    pub fn nextDeadline(p: *const PetState, now: u64) ?u64 {
        var best: ?u64 = null;
        const consider = struct {
            fn f(b: *?u64, t: u64, n: u64) void {
                if (t <= n) return;
                if (b.* == null or t < b.*.?) b.* = t;
            }
        }.f;
        switch (p.mode) {
            .waking => consider(&best, p.wake_until, now),
            .typing => {
                consider(&best, p.last_key + p.timing.idle_after, now);
                // A fast streak becomes excited without another key needing to arrive.
                if (p.fast_since != 0 and p.config.animations) consider(&best, p.fast_since + p.timing.excited_after, now);
            },
            .excited => {
                consider(&best, p.last_key + p.timing.idle_after, now);
                consider(&best, now + 250 * ms, now);
            },
            .idle => {
                if (p.config.animations) {
                    if (p.config.sleep_after > 0) consider(&best, p.last_activity + p.config.sleep_after, now);
                    if (p.config.holding) {
                        consider(&best, if (p.sip_until != 0) p.sip_until else p.sip_at, now);
                    } else {
                        consider(&best, if (p.peek_until != 0) p.peek_until else p.peek_at, now);
                    }
                }
            },
            .sleeping => {},
        }
        return best;
    }

    /// Body bob / squash at `now` (viewBox units).
    pub fn motion(p: *const PetState, now: u64) struct { dy: f32, squash: f32 } {
        if (!p.config.animations) return .{ .dy = 0, .squash = 0 };
        var dy: f32 = 0;
        var squash: f32 = 0;
        if (p.bump_at != 0 and now -| p.bump_at < p.timing.bump_len) {
            const t = @as(f32, @floatFromInt(now - p.bump_at)) / @as(f32, @floatFromInt(p.timing.bump_len));
            const k = (1 - t) * (1 - t);
            squash = 0.025 * k;
            dy = 1.2 * k;
        }
        if (p.mode == .excited) {
            const phase = @as(f32, @floatFromInt(now % (400 * ms))) / @as(f32, 400 * ms);
            dy -= 3.0 * @abs(@sin(phase * std.math.pi));
        }
        return .{ .dy = dy, .squash = squash };
    }

    /// Something moves continuously (keep requesting frames until this turns false).
    pub fn animating(p: *const PetState, now: u64) bool {
        if (!p.config.animations) return false;
        if (p.mode == .excited) return true;
        return p.bump_at != 0 and now -| p.bump_at < p.timing.bump_len;
    }
};

// ---- tests ------------------------------------------------------------------------------

const testing = std.testing;

fn typeKeys(p: *PetState, start: u64, n: usize, gap: u64) u64 {
    var t = start;
    for (0..n) |i| {
        p.onKey(.{ .key = .letter, .key_x = if (i % 2 == 0) 0.2 else 0.8, .t = t });
        _ = p.update(t);
        t += gap;
    }
    return t - gap;
}

test "typing frames follow key position, idle after 400 ms" {
    var p = PetState.init(1 * s, .{});
    p.onKey(.{ .key = .letter, .key_x = 0.1, .t = 2 * s });
    try testing.expectEqual(art.Frame.type_left, p.frame(2 * s));
    p.onKey(.{ .key = .letter, .key_x = 0.9, .t = 2 * s + 200 * ms });
    try testing.expectEqual(art.Frame.type_right, p.frame(2 * s + 200 * ms));
    p.onKey(.{ .key = .space, .t = 2 * s + 400 * ms });
    try testing.expectEqual(art.Frame.type_both, p.frame(2 * s + 400 * ms));
    try testing.expectEqual(@as(?u64, 2 * s + 800 * ms), p.nextDeadline(2 * s + 400 * ms));
    _ = p.update(2 * s + 799 * ms);
    try testing.expectEqual(Mode.typing, p.mode);
    _ = p.update(2 * s + 800 * ms);
    try testing.expectEqual(art.Frame.idle, p.frame(2 * s + 800 * ms));
}

test "unknown key positions alternate paws; bursts use both" {
    var p = PetState.init(0, .{});
    p.onKey(.{ .t = 1 * s });
    const a = p.frame(1 * s);
    p.onKey(.{ .t = 1 * s + 100 * ms });
    const b = p.frame(1 * s + 100 * ms);
    try testing.expect(a != b);
    try testing.expect(a == .type_left or a == .type_right);
    p.onKey(.{ .t = 1 * s + 120 * ms });
    try testing.expectEqual(art.Frame.type_both, p.frame(1 * s + 120 * ms));
}

test "sustained fast typing gets excited, slowing down calms it" {
    var p = PetState.init(0, .{ .excited_wpm = 60 });
    // 10 keys/s = 120 WPM for 5 s.
    const end = typeKeys(&p, 1 * s, 50, 100 * ms);
    try testing.expectEqual(art.Frame.excited, p.frame(end));
    try testing.expect(p.animating(end));
    // Slow typing (2 keys/s = 24 WPM) for 3 s drops back to typing.
    const end2 = typeKeys(&p, end + 500 * ms, 6, 300 * ms) ;
    _ = p.update(end2 + 1 * s);
    _ = p.update(end2 + 1 * s);
    try testing.expect(p.mode == .idle);
    try testing.expect(p.frame(end2 + 1 * s) == .idle or p.frame(end2 + 1 * s) == .peek);
}

test "a fast streak turns excited at its deadline without another key" {
    var p = PetState.init(0, .{ .excited_wpm = 60 });
    // 10 keys/s: the rate crosses 60 WPM (3 keys/s over 3 s) at the 9th key.
    var t: u64 = 1 * s;
    while (p.fast_since == 0) : (t += 100 * ms) p.onKey(.{ .key = .letter, .t = t });
    const due = p.fast_since + p.timing.excited_after;
    // Keep typing up to just before the deadline, then the timer fires between keys.
    while (t + 100 * ms < due) : (t += 100 * ms) p.onKey(.{ .key = .letter, .t = t });
    try testing.expectEqual(Mode.typing, p.mode);
    try testing.expectEqual(@as(?u64, due), p.nextDeadline(t - 100 * ms));
    _ = p.update(due);
    try testing.expectEqual(art.Frame.excited, p.frame(due));
}

test "coarse timer: keys bunched on 15.6 ms ticks with stretched gaps still get excited" {
    // A Windows-style 15.625 ms timer tick: every key timestamp lands on a tick and each
    // nominal 85 ms (±15 %) gap is rounded up to whole ticks, like a Sleep()-driven burst.
    const tick: u64 = 15_625_000;
    var p = PetState.init(0, .{ .excited_wpm = 50 });
    var rng: std.Random.DefaultPrng = .init(7);
    var t: u64 = 64 * tick;
    var excited_at: ?u64 = null;
    for (0..60) |_| {
        p.onKey(.{ .key = .letter, .key_x = rng.random().float(f32), .t = t });
        _ = p.update(t);
        if (excited_at == null and p.mode == .excited) excited_at = t;
        const gap: u64 = @intFromFloat(85.0 * @as(f64, ms) * (0.85 + rng.random().float(f64) * 0.3));
        t += (gap + tick - 1) / tick * tick;
        // The pet's timer can only fire on a tick too.
        if (p.nextDeadline(t - tick)) |d| if (d < t) {
            _ = p.update((d + tick - 1) / tick * tick);
        };
    }
    try testing.expect(excited_at != null);
    // From cold: ~1.2 s until the 3 s window holds 50 WPM, then `excited_after` (2.5 s).
    try testing.expect(excited_at.? - 64 * tick <= 4 * s);
    try testing.expectEqual(Mode.excited, p.mode);
}

test "slow typing never gets excited" {
    var p = PetState.init(0, .{ .excited_wpm = 75 });
    const end = typeKeys(&p, 1 * s, 30, 250 * ms); // 48 WPM
    try testing.expect(p.mode == .typing);
    _ = end;
}

test "peek every 4-8 s for 150 ms; nothing else scheduled while idle" {
    var p = PetState.init(0, .{ .sleep_after = 0 });
    const d = p.nextDeadline(0).?;
    try testing.expect(d >= 4 * s and d < 8 * s);
    _ = p.update(d);
    try testing.expectEqual(art.Frame.peek, p.frame(d));
    try testing.expectEqual(@as(?u64, d + 150 * ms), p.nextDeadline(d));
    _ = p.update(d + 150 * ms);
    try testing.expectEqual(art.Frame.idle, p.frame(d + 150 * ms));
    const d2 = p.nextDeadline(d + 150 * ms).?;
    try testing.expect(d2 >= d + 150 * ms + 4 * s);
}

test "sleep after N s idle, wake frame on the next key, no timers while asleep" {
    var p = PetState.init(0, .{ .sleep_after = 60 * s });
    var t: u64 = 0;
    while (p.nextDeadline(t)) |d| {
        t = d;
        _ = p.update(t);
        if (p.mode == .sleeping) break;
    }
    try testing.expectEqual(@as(u64, 60 * s), t);
    try testing.expectEqual(art.Frame.sleep, p.frame(t));
    try testing.expectEqual(@as(?u64, null), p.nextDeadline(t));
    try testing.expect(!p.animating(t + 10 * s));
    p.onKey(.{ .key = .letter, .key_x = 0.3, .t = 100 * s });
    try testing.expectEqual(art.Frame.wake, p.frame(100 * s));
    _ = p.update(100 * s + 600 * ms);
    try testing.expectEqual(art.Frame.idle, p.frame(100 * s + 600 * ms));
}

test "held item: hold frame with sips while idle" {
    var p = PetState.init(0, .{ .holding = true, .sleep_after = 0 });
    try testing.expectEqual(art.Frame.hold, p.frame(0));
    const d = p.nextDeadline(0).?;
    try testing.expect(d >= 5 * s and d < 9 * s);
    _ = p.update(d);
    try testing.expectEqual(art.Frame.sip, p.frame(d));
    _ = p.update(d + 1200 * ms);
    try testing.expectEqual(art.Frame.hold, p.frame(d + 1200 * ms));
    p.onKey(.{ .key = .letter, .key_x = 0.7, .t = d + 2 * s });
    try testing.expectEqual(art.Frame.type_right, p.frame(d + 2 * s));
}

test "reduce motion: idle and paw swaps only" {
    var p = PetState.init(0, .{ .animations = false, .sleep_after = 10 * s, .excited_wpm = 30 });
    try testing.expectEqual(@as(?u64, null), p.nextDeadline(0));
    const end = typeKeys(&p, 1 * s, 40, 100 * ms);
    try testing.expect(p.frame(end) == .type_left or p.frame(end) == .type_right or p.frame(end) == .type_both);
    try testing.expect(!p.animating(end));
    try testing.expectEqual(@as(f32, 0), p.motion(end).dy);
    _ = p.update(end + 1 * s);
    try testing.expectEqual(art.Frame.idle, p.frame(end + 1 * s));
    _ = p.update(end + 100 * s);
    try testing.expectEqual(art.Frame.idle, p.frame(end + 100 * s));
}

test "keystroke bump decays within 140 ms" {
    var p = PetState.init(0, .{});
    p.onKey(.{ .key = .letter, .key_x = 0.2, .t = 5 * s });
    try testing.expect(p.animating(5 * s + 10 * ms));
    try testing.expect(p.motion(5 * s).squash > 0);
    try testing.expect(!p.animating(5 * s + 140 * ms));
}
