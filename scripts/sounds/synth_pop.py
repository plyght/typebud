#!/usr/bin/env python3
"""Procedurally generated "bubble pop" pack (typebud original, CC0-1.0).

Each pop is a damped sine whose pitch rises while it decays, which is what a
small air bubble resonating at the water surface sounds like (Minnaert
resonance with a rising frequency as the bubble shrinks). A very short noise
tick in front gives the attack some definition. Everything is deterministic
(fixed seeds) so rebuilding produces identical files.

Called by import_pack.py (recipe entry with "generator": "synth_pop"); the
output then goes through the same trimming / loudness chain as recorded packs.
"""
from __future__ import annotations

import numpy as np


def bubble(sr: int, f0: float, rise: float, tau_ms: float, dur_ms: float = 120.0,
           tick: float = 0.15, seed: int = 0, sweep_ms: float = 40.0) -> np.ndarray:
    n = int(sr * dur_ms / 1000)
    t = np.arange(n) / sr
    # frequency rises by `rise` (fraction of f0) over sweep_ms, then holds
    f = f0 * (1.0 + rise * np.clip(t / (sweep_ms / 1000), 0, 1))
    phase = 2 * np.pi * np.cumsum(f) / sr
    env = np.exp(-t / (tau_ms / 1000))
    att = np.clip(t / 0.0006, 0, 1)  # 0.6 ms attack: soft enough not to click, fast enough to feel instant
    y = np.sin(phase) * env * att
    rng = np.random.default_rng(seed)
    nt = int(sr * 0.0015)
    noise = rng.standard_normal(nt) * np.hanning(nt * 2)[nt:]
    # high-passed tick (first difference) for a little "plk"
    noise = np.diff(noise, prepend=0.0)
    y[:nt] += tick * noise
    return y / np.max(np.abs(y))


def generate(sr: int = 48000) -> dict:
    down_generic = [bubble(sr, f0, rise=0.55, tau_ms=16 + 2 * (i % 3), seed=i)
                    for i, f0 in enumerate((620, 655, 690, 720, 745, 770, 800, 830))]
    up_generic = [0.55 * bubble(sr, f0, rise=0.35, tau_ms=7, dur_ms=60, tick=0.05, seed=100 + i)
                  for i, f0 in enumerate((1450, 1540, 1620, 1700))]
    space = [bubble(sr, f0, rise=0.6, tau_ms=32, dur_ms=200, seed=200 + i, sweep_ms=60)
             for i, f0 in enumerate((380, 405))]
    space_up = [0.5 * bubble(sr, 980, rise=0.3, tau_ms=9, dur_ms=60, tick=0.05, seed=250)]
    # enter: two bubbles in quick succession, low then high
    e1 = bubble(sr, 520, rise=0.5, tau_ms=20, dur_ms=180, seed=300)
    e2 = bubble(sr, 820, rise=0.5, tau_ms=22, dur_ms=135, seed=301)
    off = int(sr * 0.045)
    enter = e1.copy()
    enter[off:off + len(e2)] += 0.9 * e2[: len(enter) - off]
    enter /= np.max(np.abs(enter))
    # backspace: falling "bwoop"
    backspace = [bubble(sr, 900, rise=-0.42, tau_ms=24, dur_ms=150, seed=400, sweep_ms=70)]
    modifier = [0.8 * bubble(sr, f0, rise=0.25, tau_ms=10, dur_ms=80, tick=0.08, seed=500 + i)
                for i, f0 in enumerate((450, 480))]
    return {
        "down": {"generic": down_generic, "space": space, "enter": [enter],
                 "backspace": backspace, "modifier": modifier},
        "up": {"generic": up_generic, "space": space_up},
    }


if __name__ == "__main__":
    import sys
    import soundfile as sf
    out = sys.argv[1] if len(sys.argv) > 1 else "bubble_pop_raw.wav"
    g = generate()
    gap = np.zeros(int(48000 * 0.15))
    seq = []
    for direction in g.values():
        for arrs in direction.values():
            for a in arrs:
                seq += [a * 0.5, gap]
    sf.write(out, np.concatenate(seq), 48000, subtype="PCM_16")
    print("wrote", out)
