#!/usr/bin/env python3
"""Validate typebud sound packs and render a typing demo for each.

  python3 scripts/sounds/preview.py [--packs sounds/packs] [--out sounds/preview] [--seed 7]

For every sounds/packs/<id>/pack.json this
  * checks the pack against sounds/FORMAT.md (fields, files present, 48 kHz
    mono 16-bit PCM WAV, generic keydown pool present),
  * measures every sample: onset offset (time from sample start to the first
    point where the 0.25 ms envelope reaches -20 dB re its peak), peak, strike
    loudness, length,
  * renders sounds/preview/<id>.wav: a few seconds of realistic typing (rolled
    inter-key timing, shifted capitals, a typo fixed with backspace, Enter),
    using the same pool resolution, random variant choice, gain jitter, pitch
    jitter and key-up handling the app is expected to implement,
  * reports integrated / max short-term loudness (BS.1770 via pyloudnorm) and
    peak of each preview.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(HERE))
import import_pack as ip  # noqa: E402

SR = 48000
TEXT = "Hello there! typebud is lsi\b\b\bistening to you type.\nNice and cozy :)\n"
PREVIEW_CEILING_DB = -1.0
SHIFTED = set('ABCDEFGHIJKLMNOPQRSTUVWXYZ!:)?"')


def key_class(ch: str) -> str:
    if ch == " ":
        return "space"
    if ch == "\n":
        return "enter"
    if ch == "\b":
        return "backspace"
    if ch.isalpha():
        return "letter"
    if ch.isdigit():
        return "digit"
    return "other"


def resolve(sounds: dict, direction: str, cls: str) -> list[str]:
    """FORMAT.md section 'Choosing a sample': class pool, else generic, else nothing."""
    d = sounds.get(direction, {})
    return d.get(cls) or d.get("generic") or []


def validate(pack_dir: Path) -> tuple[dict, list[str]]:
    errs = []
    pj = json.loads((pack_dir / "pack.json").read_text())
    for k in ("format", "format_version", "id", "name", "author", "license", "sounds"):
        if k not in pj:
            errs.append(f"missing field {k}")
    if pj.get("format") != ip.FORMAT_ID or pj.get("format_version") != ip.FORMAT_VERSION:
        errs.append("bad format/format_version")
    if pj.get("id") != pack_dir.name:
        errs.append("id does not match folder name")
    if not pj.get("sounds", {}).get("down", {}).get("generic"):
        errs.append("down.generic missing or empty")
    for direction, pools in pj.get("sounds", {}).items():
        if direction not in ("down", "up"):
            errs.append(f"unknown direction {direction}")
        for pool, files in pools.items():
            if pool not in ip.POOLS:
                errs.append(f"unknown pool {pool}")
            for f in files:
                p = pack_dir / f
                if not p.exists():
                    errs.append(f"missing {f}")
                    continue
                info = sf.info(str(p))
                if (info.samplerate, info.channels, info.subtype, info.format) != (SR, 1, "PCM_16", "WAV"):
                    errs.append(f"{f}: {info.samplerate} Hz {info.channels} ch {info.subtype} {info.format}")
    if pj.get("license_file") and not (pack_dir / pj["license_file"]).exists():
        errs.append("license_file missing")
    return pj, errs


def analyze_sample(x: np.ndarray) -> dict:
    env = np.sqrt(np.convolve(x * x, np.ones(12) / 12, mode="same"))
    onset = int(np.argmax(env >= env.max() * 0.1))
    return {"onset_ms": onset / SR * 1000, "peak_db": float(ip.db(np.abs(x).max())),
            "strike": ip.strike_lufs(x), "len_ms": len(x) / SR * 1000,
            "first_sample_db": float(ip.db(abs(x[0]) + 1e-9))}


def pitch_shift(x: np.ndarray, cents: float) -> np.ndarray:
    if not cents:
        return x
    r = 2 ** (cents / 1200)
    n = int(len(x) / r)
    return np.interp(np.arange(n) * r, np.arange(len(x)), x)


def render(pack_dir: Path, pj: dict, rng: np.random.Generator) -> np.ndarray:
    cache = {}

    def load(f):
        if f not in cache:
            cache[f] = sf.read(str(pack_dir / f), dtype="float64")[0]
        return cache[f]

    pb = pj.get("playback", {})
    gj, pj_c = pb.get("gain_jitter_db", 0.0), pb.get("pitch_jitter_cents", 0)
    events = []  # (time_s, direction, class)
    t = 0.35
    for ch in TEXT:
        cls = key_class(ch)
        if ch in SHIFTED:
            events.append((t - 0.06, "down", "modifier"))
            events.append((t + 0.12, "up", "modifier"))
        hold = rng.uniform(0.065, 0.11) * (1.3 if cls == "space" else 1.0)
        events.append((t, "down", cls))
        events.append((t + hold, "up", cls))
        gap = float(np.exp(rng.normal(np.log(0.13), 0.33)))
        if cls in ("space", "enter"):
            gap += rng.uniform(0.04, 0.12)
        if cls == "enter":
            gap += 0.35
        if ch == "\b":
            gap = rng.uniform(0.11, 0.15)  # backspace auto-ish rhythm
        t += gap
    out = np.zeros(int((t + 0.5) * SR))
    last = {}
    for when, direction, cls in sorted(events):
        files = resolve(pj["sounds"], direction, cls)
        if not files:
            continue
        key = (direction, cls)
        choices = [f for f in files if f != last.get(key)] or files
        f = choices[rng.integers(len(choices))]
        last[key] = f
        x = pitch_shift(load(f), rng.uniform(-pj_c, pj_c)) * 10 ** (rng.uniform(-gj, gj) / 20)
        i = int(when * SR)
        out[i:i + len(x)] += x[: len(out) - i]
    return out


def main(argv=None) -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--packs", default=str(REPO / "sounds" / "packs"))
    ap.add_argument("--out", default=str(REPO / "sounds" / "preview"))
    ap.add_argument("--seed", type=int, default=7)
    a = ap.parse_args(argv)
    import pyloudnorm as pyln

    meter = pyln.Meter(SR)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    print(f"{'pack':20s} {'n':>3s} {'onset ms (min/med/max)':>23s} {'1st smp':>8s} {'peak dBFS':>10s} "
          f"{'strike LUFS d/u':>16s} {'preview LUFS':>12s} {'ST max':>7s} {'pk dBFS':>8s} {'KiB':>6s}")
    for pack_dir in sorted(p for p in Path(a.packs).iterdir() if (p / "pack.json").exists()):
        pj, errs = validate(pack_dir)
        if errs:
            print(f"{pack_dir.name}: INVALID: {errs}")
            continue
        stats = {"down": [], "up": []}
        for direction, pools in pj["sounds"].items():
            for files in pools.values():
                for f in files:
                    stats[direction].append(analyze_sample(sf.read(str(pack_dir / f), dtype="float64")[0]))
        allst = stats["down"] + stats["up"]
        on = np.array([s["onset_ms"] for s in allst])
        pk = max(s["peak_db"] for s in allst)
        sd = np.median([s["strike"] for s in stats["down"]])
        su = np.median([s["strike"] for s in stats["up"]]) if stats["up"] else float("nan")
        fs = max(s["first_sample_db"] for s in allst)
        y = render(pack_dir, pj, np.random.default_rng(a.seed))
        # Overlapping strikes (key-down of the next key during the previous
        # key's tail, shift + letter) can sum above full scale. The app's mixer
        # needs headroom / a limiter for the same reason; the preview just
        # scales the whole render down so its peak sits at PREVIEW_CEILING_DB.
        raw_pk = float(ip.db(np.abs(y).max()))
        trim_db = min(0.0, PREVIEW_CEILING_DB - raw_pk)
        y = y * 10 ** (trim_db / 20)
        sf.write(str(out / f"{pj['id']}.wav"), y, SR, subtype="PCM_16")
        integ = meter.integrated_loudness(y)
        hop, win = int(0.1 * SR), int(3.0 * SR)
        st = max(meter.integrated_loudness(y[i:i + win]) for i in range(0, max(1, len(y) - win), hop)) \
            if len(y) > win else integ
        size = sum(p.stat().st_size for p in pack_dir.rglob("*") if p.is_file())
        print(f"{pj['id']:20s} {len(allst):3d} {on.min():7.2f}/{np.median(on):5.2f}/{on.max():5.2f}      "
              f"{fs:8.1f} {pk:10.1f} {sd:8.1f}/{su:6.1f} {integ:12.1f} {st:7.1f} {ip.db(np.abs(y).max()):8.1f} "
              f"{size / 1024:6.0f}  sum pk {raw_pk:+5.1f} dBFS" + (f" (scaled {trim_db:+.1f} dB)" if trim_db else "")
              + f"  ({len(y) / SR:.1f} s)")


if __name__ == "__main__":
    main()
