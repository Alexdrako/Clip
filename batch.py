"""Batch video processor: apply a preset (and optional watermark removal)
to every video in a folder using ffmpeg.

Usage:
  python batch.py IN_DIR OUT_DIR --preset vertical
  python batch.py IN_DIR OUT_DIR --preset horizontal --watermark 20,20,200,80
  python batch.py IN_DIR OUT_DIR --preset audio
  python batch.py IN_DIR OUT_DIR --preset copy --size-mb 50
"""
from __future__ import annotations

import argparse
from pathlib import Path

from ffmpeg_core import run_ffmpeg, probe_duration

VIDEO_EXT = {".mp4", ".mov", ".mkv", ".webm", ".avi", ".m4v"}

PRESETS = {
    "vertical": {"w": 1080, "h": 1920, "ext": "mp4"},    # TikTok/Reels/Shorts 9:16
    "horizontal": {"w": 1920, "h": 1080, "ext": "mp4"},  # 16:9
    "audio": {"ext": "mp3"},                              # extract audio only
    "copy": {"ext": None},                                # keep dims, just re-encode/resize by size
}


def build_filters(preset: dict, watermark: tuple[int, int, int, int] | None) -> str | None:
    parts = []
    if watermark:
        x, y, w, h = watermark
        parts.append(f"delogo=x={x}:y={y}:w={w}:h={h}")
    if "w" in preset and "h" in preset:
        w, h = preset["w"], preset["h"]
        parts.append(f"scale={w}:{h}:force_original_aspect_ratio=increase,crop={w}:{h}")
    return ",".join(parts) if parts else None


def process_one(src: Path, out_dir: Path, preset_name: str, watermark, size_mb: int) -> Path:
    preset = PRESETS[preset_name]
    ext = preset["ext"] or src.suffix.lstrip(".")
    dest = out_dir / f"{src.stem}.{ext}"

    args = ["-i", str(src)]

    if preset_name == "audio":
        args += ["-vn", "-c:a", "libmp3lame", "-q:a", "0"]
    else:
        vf = build_filters(preset, watermark)
        if vf:
            args += ["-vf", vf]
        args += ["-c:v", "libx264", "-preset", "fast", "-pix_fmt", "yuv420p", "-c:a", "aac"]
        if size_mb > 0:
            duration = max(probe_duration(str(src)), 5)
            total_kbits = size_mb * 8192 * 0.95
            vkbps = max(100, int(total_kbits / duration) - 128)
            args += ["-b:v", f"{vkbps}k"]

    args.append(str(dest))
    run_ffmpeg(args)
    return dest


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input_dir", type=Path)
    ap.add_argument("output_dir", type=Path)
    ap.add_argument("--preset", choices=PRESETS.keys(), default="copy")
    ap.add_argument("--watermark", metavar="X,Y,W,H",
                     help="delogo box (top-left corner + size) to remove a fixed-position watermark")
    ap.add_argument("--size-mb", type=int, default=0, help="target output size in MB (0 = no limit)")
    args = ap.parse_args()

    watermark = None
    if args.watermark:
        watermark = tuple(int(v) for v in args.watermark.split(","))
        if len(watermark) != 4:
            ap.error("--watermark must be X,Y,W,H")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    files = sorted(p for p in args.input_dir.iterdir() if p.suffix.lower() in VIDEO_EXT)
    if not files:
        print(f"Немає відео у {args.input_dir}")
        return

    for i, src in enumerate(files, 1):
        print(f"[{i}/{len(files)}] {src.name} …", end=" ", flush=True)
        try:
            dest = process_one(src, args.output_dir, args.preset, watermark, args.size_mb)
            print(f"-> {dest.name}")
        except Exception as e:
            print(f"ПОМИЛКА: {e}")


if __name__ == "__main__":
    main()
