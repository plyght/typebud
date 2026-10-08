#!/usr/bin/env python3
"""Convert keyboard sound packs into typebud's pack format (see sounds/FORMAT.md).

Usage
-----
  # Import any Mechvibes (v1 / v2), MechvibesDX (config_version 2), Thock or
  # kbsim-style pack folder:
  python3 scripts/sounds/import_pack.py import PATH/TO/PACK OUT/DIR [--id ID] [--name NAME] ...
  # The pack id defaults to OUT/DIR's folder name; with --id ID that differs
  # from it, the pack is written to OUT/DIR/ID instead.

  # Rebuild every bundled pack listed in scripts/sounds/default_packs.json.
  # Upstream repositories are cloned (shallow, pinned commit) into --sources.
  python3 scripts/sounds/import_pack.py defaults --sources /tmp/typebud-sound-src

Every sample goes through the same chain:
  decode -> mono -> resample to 48 kHz -> 20 Hz high-pass -> trim leading
  silence (the -20 dB-re-peak onset lands 1.0 ms after sample start, with a
  half-Hann fade over that pre-roll) -> trim tail at the noise floor and fade
  out -> per-class level smoothing (variants kept within +/-2 dB of the class
  median) -> one gain for the whole pack so the median keydown "strike
  loudness" hits the target -> per-sample peak ceiling -> 16-bit TPDF-dithered
  PCM WAV.

"Strike loudness" is BS.1770 K-weighted mean-square energy over a fixed 50 ms
window starting at the sample start, in LUFS. A fixed window makes the number
independent of how long a sample's tail happens to be, which plain integrated
LUFS of a 70 ms clip is not.

Only numpy, scipy and soundfile are needed (pip install numpy scipy soundfile).
Source packs are treated as data: nothing from them is executed.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy import signal

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent

SR = 48000
FORMAT_ID = "typebud.soundpack"
FORMAT_VERSION = 1

# Must match the app's GlobalKeyClass enum, plus the "generic" fallback pool.
KEY_CLASSES = ("letter", "digit", "space", "enter", "backspace", "tab", "modifier", "arrow", "other")
POOLS = ("generic",) + KEY_CLASSES

DEFAULTS = dict(
    target_lufs=-23.0,      # median keydown strike loudness of every pack
    peak_ceiling_db=-1.0,   # no sample may exceed this after gain
    class_spread_db=2.0,    # variants within a class are pulled to +/- this of the class median
    special_max_db=4.0,     # space/enter/... keydown classes at most this much louder than generic keydown
    up_max_db=0.0,          # keyup classes at most this loud relative to generic keydown
    preroll_ms=1.0,         # silence kept before the onset (faded in)
    max_down_ms=260.0,
    max_up_ms=200.0,
    fade_out_ms=12.0,
    tail_floor_db=-48.0,    # tail ends where the 5 ms envelope drops below peak + this ...
    tail_noise_margin_db=6.0,  # ... or below noise floor + this, whichever is higher
    max_generic=8,          # variant caps when importing large per-key packs
    max_special=3,
)

# --------------------------------------------------------------------------
# key-code -> GlobalKeyClass tables


def _iohook_class_table() -> dict[int, str]:
    """libuiohook / iohook virtual codes, as used by Mechvibes v1/v2 configs.

    The low codes equal PC scan-code set 1, which is also what bucklespring
    names its sample files after.
    """
    t: dict[int, str] = {}
    letters = list(range(16, 26)) + list(range(30, 39)) + list(range(44, 51))
    for c in letters:
        t[c] = "letter"
    for c in range(2, 12):
        t[c] = "digit"
    t[57] = "space"
    t[28] = "enter"
    t[3612] = "enter"      # numpad enter
    t[14] = "backspace"
    t[15] = "tab"
    for c in (42, 54, 29, 3613, 56, 3640, 3675, 3676, 3677, 58):
        t[c] = "modifier"  # shift, ctrl, alt, meta, menu, caps lock
    for c in (57416, 57419, 57421, 57424, 61000, 61003, 61005, 61008):
        t[c] = "arrow"
    return t


IOHOOK_CLASS = _iohook_class_table()


def iohook_class(code: int) -> str:
    return IOHOOK_CLASS.get(code, "other")


def w3c_class(code: str) -> str:
    """KeyboardEvent.code names, as used by MechvibesDX."""
    if re.fullmatch(r"Key[A-Z]", code):
        return "letter"
    if re.fullmatch(r"Digit[0-9]", code):
        return "digit"
    if code == "Space":
        return "space"
    if code in ("Enter", "NumpadEnter"):
        return "enter"
    if code == "Backspace":
        return "backspace"
    if code == "Tab":
        return "tab"
    if re.match(r"(Shift|Control|Alt|Meta|OS)(Left|Right)$", code) or code in ("CapsLock", "ContextMenu", "Fn"):
        return "modifier"
    if code.startswith("Arrow"):
        return "arrow"
    return "other"


def pool_for(cls: str) -> str:
    """Letters, digits and other printable keys share the generic pool on import."""
    return "generic" if cls in ("letter", "digit", "other") else cls


# --------------------------------------------------------------------------
# source description


@dataclass
class Source:
    """One source sound: a whole file, or a [start, end) window of a sprite."""
    path: Path
    start_ms: float | None = None
    end_ms: float | None = None

    def key(self):
        return (str(self.path), self.start_ms, self.end_ms)


@dataclass
class PackSpec:
    meta: dict
    # sounds[direction][pool] -> list[Source]
    sounds: dict = field(default_factory=lambda: {"down": {}, "up": {}})
    synth: dict | None = None  # sounds[direction][pool] -> list[np.ndarray] (already 48 kHz)

    def add(self, direction: str, pool: str, src: Source):
        lst = self.sounds[direction].setdefault(pool, [])
        if src.key() not in [s.key() for s in lst]:
            lst.append(src)


# --------------------------------------------------------------------------
# readers for foreign pack formats


def _expand_range(pattern: str) -> list[str]:
    """Mechvibes v2 'press/GENERIC_R{0-4}.mp3' -> all five names."""
    m = re.search(r"\{(\d+)-(\d+)\}", pattern)
    if not m:
        return [pattern]
    a, b = int(m.group(1)), int(m.group(2))
    return [pattern[: m.start()] + str(i) + pattern[m.end():] for i in range(a, b + 1)]


def _resolve(base: Path, rel: str) -> Path:
    p = (base / rel).resolve()
    if base.resolve() not in p.parents and p != base.resolve():
        raise ValueError(f"path escapes pack folder: {rel}")
    if not p.exists():
        # Some packs differ in case from their config on case-insensitive OSes.
        for cand in p.parent.glob("*"):
            if cand.name.lower() == p.name.lower():
                return cand
        raise FileNotFoundError(p)
    return p


def read_mechvibes(folder: Path, cfg: dict) -> PackSpec:
    """Mechvibes config.json, version 1 (single / multi) and version 2."""
    version = int(cfg.get("version", 1) or 1)
    kind = cfg.get("key_define_type", "single")
    defines = cfg.get("defines", {}) or {}
    spec = PackSpec(meta={"name": cfg.get("name"), "_format": f"mechvibes-v{version}-{kind}"})

    if kind == "single":
        sprite = _resolve(folder, cfg["sound"])
        for k, v in defines.items():
            if not v:
                continue
            up = k.endswith("-up")
            code = int(k[:-3] if up else k)
            start, dur = float(v[0]), float(v[1])
            spec.add("up" if up else "down", pool_for(iohook_class(code)), Source(sprite, start, start + dur))
        return spec

    if kind != "multi":
        raise ValueError(f"unknown key_define_type {kind!r}")

    # multi: one file per key; v2 adds '<code>-up' keys, a 'sound' fallback
    # pattern and a 'soundup' fallback pattern, both with optional {a-b} ranges.
    for k, v in defines.items():
        if not v:
            continue
        up = k.endswith("-up")
        code = int(k[:-3] if up else k)
        for name in _expand_range(v):
            spec.add("up" if up else "down", pool_for(iohook_class(code)), Source(_resolve(folder, name)))
    if version >= 2:
        for direction, fld in (("down", "sound"), ("up", "soundup")):
            pat = cfg.get(fld)
            if pat:
                for name in _expand_range(pat):
                    try:
                        spec.add(direction, "generic", Source(_resolve(folder, name)))
                    except FileNotFoundError:
                        pass
    return spec


def read_mechvibes_dx(folder: Path, cfg: dict) -> PackSpec:
    """MechvibesDX config_version 2: W3C key codes, timing [[down],[up]] in ms."""
    defs = cfg.get("definitions") or cfg.get("defs") or {}
    if cfg.get("definition_method", "single") != "single" or "audio_file" not in cfg:
        raise ValueError("MechvibesDX pack is not definition_method 'single' with an audio_file; "
                         "open it once in MechvibesDX (which converts it) and import the result")
    sprite = _resolve(folder, cfg["audio_file"])
    spec = PackSpec(meta={"name": cfg.get("name"), "author": cfg.get("author"), "_format": "mechvibesdx-v2"})
    for code, d in defs.items():
        timing = d.get("timing", []) if isinstance(d, dict) else []
        pool = pool_for(w3c_class(code))
        if code.startswith(("Mouse", "Wheel", "Button")):
            continue
        if (len(timing) >= 2 and abs(float(timing[1][0]) - float(timing[0][1])) < 0.01
                and not cfg.get("_keep_split_halves")):
            # MechvibesDX's v1 -> v2 migration cuts each single-sprite press
            # region into two back-to-back halves and plays the second half on
            # key-up. That "key-up" is just the tail of the press, so rejoin the
            # halves into one keydown and import no key-up for this key.
            spec.add("down", pool, Source(sprite, float(timing[0][0]), float(timing[1][1])))
            continue
        if len(timing) >= 1:
            spec.add("down", pool, Source(sprite, float(timing[0][0]), float(timing[0][1])))
        if len(timing) >= 2:
            spec.add("up", pool, Source(sprite, float(timing[1][0]), float(timing[1][1])))
    return spec


THOCK_POOLS = {"default": "generic"}


def read_thock(folder: Path, cfg: dict) -> PackSpec:
    md = cfg.get("metadata", {})
    lic = cfg.get("license", {})
    spec = PackSpec(meta={"name": md.get("name"), "author": md.get("author"),
                          "license": lic.get("type"), "_format": "thock"})
    for cls, d in cfg.get("sounds", {}).items():
        pool = THOCK_POOLS.get(cls, cls)
        if pool not in POOLS:
            pool = "generic"
        for direction in ("down", "up"):
            for name in d.get(direction, []) or []:
                spec.add(direction, pool, Source(_resolve(folder, name)))
    return spec


KBSIM_NAMES = {"GENERIC": "generic", "SPACE": "space", "ENTER": "enter", "BACKSPACE": "backspace"}


def read_kbsim_dir(folder: Path) -> PackSpec:
    """press/ + release/ folders with GENERIC_R<n>, SPACE, ENTER, BACKSPACE files."""
    spec = PackSpec(meta={"_format": "kbsim"})
    for direction, sub in (("down", "press"), ("up", "release")):
        for f in sorted((folder / sub).iterdir()):
            stem = f.stem.upper()
            base = re.sub(r"_R\d+$", "", stem)
            if base in KBSIM_NAMES and f.suffix.lower() in (".mp3", ".wav", ".ogg", ".flac"):
                spec.add(direction, KBSIM_NAMES[base], Source(f))
    return spec


def read_any(folder: Path) -> PackSpec:
    folder = folder.resolve()
    cfg_path = folder / "config.json"
    if cfg_path.exists():
        cfg = json.loads(cfg_path.read_text(encoding="utf-8-sig"))
        if "sounds" in cfg and "metadata" in cfg:
            return read_thock(folder, cfg)
        if "definitions" in cfg or "defs" in cfg:
            return read_mechvibes_dx(folder, cfg)
        if "defines" in cfg:
            return read_mechvibes(folder, cfg)
        raise ValueError(f"unrecognised config.json in {folder}")
    if (folder / "press").is_dir():
        return read_kbsim_dir(folder)
    raise ValueError(f"{folder}: no config.json and no press/ folder; cannot tell the pack format")


def read_file_lists(folder: Path, files: dict) -> PackSpec:
    """Explicit {"down": {pool: [file, ...]}, "up": {...}} lists from a recipe."""
    spec = PackSpec(meta={"_format": "file-list"})
    for direction in ("down", "up"):
        for pool, names in files.get(direction, {}).items():
            if pool not in POOLS:
                raise ValueError(f"unknown pool {pool}")
            for name in names:
                spec.add(direction, pool, Source(_resolve(folder, name)))
    return spec


# --------------------------------------------------------------------------
# DSP

_KW1 = ([1.53512485958697, -2.69169618940638, 1.19839281085285], [1.0, -1.69065929318241, 0.73248077421585])
_KW2 = ([1.0, -2.0, 1.0], [1.0, -1.99004745483398, 0.99007225036621])
_HP = signal.butter(2, 20.0, "highpass", fs=SR, output="sos")
HOT_START_FADE_MS = 0.25  # fade-in applied to sources that begin mid-strike
_decode_cache: dict[str, tuple[np.ndarray, int]] = {}


def db(x):
    return 20.0 * np.log10(np.maximum(x, 1e-12))


def strike_lufs(x: np.ndarray, window_ms: float = 50.0) -> float:
    n = int(SR * window_ms / 1000)
    seg = np.zeros(n)
    seg[: min(n, len(x))] = x[:n]
    y = signal.lfilter(*_KW2, signal.lfilter(*_KW1, seg))
    return -0.691 + 10.0 * np.log10(max(np.mean(y * y), 1e-20))


def decode(path: Path) -> tuple[np.ndarray, int]:
    k = str(path)
    if k not in _decode_cache:
        try:
            x, sr = sf.read(k, always_2d=True, dtype="float64")
        except Exception:
            # Formats libsndfile cannot read (e.g. m4a): fall back to ffmpeg if present.
            if not shutil.which("ffmpeg"):
                raise
            raw = subprocess.run(["ffmpeg", "-v", "error", "-i", k, "-f", "f32le", "-ac", "1", "-ar", str(SR), "-"],
                                 check=True, capture_output=True).stdout
            x, sr = np.frombuffer(raw, dtype="<f4").astype(np.float64)[:, None], SR
        _decode_cache[k] = (x.mean(axis=1), sr)
    return _decode_cache[k]


def load_source(src: Source) -> np.ndarray:
    x, sr = decode(src.path)
    if src.start_ms is not None:
        a = int(round(src.start_ms * sr / 1000))
        b = int(round(src.end_ms * sr / 1000))
        x = x[max(a, 0): max(b, a + 1)]
    if sr != SR:
        g = np.gcd(SR, sr)
        x = signal.resample_poly(x, SR // g, sr // g)
    return np.asarray(x, dtype=np.float64)


def _env(x: np.ndarray, ms: float) -> np.ndarray:
    n = max(1, int(SR * ms / 1000))
    return np.sqrt(np.convolve(x * x, np.ones(n) / n, mode="same"))


def trim(x: np.ndarray, max_ms: float, o: dict) -> tuple[np.ndarray, dict]:
    """Cut leading silence and tail; return trimmed sample and diagnostics."""
    x = signal.sosfilt(_HP, x)
    if len(x) < 32 or np.max(np.abs(x)) < 1e-6:
        raise ValueError("silent or empty sample")
    env = _env(x, 0.25)
    pk = env.max()
    onset = int(np.argmax(env >= pk * 0.1))  # -20 dB re envelope peak
    pre = int(SR * o["preroll_ms"] / 1000)
    start = max(0, onset - pre)
    y = x[start:].copy()
    k = onset - start
    if k > 0:
        y[:k] *= np.sin(np.linspace(0, np.pi / 2, k, endpoint=False)) ** 2
    if k < pre:
        # The source was cut (upstream) right at or just before the strike, so
        # it starts "hot". Ease in its first samples to remove the step, then pad
        # with silence so the onset still lands at preroll_ms like every other
        # sample.
        nf = min(int(SR * HOT_START_FADE_MS / 1000), len(y))
        if k == 0 and nf > 0:
            y[:nf] *= np.sin(np.linspace(0, np.pi / 2, nf, endpoint=False)) ** 2
        y = np.concatenate([np.zeros(pre - k), y])
        onset, start = pre, 0

    # tail: last point where the 5 ms envelope is above max(peak-48 dB, floor+6 dB)
    e5 = _env(y, 5.0)
    floor = np.percentile(_env(x, 5.0), 5)
    thr = max(e5.max() * 10 ** (o["tail_floor_db"] / 20), floor * 10 ** (o["tail_noise_margin_db"] / 20))
    above = np.nonzero(e5 > thr)[0]
    end = int(above[-1]) + int(SR * 0.005) if len(above) else len(y)
    end = min(end, len(y), int(SR * max_ms / 1000))
    end = max(end, int(SR * 0.02))
    y = y[:end]
    nf = min(int(SR * o["fade_out_ms"] / 1000), len(y) // 3)
    if nf > 0:
        y[-nf:] *= np.cos(np.linspace(0, np.pi / 2, nf)) ** 2
    return y, {"onset_ms": (onset - start) / SR * 1000, "len_ms": len(y) / SR * 1000}


def to_pcm16(x: np.ndarray, seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    tpdf = (rng.random(len(x)) - rng.random(len(x)))  # +/- 1 LSB triangular
    q = np.round(x * 32767.0 + tpdf)
    return np.clip(q, -32768, 32767).astype("<i2")


# --------------------------------------------------------------------------
# pipeline


def _pick(lst: list, n: int) -> list:
    if len(lst) <= n:
        return lst
    idx = np.linspace(0, len(lst) - 1, n).round().astype(int)
    return [lst[i] for i in idx]


def build(spec: PackSpec, out_dir: Path, meta: dict, o: dict) -> dict:
    """Process every sample of `spec`, write WAVs + pack.json into out_dir."""
    # gather raw arrays
    raw: dict[str, dict[str, list[np.ndarray]]] = {"down": {}, "up": {}}
    for direction in ("down", "up"):
        for pool, srcs in spec.sounds[direction].items():
            cap = o["max_generic"] if pool == "generic" else o["max_special"]
            for s in _pick(srcs, cap):
                raw[direction].setdefault(pool, []).append(load_source(s))
        if spec.synth:
            for pool, arrs in spec.synth.get(direction, {}).items():
                raw[direction].setdefault(pool, []).extend(arrs)
    if not raw["down"].get("generic"):
        # every pack needs a generic keydown pool: borrow the most populated one
        pools = sorted(raw["down"].items(), key=lambda kv: -len(kv[1]))
        if not pools:
            raise ValueError("pack has no keydown sounds")
        raw["down"]["generic"] = list(pools[0][1])
    if raw["up"] and not raw["up"].get("generic"):
        pools = sorted(raw["up"].items(), key=lambda kv: -len(kv[1]))
        raw["up"]["generic"] = list(pools[0][1])

    # trim, then level within each class
    proc: dict[str, dict[str, list[np.ndarray]]] = {"down": {}, "up": {}}
    diag = []
    for direction in ("down", "up"):
        max_ms = o["max_down_ms"] if direction == "down" else o["max_up_ms"]
        for pool, arrs in raw[direction].items():
            ys = []
            for a in arrs:
                try:
                    y, d = trim(a, max_ms, o)
                except ValueError:
                    continue
                ys.append(y)
            if not ys:
                continue
            L = np.array([strike_lufs(y) for y in ys])
            med = float(np.median(L))
            ys = [y * 10 ** ((np.clip(l, med - o["class_spread_db"], med + o["class_spread_db"]) - l) / 20)
                  for y, l in zip(ys, L)]
            proc[direction][pool] = ys

    ref = float(np.median([strike_lufs(y) for y in proc["down"]["generic"]]))
    # keep the special keys and the key-ups from towering over normal typing
    for direction in ("down", "up"):
        cap = o["up_max_db"] if direction == "up" else o["special_max_db"]
        for pool, ys in proc[direction].items():
            if direction == "down" and pool == "generic":
                continue
            med = float(np.median([strike_lufs(y) for y in ys]))
            if med > ref + cap:
                k = 10 ** ((ref + cap - med) / 20)
                proc[direction][pool] = [y * k for y in ys]
    gain_db = o["target_lufs"] - ref
    g = 10 ** (gain_db / 20)
    ceiling = 10 ** (o["peak_ceiling_db"] / 20)

    if out_dir.exists():
        for sub in ("down", "up"):
            shutil.rmtree(out_dir / sub, ignore_errors=True)
    out_dir.mkdir(parents=True, exist_ok=True)

    sounds_json: dict[str, dict[str, list[str]]] = {"down": {}, "up": {}}
    limited = []
    total_bytes = 0
    for direction in ("down", "up"):
        for pool in POOLS:
            ys = proc[direction].get(pool)
            if not ys:
                continue
            (out_dir / direction).mkdir(exist_ok=True)
            names = []
            for i, y in enumerate(ys, 1):
                y = y * g
                pk = np.max(np.abs(y))
                if pk > ceiling:
                    limited.append(f"{direction}/{pool}_{i}: -{db(pk / ceiling):.1f} dB")
                    y = y * (ceiling / pk)
                rel = f"{direction}/{pool}_{i:02d}.wav"
                seed = int(hashlib.sha1(f"{meta['id']}/{rel}".encode()).hexdigest()[:8], 16)
                sf.write(out_dir / rel, to_pcm16(y, seed), SR, subtype="PCM_16", format="WAV")
                total_bytes += (out_dir / rel).stat().st_size
                names.append(rel)
                diag.append({"file": rel, "peak_dbfs": round(float(db(np.max(np.abs(y)))), 2),
                             "strike_lufs": round(strike_lufs(y), 2), "len_ms": round(len(y) / SR * 1000, 1)})
            sounds_json[direction][pool] = names
    if not sounds_json["up"]:
        del sounds_json["up"]

    pack = {
        "format": FORMAT_ID,
        "format_version": FORMAT_VERSION,
        "id": meta["id"],
        "name": meta.get("name") or meta["id"],
        "description": meta.get("description", ""),
        "author": meta.get("author", "unknown"),
        "license": meta.get("license", "NOASSERTION"),
        "license_file": "LICENSE" if (out_dir / "LICENSE").exists() or meta.get("_license_text") else None,
        "attribution": meta.get("attribution", ""),
        "source": meta.get("source", {}),
        "switch_type": meta.get("switch_type", "unknown"),
        "tags": meta.get("tags", []),
        "audio": {"sample_rate": SR, "channels": 1, "encoding": "pcm_s16le", "container": "wav"},
        "loudness": {"reference": "median keydown generic strike loudness (K-weighted, 50 ms window)",
                     "target_lufs": o["target_lufs"], "gain_applied_db": round(gain_db, 2),
                     "peak_ceiling_dbfs": o["peak_ceiling_db"]},
        "playback": meta.get("playback", {"pitch_jitter_cents": 0, "gain_jitter_db": 1.0}),
        "sounds": sounds_json,
    }
    if pack["license_file"] is None:
        del pack["license_file"]
    if meta.get("_license_text"):
        (out_dir / "LICENSE").write_text(meta["_license_text"], encoding="utf-8")
    (out_dir / "pack.json").write_text(json.dumps(pack, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return {"id": meta["id"], "bytes": total_bytes, "gain_db": gain_db, "limited": limited, "samples": diag,
            "format": spec.meta.get("_format")}


# --------------------------------------------------------------------------
# CLI


def slugify(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-") or "pack"


def cmd_import(a) -> None:
    o = dict(DEFAULTS)
    for k in DEFAULTS:
        v = getattr(a, k, None)
        if v is not None:
            o[k] = v
    spec = read_any(Path(a.pack))
    name = a.name or spec.meta.get("name") or Path(a.pack).name
    meta = {
        # pack.json "id" must equal the pack's folder name (FORMAT.md)
        "id": a.id or slugify(Path(a.out).name),
        "name": name,
        "author": a.author or spec.meta.get("author") or "unknown",
        "license": a.license or spec.meta.get("license") or "NOASSERTION",
        "attribution": a.attribution or "",
        "switch_type": a.switch_type or "unknown",
        "source": {"url": a.source_url} if a.source_url else {"imported_from": spec.meta.get("_format")},
    }
    if a.license_file:
        meta["_license_text"] = Path(a.license_file).read_text(encoding="utf-8")
    out = Path(a.out)
    if out.name != meta["id"]:
        out = out / meta["id"]
    r = build(spec, out, meta, o)
    report([r])


def ensure_repo(sources: Path, url: str, commit: str) -> Path:
    name = url.rstrip("/").split("/")[-1]
    d = sources / name
    if not d.exists():
        sources.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "clone", "-q", "--depth", "1", url, str(d)], check=True)
    head = subprocess.run(["git", "-C", str(d), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    if head != commit:
        subprocess.run(["git", "-C", str(d), "fetch", "-q", "--depth", "1", "origin", commit], check=True)
        subprocess.run(["git", "-C", str(d), "checkout", "-q", commit], check=True)
    return d


def cmd_defaults(a) -> None:
    recipes = json.loads(Path(a.recipes).read_text())
    out_root = Path(a.out)
    results = []
    only = set(a.only.split(",")) if a.only else None
    for r in recipes["packs"]:
        if only and r["id"] not in only:
            continue
        o = dict(DEFAULTS)
        o.update(r.get("options", {}))
        meta = {k: v for k, v in r.items() if k not in ("files", "repo", "path", "options", "generator", "license_text_file")}
        if "generator" in r:
            sys.path.insert(0, str(HERE))
            import synth_pop  # noqa: E402  (local module, scripts/sounds/synth_pop.py)
            spec = PackSpec(meta={"_format": "synth"}, synth=synth_pop.generate(SR))
            meta["source"] = {"generator": "scripts/sounds/synth_pop.py"}
        else:
            repo = ensure_repo(Path(a.sources), r["repo"]["url"], r["repo"]["commit"])
            folder = repo / r["path"]
            spec = read_file_lists(folder, r["files"]) if "files" in r else read_any(folder)
            meta["source"] = {"url": r["repo"]["url"], "commit": r["repo"]["commit"], "path": r["path"]}
            lt = r.get("license_text_file")
            if lt:
                header = (f"{r['name']} sound pack for typebud.\n\n{r.get('attribution', '')}\n\n"
                          f"Source: {r['repo']['url']} (commit {r['repo']['commit']}, path {r['path']}).\n"
                          f"The upstream license ({r['license']}) is reproduced below and applies to the\n"
                          f"audio files in this folder.\n\n" + "-" * 72 + "\n\n")
                meta["_license_text"] = header + (repo / lt).read_text(encoding="utf-8", errors="replace")
        if "license_text" in r:
            meta["_license_text"] = r["license_text"]
            meta.pop("license_text", None)
        results.append(build(spec, out_root / r["id"], meta, o))
    manifest = {"format": "typebud.soundpack-index", "format_version": 1,
                "packs": [{"id": r["id"], "bundle": r.get("bundle", "default")} for r in recipes["packs"]]}
    (out_root / "index.json").write_text(json.dumps(manifest, indent=2) + "\n")
    report(results)


def report(results: list[dict]) -> None:
    tot = 0
    for r in results:
        tot += r["bytes"]
        on = [s for s in r["samples"]]
        pk = max(s["peak_dbfs"] for s in on)
        n_down = sum(1 for s in on if s["file"].startswith("down/"))
        n_up = len(on) - n_down
        print(f"{r['id']:24s} {r['format'] or '':22s} down={n_down:3d} up={n_up:3d} size={r['bytes'] / 1024:7.1f} KiB "
              f"gain={r['gain_db']:+6.1f} dB maxpeak={pk:6.1f} dBFS" + (f" limited={len(r['limited'])}" if r["limited"] else ""))
    print(f"{'total':24s} {tot / 1024:.1f} KiB")


def main(argv=None) -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = p.add_subparsers(dest="cmd", required=True)
    pi = sp.add_parser("import", help="import one pack folder (Mechvibes v1/v2, MechvibesDX, Thock, kbsim layout)")
    pi.add_argument("pack")
    pi.add_argument("out")
    for f in ("id", "name", "author", "license", "license_file", "attribution", "switch_type", "source_url"):
        pi.add_argument("--" + f.replace("_", "-"), dest=f)
    for k, v in DEFAULTS.items():
        pi.add_argument("--" + k.replace("_", "-"), dest=k, type=type(v), default=None)
    pi.set_defaults(func=cmd_import)
    pd = sp.add_parser("defaults", help="rebuild the bundled packs from scripts/sounds/default_packs.json")
    pd.add_argument("--recipes", default=str(HERE / "default_packs.json"))
    pd.add_argument("--sources", required=True, help="directory holding (or receiving) shallow clones of upstream repos")
    pd.add_argument("--out", default=str(REPO / "sounds" / "packs"))
    pd.add_argument("--only", help="comma-separated pack ids")
    pd.set_defaults(func=cmd_defaults)
    a = p.parse_args(argv)
    a.func(a)


if __name__ == "__main__":
    main()
