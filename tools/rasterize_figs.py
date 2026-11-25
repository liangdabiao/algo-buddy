#!/usr/bin/env python3
"""Rasterize the hello-algo SVG figures referenced by data/content.json into
quantized PNGs for the Godot app, via the resvg binary.

- Regular figures and step figures: 1280 px wide (2x of the 640 px screen).
- figure_steps blocks additionally get a 480 px wide thumb of their first step.
- Chapter covers (JPG) are downscaled to 256 px wide.
- Incremental: a PNG newer than its SVG source is kept as-is.

Usage:
  python tools/rasterize_figs.py                # all figures
  python tools/rasterize_figs.py --force        # ignore timestamps
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
WORKSPACE = ROOT.parent
REPO = WORKSPACE / ".build" / "hello-algo-src" / "repo"
RESVG = WORKSPACE / ".build" / "resvg" / "resvg.exe"
CONTENT = ROOT / "data" / "content.json"
OUT_DIR = ROOT / "assets" / "figures"
COVER_DIR = ROOT / "assets" / "covers"

FIG_WIDTH = 1280
THUMB_WIDTH = 480
COVER_WIDTH = 256


def run_resvg(src: Path, dst: Path, width: int) -> bool:
    cmd = [str(RESVG), "--width", str(width), str(src), str(dst)]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        print(f"  TIMEOUT {src.name}", file=sys.stderr)
        return False
    if r.returncode != 0:
        print(f"  FAIL {src.name}: {r.stderr.strip()[:120]}", file=sys.stderr)
        return False
    return dst.exists()


def quantize(dst: Path) -> None:
    img = Image.open(dst)
    if img.mode != "P":
        img = img.convert("RGB").quantize(colors=256, method=Image.MEDIANCUT, dither=Image.NONE)
        img.save(dst, optimize=True)


def shrink(dst: Path, width: int, out: Path) -> None:
    img = Image.open(dst)
    ratio = width / img.width
    if ratio >= 1.0:
        img.save(out, optimize=True)
        return
    small = img.resize((width, max(1, round(img.height * ratio))), Image.LANCZOS)
    small.convert("RGB").quantize(colors=256, method=Image.MEDIANCUT, dither=Image.NONE).save(
        out, optimize=True)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()

    content = json.loads(CONTENT.read_text(encoding="utf-8"))
    images: dict[str, str] = content.get("images", {})
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    COVER_DIR.mkdir(parents=True, exist_ok=True)

    # Steps thumbs (first step of each figure_steps block).
    thumbs: set[str] = set()
    for sec in content["sections"]:
        for b in sec["blocks"]:
            if b.get("type") == "figure_steps" and b.get("steps"):
                thumbs.add(b["steps"][0]["img"])

    ok = fail = skipped = 0
    total_bytes = 0
    for rel, name in sorted(images.items()):
        src = REPO / rel
        dst = OUT_DIR / f"{name}.png"
        if not src.exists():
            print(f"MISSING SRC {rel}", file=sys.stderr)
            fail += 1
            continue
        if dst.exists() and dst.stat().st_mtime > src.stat().st_mtime and not args.force:
            skipped += 1
        elif src.suffix.lower() == ".svg":
            if run_resvg(src, dst, FIG_WIDTH):
                quantize(dst)
                ok += 1
            else:
                fail += 1
                continue
        else:
            # bitmap source (jpg/gif/png): convert directly with PIL
            try:
                img = Image.open(src)
                img.seek(0)                                   # first gif frame
                img = img.convert("RGB")
                w, h = img.size
                ratio = min(1.0, FIG_WIDTH / w)
                if ratio < 1.0:
                    img = img.resize((FIG_WIDTH, max(1, round(h * ratio))), Image.LANCZOS)
                q = img.quantize(colors=256, method=Image.MEDIANCUT, dither=Image.NONE)
                q.info.pop("transparency", None)              # gif palette tuples break png save
                q.save(dst, optimize=True)
                ok += 1
            except Exception as e:
                print(f"  FAIL {src.name}: {e}", file=sys.stderr)
                fail += 1
                continue
        if name in thumbs:
            thumb = OUT_DIR / f"{name}_thumb.png"
            if args.force or not thumb.exists() or thumb.stat().st_mtime < src.stat().st_mtime:
                shrink(dst, THUMB_WIDTH, thumb)

    # Chapter covers.
    for ch in content["chapters"]:
        stem = ch.get("cover", "").replace("cover_", "")
        src = REPO / "docs" / "assets" / "covers" / f"{stem}.jpg"
        dst = COVER_DIR / f"{ch['cover']}.png"
        if not ch.get("cover") or not src.exists():
            continue
        if dst.exists() and dst.stat().st_mtime > src.stat().st_mtime and not args.force:
            skipped += 1
            continue
        img = Image.open(src).convert("RGB")
        ratio = COVER_WIDTH / img.width
        small = img.resize((COVER_WIDTH, max(1, round(img.height * ratio))), Image.LANCZOS)
        small.quantize(colors=256, method=Image.MEDIANCUT, dither=Image.NONE).save(
            dst, optimize=True)
        ok += 1

    for p in list(OUT_DIR.glob("*.png")):
        total_bytes += p.stat().st_size
    for p in list(COVER_DIR.glob("*.png")):
        total_bytes += p.stat().st_size
    print(f"rendered={ok} skipped={skipped} failed={fail} "
          f"total={total_bytes / 1024 / 1024:.1f} MiB")
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
