"""Shared ffmpeg/ffprobe helpers used by clip_app.py and batch.py."""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

NO_WINDOW = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0


def find_binary(name: str) -> str:
    exe = name + (".exe" if os.name == "nt" else "")
    found = shutil.which(name)
    if found:
        return found
    for base in (Path.home() / "AppData/Local/Microsoft/WinGet/Packages",
                 Path("C:/Program Files")):
        if base.exists():
            hits = list(base.rglob(exe))[:1]
            if hits:
                return str(hits[0])
    return name


FFMPEG = find_binary("ffmpeg")
FFPROBE = find_binary("ffprobe")


def probe_duration(path: str) -> float:
    try:
        out = subprocess.run(
            [FFPROBE, "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", path],
            capture_output=True, text=True, timeout=20, creationflags=NO_WINDOW,
        ).stdout.strip()
        return float(out)
    except Exception:
        return 0.0


def run_ffmpeg(args: list[str], timeout: int = 3600) -> None:
    p = subprocess.run([FFMPEG, "-y", "-hide_banner", "-loglevel", "error", *args],
                       capture_output=True, text=True, timeout=timeout, creationflags=NO_WINDOW)
    if p.returncode != 0:
        raise RuntimeError("ffmpeg: " + (p.stderr or "")[-400:])
