//! The "Show WPM" bubble's meter: typing speed in words per minute (5 characters a word)
//! over a rolling window of recent keystrokes. Pure, like pet_state: the app feeds key
//! times, asks what to show, and arms one timer for `deadline` (when the bubble hides).
//!
//! The shown number changes at most every `refresh` while typing and never between keys,
//! so the bubble costs no frames of its own: the pet redraws on each key anyway, and once
//! typing stops the only work left is the one timer that hides it.

const std = @import("std");

const ms = std.time.ns_per_ms;
const s = std.time.ns_per_s;

/// Keys that count as typed characters (the macOS counter mode reports `.other`).
pub fn countsKey(key: anytype) bool {
    return switch (key) {
        .letter, .digit, .space, .enter, .other => true,
        .backspace, .tab, .modifier, .arrow => false,
    };
}

const ring_len = 256;

pub const Meter = struct {
    /// Keys older than this no longer count.
    window: u64 = 12 * s,
    /// A pause this long starts a new streak: keys before it no longer count.
    pause: u64 = 2 * s,
    /// Shortest span the rate is measured over (a short burst does not read as 300 WPM).
    min_span: u64 = 1500 * ms,
    /// Keys in the window before the bubble appears.
    min_keys: usize = 6,
    /// No key for this long: the bubble hides.
    hide_after: u64 = 3 * s,
    /// The shown number updates at most this often.
    refresh: u64 = 500 * ms,

    keys: [ring_len]u64 = @splat(0),
    head: usize = 0,
    count: usize = 0,
    last_key: u64 = 0,
    /// The number on the bubble; null = hidden.
    shown: ?u16 = null,
    shown_at: u64 = 0,

    /// A counted key at `t`. True when the bubble changed (appeared or a new number).
    pub fn onKey(m: *Meter, t: u64) bool {
        m.keys[m.head] = t;
        m.head = (m.head + 1) % ring_len;
        m.count = @min(m.count + 1, ring_len);
        m.last_key = t;
        if (m.inWindow(t) < m.min_keys) return false;
        if (m.shown != null and t -| m.shown_at < m.refresh) return false;
        const v: u16 = @intFromFloat(@min(@round(m.wpm(t)), 999));
        m.shown_at = t;
        if (m.shown == v) return false;
        m.shown = v;
        return true;
    }

    /// Hide once idle. True when the bubble changed.
    pub fn update(m: *Meter, now: u64) bool {
        if (m.shown == null or now -| m.last_key < m.hide_after) return false;
        m.shown = null;
        return true;
    }

    /// When `update` has something to do (the bubble hiding), or null.
    pub fn deadline(m: *const Meter) ?u64 {
        if (m.shown == null) return null;
        return m.last_key + m.hide_after;
    }

    /// Words per minute at `now` over the current streak (the keys since the last
    /// pause, at most `window` back).
    pub fn wpm(m: *const Meter, now: u64) f32 {
        const r = m.streak(now);
        if (r.n == 0) return 0;
        const span: f32 = @floatFromInt(@max(now -| r.oldest, m.min_span));
        const cps = @as(f32, @floatFromInt(r.n)) / (span / s);
        return cps * 60.0 / 5.0;
    }

    fn inWindow(m: *const Meter, now: u64) usize {
        return m.streak(now).n;
    }

    fn streak(m: *const Meter, now: u64) struct { n: usize, oldest: u64 } {
        var n: usize = 0;
        var oldest: u64 = now;
        var newer: u64 = now;
        for (0..m.count) |i| {
            const t = m.keys[(m.head + ring_len - 1 - i) % ring_len];
            if (now -| t > m.window or newer -| t > m.pause) break;
            n += 1;
            oldest = t;
            newer = t;
        }
        return .{ .n = n, .oldest = oldest };
    }
};

test "steady typing reads its speed" {
    var m: Meter = .{};
    // 60 WPM = 5 characters a second.
    var t: u64 = 1 * s;
    for (0..60) |_| {
        _ = m.onKey(t);
        t += 200 * ms;
    }
    const v = m.shown.?;
    try std.testing.expect(v >= 57 and v <= 63);
}

test "a few keys do not show the bubble; idle hides it" {
    var m: Meter = .{};
    _ = m.onKey(1 * s);
    _ = m.onKey(1 * s + 100 * ms);
    try std.testing.expect(m.shown == null);
    try std.testing.expect(m.deadline() == null);
    var t: u64 = 2 * s;
    for (0..10) |_| {
        _ = m.onKey(t);
        t += 150 * ms;
    }
    try std.testing.expect(m.shown != null);
    const d = m.deadline().?;
    try std.testing.expect(!m.update(d - 1));
    try std.testing.expect(m.update(d));
    try std.testing.expect(m.shown == null and m.deadline() == null);
}

test "the number changes at most every refresh" {
    var m: Meter = .{};
    var t: u64 = 1 * s;
    var changes: usize = 0;
    for (0..100) |i| {
        if (m.onKey(t)) changes += 1;
        t += if (i % 2 == 0) 90 * ms else 160 * ms; // ~10 s of uneven typing
    }
    try std.testing.expect(changes <= 26);
}

test "a pause starts over" {
    var m: Meter = .{};
    var t: u64 = 1 * s;
    for (0..30) |_| { // a fast burst
        _ = m.onKey(t);
        t += 80 * ms;
    }
    t += 5 * s;
    for (0..30) |_| { // then 60 WPM
        _ = m.onKey(t);
        t += 200 * ms;
    }
    const v = m.shown.?;
    try std.testing.expect(v >= 56 and v <= 64);
}

test "counted keys" {
    const K = enum { letter, digit, space, enter, backspace, tab, modifier, arrow, other };
    try std.testing.expect(countsKey(K.letter) and countsKey(K.other) and countsKey(K.space));
    try std.testing.expect(!countsKey(K.modifier) and !countsKey(K.arrow) and !countsKey(K.backspace));
}
