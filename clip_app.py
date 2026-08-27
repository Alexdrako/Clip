"""
Clip for Windows — video downloader GUI wrapping yt-dlp + ffmpeg.
PySide6, dark glass styling, queue with max 3 concurrent downloads,
format/resolution/target-size/clip-range options, history persisted to JSON.

Run:  python clip_app.py
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from PySide6.QtCore import Qt, QThread, Signal, QUrl
from PySide6.QtGui import QPixmap, QDesktopServices
from PySide6.QtWidgets import (
    QApplication, QMainWindow, QWidget, QLabel, QLineEdit, QPushButton,
    QVBoxLayout, QHBoxLayout, QComboBox, QCheckBox, QSlider, QListWidget,
    QListWidgetItem, QFileDialog, QMessageBox, QFrame,
    QGraphicsDropShadowEffect, QStackedWidget,
)
from PySide6.QtNetwork import QNetworkAccessManager, QNetworkRequest, QNetworkReply

# ---------------------------------------------------------------- constants

APP_DIR = Path(__file__).resolve().parent
HISTORY_FILE = APP_DIR / "clip_history.json"
SETTINGS_FILE = APP_DIR / "clip_settings.json"
DOWNLOADS = Path.home() / "Downloads"

MAX_CONCURRENT = 3
HISTORY_LIMIT = 200
NO_WINDOW = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0


# ---------------------------------------------------------------- binaries

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


YTDLP = find_binary("yt-dlp")
FFMPEG = find_binary("ffmpeg")
FFPROBE = find_binary("ffprobe")

# ---------------------------------------------------------------- utils

PLATFORMS = {
    "youtube.com": ("YouTube", "#ff4e45"),
    "youtu.be": ("YouTube", "#ff4e45"),
    "x.com": ("X / Twitter", "#1d9bf0"),
    "twitter.com": ("X / Twitter", "#1d9bf0"),
    "instagram.com": ("Instagram", "#d6249f"),
    "tiktok.com": ("TikTok", "#25f4ee"),
    "reddit.com": ("Reddit", "#ff4500"),
    "redd.it": ("Reddit", "#ff4500"),
}
URL_RE = re.compile(r"https?://[^\s\"'<>]+", re.I)


def detect_platform(url: str) -> tuple[str, str]:
    low = url.lower()
    for host, (name, color) in PLATFORMS.items():
        if host in low:
            return name, color
    return "Video", "#8e8e93"


def first_url(text: str) -> str | None:
    m = URL_RE.search(text or "")
    return m.group(0).rstrip(".,;)") if m else None


def fmt_duration(sec: float | None) -> str:
    if not sec or sec <= 0:
        return ""
    sec = int(round(sec))
    h, rem = divmod(sec, 3600)
    return f"{h}:{rem // 60:02d}:{rem % 60:02d}" if h else f"{sec // 60}:{sec % 60:02d}"


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


def reddit_direct_media(url: str) -> str | None:
    """yt-dlp's Reddit extractor is broken; resolve direct video via api.reddit.com."""
    try:
        import urllib.request
        api = re.sub(r"(?:www\.|old\.|new\.|new\.)?(reddit\.com|redd\.it)",
                     "api.reddit.com", url.split("?")[0], count=1)
        api = api.rstrip("/") + ".json"
        req = urllib.request.Request(api, headers={
            "User-Agent": "windows:Clip:1.0 (by /u/Alexdrako)"})
        with urllib.request.urlopen(req, timeout=10) as r:
            data = json.load(r)
        post = data[0]["data"]["children"][0]["data"]
        for node in [post] + post.get("crosspost_parent_list", []):
            rv = ((node.get("media") or {}).get("reddit_video")
                  or (node.get("secure_media") or {}).get("reddit_video"))
            if rv and rv.get("fallback_url"):
                return rv["fallback_url"]
    except Exception:
        return None
    return None


# ---------------------------------------------------------------- video tools

def _run_ffmpeg(args: list[str], timeout: int = 3600):
    p = subprocess.run(args, capture_output=True, text=True, timeout=timeout,
                       creationflags=NO_WINDOW)
    if p.returncode != 0:
        raise RuntimeError("ffmpeg: " + (p.stderr or "")[-300:])


def probe_video_info(path: str) -> dict:
    """duration/fps/width/height/has_audio via one ffprobe call."""
    try:
        out = subprocess.run(
            [FFPROBE, "-v", "error", "-show_entries",
             "format=duration:stream=width,height,r_frame_rate,codec_type",
             "-of", "json", path],
            capture_output=True, text=True, timeout=20, creationflags=NO_WINDOW,
        ).stdout
        data = json.loads(out)
    except Exception:
        return {}
    info = {"duration": float((data.get("format") or {}).get("duration", 0) or 0),
            "has_audio": False, "width": 0, "height": 0, "fps": 24.0}
    for s in data.get("streams", []):
        if s.get("codec_type") == "video" and not info["width"]:
            info["width"] = s.get("width", 0)
            info["height"] = s.get("height", 0)
            num, _, den = (s.get("r_frame_rate") or "24/1").partition("/")
            try:
                info["fps"] = float(num) / float(den or 1)
            except Exception:
                info["fps"] = 24.0
        elif s.get("codec_type") == "audio":
            info["has_audio"] = True
    return info


def detect_crop_box(path: str, info: dict) -> tuple[int, int, int, int] | None:
    """Auto-detect black bars via ffmpeg's cropdetect. None if nothing to crop."""
    fps = info.get("fps") or 24.0
    duration = info.get("duration") or 5
    sample_frames = min(90, max(10, int(duration * fps)))
    p = subprocess.run(
        [FFMPEG, "-i", path, "-vf", "cropdetect=24:16:0", "-an",
         "-frames:v", str(sample_frames), "-f", "null", "-"],
        capture_output=True, text=True, timeout=60, creationflags=NO_WINDOW,
    )
    matches = re.findall(r"crop=(\d+):(\d+):(\d+):(\d+)", p.stderr)
    if not matches:
        return None
    w, h, x, y = (int(v) for v in matches[-1])
    if w >= info.get("width", w) and h >= info.get("height", h):
        return None
    return w, h, x, y


def find_loop_seam(path: str, info: dict, min_loop_s: float = 3.0):
    """Sample small grayscale frames and find the best-matching early/late
    frame pair for a natural loop cut. Pure stdlib (no numpy). Returns
    (start_frame, end_frame, fps) or None if no good pair / clip too short."""
    fps = info.get("fps") or 24.0
    duration = info.get("duration") or 0
    if duration < min_loop_s + 1:
        return None
    sw, sh = 40, 22
    proc = subprocess.run(
        [FFMPEG, "-i", path, "-vf", f"fps={fps},scale={sw}:{sh},format=gray",
         "-f", "rawvideo", "-"],
        capture_output=True, timeout=60, creationflags=NO_WINDOW,
    )
    raw = proc.stdout
    frame_size = sw * sh
    n = len(raw) // frame_size
    if n < 10:
        return None
    frames = [raw[i * frame_size:(i + 1) * frame_size] for i in range(n)]
    min_gap = max(1, int(min_loop_s * fps))
    third = max(1, n // 3)
    late_start = max(third, n - third)
    best = None
    for i in range(0, third):
        fi = frames[i]
        for j in range(late_start, n):
            if j - i < min_gap:
                continue
            diff = sum(a - b if a > b else b - a for a, b in zip(fi, frames[j]))
            if best is None or diff < best[0]:
                best = (diff, i, j)
    if not best:
        return None
    _, i, j = best
    return i, j, fps


def render_loop(path: str, out_path: str, info: dict, mode: str):
    fps = info.get("fps") or 24.0
    has_audio = info.get("has_audio", False)
    duration = info.get("duration") or 0

    if mode == "boomerang":
        rev = out_path + ".rev.mp4"
        args_rev = [FFMPEG, "-y", "-hide_banner", "-loglevel", "error", "-i", path, "-vf", "reverse"]
        if has_audio:
            args_rev += ["-af", "areverse"]
        args_rev += ["-c:v", "libx264", "-preset", "fast", "-pix_fmt", "yuv420p"]
        if has_audio:
            args_rev += ["-c:a", "aac"]
        args_rev.append(rev)
        _run_ffmpeg(args_rev)
        if has_audio:
            maps = "[0:v][0:a][1:v][1:a]concat=n=2:v=1:a=1[v][a]"
        else:
            maps = "[0:v][1:v]concat=n=2:v=1[v]"
        args = [FFMPEG, "-y", "-hide_banner", "-loglevel", "error", "-i", path, "-i", rev,
                "-filter_complex", maps, "-map", "[v]"]
        if has_audio:
            args += ["-map", "[a]"]
        args += ["-c:v", "libx264", "-preset", "fast", "-pix_fmt", "yuv420p"]
        if has_audio:
            args += ["-c:a", "aac"]
        args.append(out_path)
        try:
            _run_ffmpeg(args)
        finally:
            Path(rev).unlink(missing_ok=True)
        return

    if mode == "smart":
        seam = find_loop_seam(path, info)
        if seam is None:
            mode = "crossfade"
        else:
            i, j, sfps = seam
            seg_start, seg_end = i / sfps, j / sfps
    if mode == "crossfade":
        seg_start, seg_end = 0.0, duration

    seg_len = seg_end - seg_start
    fade = min(1.0 if mode == "crossfade" else 0.2, max(0.05, seg_len * 0.15))
    offset = seg_len - fade

    filt = (
        f"[0:v]trim={seg_start:.6f}:{seg_end:.6f},setpts=PTS-STARTPTS[vseg];"
        f"[vseg]split[va][vb];"
        f"[va]trim=0:{fade:.6f},setpts=PTS-STARTPTS[vstart];"
        f"[vb]trim=0:{seg_len:.6f},setpts=PTS-STARTPTS[vfull];"
        f"[vfull][vstart]xfade=transition=fade:duration={fade:.6f}:offset={offset:.6f},format=yuv420p[vout]"
    )
    maps = ["-map", "[vout]"]
    if has_audio:
        delay_ms = int(offset * 1000)
        filt += (
            f";[0:a]atrim={seg_start:.6f}:{seg_end:.6f},asetpts=PTS-STARTPTS[aseg];"
            f"[aseg]asplit[aa][ab];"
            f"[aa]atrim=0:{fade:.6f},asetpts=PTS-STARTPTS,afade=t=in:st=0:d={fade:.6f},"
            f"adelay={delay_ms}|{delay_ms}[astart];"
            f"[ab]atrim=0:{seg_len:.6f},asetpts=PTS-STARTPTS,afade=t=out:st={offset:.6f}:d={fade:.6f}[afull];"
            f"[afull][astart]amix=inputs=2:duration=first:normalize=0[aout]"
        )
        maps += ["-map", "[aout]"]
    args = [FFMPEG, "-y", "-hide_banner", "-loglevel", "error", "-i", path,
            "-filter_complex", filt] + maps + ["-c:v", "libx264", "-preset", "fast", "-pix_fmt", "yuv420p"]
    if has_audio:
        args += ["-c:a", "aac"]
    args.append(out_path)
    _run_ffmpeg(args)


def render_crop(path: str, out_path: str, info: dict, box: tuple[int, int, int, int]):
    w, h, x, y = box
    has_audio = info.get("has_audio", False)
    args = [FFMPEG, "-y", "-hide_banner", "-loglevel", "error", "-i", path,
            "-vf", f"crop={w}:{h}:{x}:{y}",
            "-c:v", "libx264", "-preset", "fast", "-pix_fmt", "yuv420p"]
    args += ["-c:a", "copy"] if has_audio else ["-an"]
    args.append(out_path)
    _run_ffmpeg(args)


class VideoToolWorker(QThread):
    done_sig = Signal(str, object)   # output_path (or ""), error-or-None

    def __init__(self, src: str, save_dir: Path, op: str, loop_mode: str = "smart"):
        super().__init__()
        self.src = src
        self.save_dir = save_dir
        self.op = op            # "loop" | "crop"
        self.loop_mode = loop_mode

    def run(self):
        try:
            info = probe_video_info(self.src)
            if not info.get("width"):
                raise RuntimeError("не вдалося прочитати відео")
            stem = re.sub(r"[\\/:*?\"<>|]", " ", Path(self.src).stem).strip() or "video"
            if self.op == "crop":
                box = detect_crop_box(self.src, info)
                if not box:
                    raise RuntimeError("чорних смуг не знайдено")
                out = self._dest(f"{stem}_cropped.mp4")
                render_crop(self.src, str(out), info, box)
            else:
                out = self._dest(f"{stem}_loop.mp4")
                render_loop(self.src, str(out), info, self.loop_mode)
            self.done_sig.emit(str(out), None)
        except Exception as e:
            self.done_sig.emit("", str(e)[-300:])

    def _dest(self, name: str) -> Path:
        dest = self.save_dir / name
        i = 1
        while dest.exists():
            dest = self.save_dir / f"{dest.stem}-{i}{dest.suffix}"
            i += 1
        return dest


class Settings:
    def __init__(self):
        self.data = {"save_dir": str(DOWNLOADS)}
        if SETTINGS_FILE.exists():
            try:
                self.data.update(json.loads(SETTINGS_FILE.read_text("utf-8")))
            except Exception:
                pass
        Path(self.data["save_dir"]).mkdir(parents=True, exist_ok=True)

    @property
    def save_dir(self) -> Path:
        return Path(self.data["save_dir"])

    def save(self):
        SETTINGS_FILE.write_text(json.dumps(self.data, indent=2), "utf-8")


# ---------------------------------------------------------------- workers

@dataclass
class TaskSpec:
    url: str
    title: str = ""
    platform: str = ""
    color: str = ""
    fmt: str = "mp4"          # mp4 / mov / webm / mp3
    resolution: int = 1080
    size_mb: int = 0          # 0 = original
    clip_start: float = -1.0  # -1 = disabled
    clip_end: float = -1.0
    status: str = "queued"    # queued / running / done / failed
    progress: float = 0.0
    output_path: str = ""


class AnalyzeWorker(QThread):
    got_meta = Signal(dict)
    failed = Signal(str)

    def __init__(self, url: str):
        super().__init__()
        self.url = url

    def run(self):
        url = self.url
        name, color = detect_platform(url)
        if name == "Reddit":
            direct = reddit_direct_media(url)
            if direct:
                url = direct
                name, color = detect_platform(url)

        cmd = [YTDLP, "--dump-single-json", "--no-warnings", "--no-playlist", url]
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=45,
                                 encoding="utf-8", errors="replace", creationflags=NO_WINDOW)
            meta = json.loads(out.stdout)
            meta["_platform"] = name
            meta["_color"] = color
            meta["_effective_url"] = url
            self.got_meta.emit(meta)
        except Exception as e:
            err = ""
            if hasattr(e, "stderr") and e.stderr:
                err = e.stderr[-300:]
            elif isinstance(e, subprocess.TimeoutExpired):
                err = "timeout: сайт не відповів за 45 с"
            else:
                err = str(e)[-300:]
            self.failed.emit(err)


class DownloadWorker(QThread):
    changed = Signal(int, float, str)   # task_id, progress, status
    done_sig = Signal(int, object)      # task_id, error-or-None

    _procs: dict[int, subprocess.Popen] = {}
    _lock = threading.Lock()

    def __init__(self, task_id: int, spec: TaskSpec, save_dir: Path):
        super().__init__()
        self.task_id = task_id
        self.spec = spec
        self.save_dir = save_dir

    @classmethod
    def cancel(cls, task_id: int):
        with cls._lock:
            proc = cls._procs.get(task_id)
        if proc:
            try:
                proc.terminate()
            except Exception:
                pass

    # ------------------------------------------------------------------
    def run(self):
        spec = self.spec
        tmpdir = Path(tempfile.mkdtemp(prefix="Clip-"))
        err = None
        try:
            self.changed.emit(self.task_id, 0.0, "старт…")
            url = spec.url

            outtmpl = str(tmpdir / "%(title).80s.%(ext)s")
            args = [YTDLP, "--newline", "--no-playlist", "--no-warnings",
                    "-o", outtmpl]
            clip_active = spec.clip_start >= 0 or spec.clip_end >= 0

            if spec.fmt == "mp3":
                args += ["-x", "--audio-format", "mp3", "--audio-quality", "0"]
            else:
                args += ["-f", f"bv*[height<={spec.resolution}]+ba/b[height<={spec.resolution}]/b",
                         "--merge-output-format", "mp4"]

            if "instagram.com" in url.lower():
                args += ["--cookies-from-browser", "chrome"]

            args.append(url)
            proc = subprocess.Popen(
                args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                text=True, encoding="utf-8", errors="replace", creationflags=NO_WINDOW)
            with self._lock:
                self._procs[self.task_id] = proc

            last_pct = -1.0
            for line in proc.stdout:
                m = re.search(r"\[download\]\s+([\d.]+)%", line)
                if m:
                    pct = float(m.group(1)) / 100 * 0.9
                    if pct - last_pct > 0.005:
                        last_pct = pct
                        sp = re.search(r"at\s+([\d.,]+\w+/s)", line)
                        self.changed.emit(self.task_id, pct,
                                          f"завантаження {sp.group(1)}" if sp else "завантаження…")
            rc = proc.wait()
            if rc != 0:
                raise RuntimeError(f"yt-dlp завершився з кодом {rc}")

            files = [p for p in tmpdir.glob("*") if p.is_file()]
            src = max(files, key=lambda p: p.stat().st_mtime, default=None)
            if not src:
                raise RuntimeError("файл не створено")

            needs_ffmpeg = clip_active or spec.size_mb > 0 or spec.fmt in ("mov", "webm")
            if needs_ffmpeg:
                self.changed.emit(self.task_id, 0.92, "обробка ffmpeg…")
                src = self._ffmpeg_pass(src)

            stem = re.sub(r"[\\/:*?\"<>|]", " ", src.stem).strip() or "video"
            dest = self.save_dir / f"{stem}{src.suffix}"
            i = 1
            while dest.exists():
                dest = self.save_dir / f"{stem}-{i}{src.suffix}"
                i += 1
            shutil.move(str(src), str(dest))
            spec.output_path = str(dest)
            self.changed.emit(self.task_id, 1.0, "готово ✓")
        except Exception as e:
            err = str(e)[-300:]
        finally:
            with self._lock:
                self._procs.pop(self.task_id, None)
            shutil.rmtree(tmpdir, ignore_errors=True)
            self.done_sig.emit(self.task_id, err)

    # ------------------------------------------------------------------
    def _ffmpeg_pass(self, src: Path) -> Path:
        spec = self.spec
        tmpdir = src.parent
        duration = probe_duration(str(src))
        ext = {"mp4": "mp4", "mov": "mov", "webm": "webm", "mp3": "mp3"}[spec.fmt]
        out = tmpdir / f"{src.stem}_out.{ext}"
        clip_active = spec.clip_start >= 0 or spec.clip_end >= 0

        args = [FFMPEG, "-y", "-hide_banner", "-loglevel", "error"]
        if clip_active:
            start = max(spec.clip_start, 0)
            end = spec.clip_end if spec.clip_end > start else duration or 3600
            args += ["-ss", f"{start:.2f}", "-t", f"{max(0.5, end - start):.2f}"]
        args += ["-i", str(src)]

        if spec.fmt == "webm":
            args += ["-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "34",
                     "-c:a", "libopus", "-row-mt", "1"]
        elif spec.fmt == "mp3":
            args += ["-c:a", "libmp3lame", "-q:a", "0"]
        elif clip_active or spec.size_mb > 0:
            args += ["-c:v", "libx264", "-preset", "fast", "-pix_fmt", "yuv420p",
                     "-c:a", "aac"]
        else:  # container change only
            args += ["-c:v", "copy", "-c:a", "copy"]

        if spec.size_mb > 0 and spec.fmt != "mp3":
            total_kbits = spec.size_mb * 8192 * 0.95
            secs = max((spec.clip_end - spec.clip_start) if clip_active else duration, 5)
            vkbps = max(100, int(total_kbits / secs) - 128)
            args += ["-b:v", f"{vkbps}k"]

        args.append(str(out))
        p = subprocess.run(args, capture_output=True, text=True, timeout=3600,
                           creationflags=NO_WINDOW)
        if p.returncode != 0 or not out.exists():
            raise RuntimeError("ffmpeg: " + (p.stderr or "")[-200:])
        src.unlink(missing_ok=True)
        return out


# ---------------------------------------------------------------- history

class History:
    def __init__(self):
        self.entries: list[dict] = []
        if HISTORY_FILE.exists():
            try:
                self.entries = json.loads(HISTORY_FILE.read_text("utf-8"))
            except Exception:
                self.entries = []

    def add(self, spec: TaskSpec):
        self.entries.insert(0, {
            "date": datetime.now().isoformat(timespec="seconds"),
            "title": spec.title or spec.url,
            "url": spec.url,
            "platform": spec.platform,
            "fmt": spec.fmt,
            "path": spec.output_path,
        })
        del self.entries[HISTORY_LIMIT:]
        HISTORY_FILE.write_text(json.dumps(self.entries, ensure_ascii=False, indent=2), "utf-8")


# ---------------------------------------------------------------- theme

DARK_BG = "#141318"
CARD_BG = "#1e1d24"
CARD_STROKE = "#2c2b34"
TEXT_MAIN = "#eceaf2"
TEXT_DIM = "#8f8d99"
ACCENT = "#4f8cff"
GREEN = "#39d98a"
RED = "#ff5a5f"

STYLE = f"""
QMainWindow, QWidget {{ background: {DARK_BG}; }}
QLabel {{ color: {TEXT_MAIN}; font-size: 13px; background: transparent; }}
QLabel[dim=true] {{ color: {TEXT_DIM}; font-size: 11px; }}
QLineEdit {{
    background: {CARD_BG}; color: {TEXT_MAIN};
    border: 1px solid {CARD_STROKE}; border-radius: 16px;
    padding: 8px 14px; font-size: 13px;
}}
QLineEdit:focus {{ border-color: {ACCENT}; }}
QPushButton {{
    background: {CARD_BG}; color: {TEXT_MAIN};
    border: 1px solid {CARD_STROKE}; border-radius: 15px;
    padding: 7px 16px; font-size: 12px;
}}
QPushButton:hover {{ border-color: {ACCENT}; color: {ACCENT}; }}
QPushButton:pressed {{ background: #26252e; }}
QPushButton:checked {{ background: {ACCENT}; color: white; border-color: {ACCENT}; }}
QPushButton:disabled {{ color: {TEXT_DIM}; }}
QPushButton#primary {{ background: {ACCENT}; color: white; border: none; font-weight: 600; }}
QPushButton#primary:hover {{ background: #66a0ff; color: white; }}
QPushButton#primary:disabled {{ background: #33384a; color: #767b8c; }}
QPushButton#danger {{ color: {RED}; }}
QComboBox {{
    background: {CARD_BG}; color: {TEXT_MAIN};
    border: 1px solid {CARD_STROKE}; border-radius: 14px;
    padding: 5px 12px; font-size: 12px;
}}
QComboBox::drop-down {{ border: none; width: 18px; }}
QComboBox QAbstractItemView {{
    background: {CARD_BG}; color: {TEXT_MAIN};
    selection-background-color: {ACCENT}; border: 1px solid {CARD_STROKE};
}}
QCheckBox {{ color: {TEXT_MAIN}; font-size: 12px; spacing: 6px; background: transparent; }}
QCheckBox::indicator {{
    width: 16px; height: 16px; border-radius: 5px;
    border: 1px solid {CARD_STROKE}; background: {CARD_BG};
}}
QCheckBox::indicator:checked {{ background: {ACCENT}; border-color: {ACCENT}; }}
QListWidget {{ background: transparent; border: none; outline: none; }}
QListWidget::item {{ color: {TEXT_MAIN}; padding: 4px 2px; border-radius: 6px; }}
QListWidget::item:selected {{ background: #2a2f40; }}
QScrollBar:vertical {{ width: 0; }}
QSlider::groove:horizontal {{ height: 5px; border-radius: 2px; background: {CARD_STROKE}; }}
QSlider::sub-page:horizontal {{ background: {ACCENT}; border-radius: 2px; }}
QSlider::handle:horizontal {{
    width: 14px; margin: -5px 0; border-radius: 7px;
    background: white; border: 2px solid {ACCENT};
}}
"""


def make_card() -> QFrame:
    card = QFrame()
    card.setStyleSheet(f"""
        QFrame {{ background: {CARD_BG}; border: 1px solid {CARD_STROKE};
                  border-radius: 16px; }}
    """)
    shadow = QGraphicsDropShadowEffect(card)
    shadow.setBlurRadius(18)
    shadow.setOffset(0, 3)
    shadow.setColor(Qt.black)
    card.setGraphicsEffect(shadow)
    return card


def dim_label(text: str) -> QLabel:
    lbl = QLabel(text)
    lbl.setProperty("dim", True)
    return lbl


# ---------------------------------------------------------------- widgets

class ProgressCard(QWidget):
    cancel_clicked = Signal(int)

    def __init__(self, task_id: int, spec: TaskSpec):
        super().__init__()
        self.task_id = task_id
        root = QHBoxLayout(self)
        root.setContentsMargins(4, 6, 4, 6)
        root.setSpacing(10)

        col = QVBoxLayout()
        col.setSpacing(4)

        head = QHBoxLayout(spacing=8)
        badge = QLabel(spec.platform or "Video")
        badge.setStyleSheet(f"color:{spec.color or ACCENT}; font-size:11px; font-weight:700;")
        title = QLabel(spec.title[:70] or spec.url)
        title.setStyleSheet("font-weight:600;")
        head.addWidget(badge)
        head.addWidget(title, stretch=1)

        self.track = QFrame()
        self.track.setFixedHeight(6)
        self.track.setStyleSheet(f"background:{CARD_STROKE}; border-radius:3px;")
        self.fill = QFrame(self.track)
        self.fill.setFixedHeight(6)
        self.fill.setStyleSheet(f"background:{ACCENT}; border-radius:3px;")
        self.fill.setGeometry(1, 0, 1, 6)

        self.status_lbl = dim_label("у черзі")

        col.addLayout(head)
        col.addWidget(self.track)
        col.addWidget(self.status_lbl)
        root.addLayout(col, stretch=1)

        self.cancel_btn = QPushButton("✕")
        self.cancel_btn.setFixedSize(26, 26)
        self.cancel_btn.setToolTip("Скасувати / прибрати")
        self.cancel_btn.clicked.connect(lambda: self.cancel_clicked.emit(self.task_id))
        root.addWidget(self.cancel_btn, alignment=Qt.AlignTop)

    def update_state(self, progress: float, status: str, finished: bool, failed: bool):
        self.status_lbl.setText(status)
        w = max(1, int((self.track.width() - 2) * min(max(progress, 0), 1)))
        self.fill.setGeometry(1, 0, w, 6)
        if finished:
            self.fill.setStyleSheet(f"background:{GREEN}; border-radius:3px;")
            self.status_lbl.setStyleSheet(f"color:{GREEN}; font-size:11px;")
            self.cancel_btn.setText("📁")
            self.cancel_btn.setToolTip("Відкрити папку")
        elif failed:
            self.fill.setStyleSheet(f"background:{RED}; border-radius:3px;")
            self.status_lbl.setStyleSheet(f"color:{RED}; font-size:11px;")


class ClipRangeBar(QWidget):
    range_changed = Signal(float, float)

    def __init__(self):
        super().__init__()
        lay = QVBoxLayout(self)
        lay.setContentsMargins(0, 2, 0, 2)
        lay.setSpacing(6)

        row = QHBoxLayout()
        self.start_lbl = QLabel("0:00")
        self.end_lbl = QLabel("--:--")
        mono = "font-size:12px; font-family:'Consolas',monospace;"
        self.start_lbl.setStyleSheet(mono + f"color:{ACCENT};")
        self.end_lbl.setStyleSheet(mono + f"color:{ACCENT};")
        mid = QLabel("✂ обери ділянку")
        mid.setStyleSheet(f"color:{TEXT_DIM}; font-size:11px;")
        mid.setAlignment(Qt.AlignCenter)
        row.addWidget(self.start_lbl)
        row.addWidget(mid, stretch=1)
        row.addWidget(self.end_lbl)

        s1 = QHBoxLayout()
        s1.addWidget(dim_label("початок"))
        self.s_start = QSlider(Qt.Horizontal)
        s1.addWidget(self.s_start, stretch=1)
        s2 = QHBoxLayout()
        s2.addWidget(dim_label("кінець "))
        self.s_end = QSlider(Qt.Horizontal)
        self.s_end.setValue(1000)
        s2.addWidget(self.s_end, stretch=1)

        lay.addLayout(row)
        lay.addLayout(s1)
        lay.addLayout(s2)

        self.duration = 60.0
        self.s_start.valueChanged.connect(self._changed)
        self.s_end.valueChanged.connect(self._changed)

    def set_duration(self, d: float):
        self.duration = max(d, 1.0)
        self.end_lbl.setText(fmt_duration(d))
        self.s_start.setValue(0)
        self.s_end.setValue(1000)

    def _changed(self):
        sv, ev = self.s_start.value(), self.s_end.value()
        if ev - sv < 20:  # <2% span → push apart
            if self.sender() is self.s_start:
                self.s_start.setValue(max(0, ev - 20))
            else:
                self.s_end.setValue(min(1000, sv + 20))
            return
        s = sv / 1000 * self.duration
        e = ev / 1000 * self.duration
        self.start_lbl.setText(fmt_duration(s))
        self.end_lbl.setText(fmt_duration(e))
        self.range_changed.emit(round(s, 2), round(e, 2))

    def values(self) -> tuple[float, float]:
        return (round(self.s_start.value() / 1000 * self.duration, 2),
                round(self.s_end.value() / 1000 * self.duration, 2))


# ---------------------------------------------------------------- main window

RES_MAP = [("4K", 2160), ("1440p", 1440), ("1080p", 1080),
           ("720p", 720), ("480p", 480), ("360p", 360)]
SIZE_MAP = [("Оригінал", 0), ("50 MB", 50), ("100 MB", 100),
            ("200 MB", 200), ("500 MB", 500)]


class MainWindow(QMainWindow):

    def __init__(self):
        super().__init__()
        self.setWindowTitle("Clip — завантажувач відео")
        self.resize(660, 760)
        self.settings = Settings()
        self.history = History()
        self.meta: dict = {}
        self.tasks: dict[int, dict] = {}
        self.next_task_id = 1
        self.vt_path = ""

        central = QWidget()
        self.setCentralWidget(central)
        root = QVBoxLayout(central)
        root.setContentsMargins(18, 16, 18, 14)
        root.setSpacing(12)

        root.addWidget(self._card_url())
        self.preview = self._card_preview()
        self.preview.setVisible(False)
        root.addWidget(self.preview)
        root.addWidget(self._card_options())
        root.addWidget(self._card_video_tools())
        root.addWidget(self._card_lists(), stretch=1)
        foot = dim_label(
            f"Зберігає у: {self.settings.save_dir}   ·   "
            f"yt-dlp {'✓' if shutil.which('yt-dlp') or 'yt-dlp' not in (YTDLP,) else '?'} · ffmpeg {'✓' if FFMPEG else '—'}")
        root.addWidget(foot)

        # Ctrl+V anywhere pastes & analyzes
        from PySide6.QtGui import QAction, QKeySequence
        act = QAction(self)
        act.setShortcut(QKeySequence("Ctrl+V"))
        act.triggered.connect(self.paste_and_analyze)
        self.addAction(act)

    # -- cards ----------------------------------------------------------
    def _card_url(self) -> QFrame:
        card = make_card()
        lay = QHBoxLayout(card)
        lay.setContentsMargins(14, 12, 14, 12)
        lay.setSpacing(8)
        self.url_edit = QLineEdit()
        self.url_edit.setPlaceholderText("Встав посилання на відео…")
        self.url_edit.textChanged.connect(lambda _: self.refresh_buttons())
        self.url_edit.returnPressed.connect(self.analyze)
        b_paste = QPushButton("Вставити")
        b_paste.clicked.connect(self.paste_and_analyze)
        self.b_analyze = QPushButton("Аналізувати")
        self.b_analyze.setObjectName("primary")
        self.b_analyze.clicked.connect(self.analyze)
        lay.addWidget(self.url_edit, stretch=1)
        lay.addWidget(b_paste)
        lay.addWidget(self.b_analyze)
        return card

    def _card_preview(self) -> QFrame:
        card = make_card()
        lay = QHBoxLayout(card)
        lay.setContentsMargins(14, 12, 14, 12)
        lay.setSpacing(12)
        self.thumb = QLabel("🎬")
        self.thumb.setFixedSize(132, 76)
        self.thumb.setAlignment(Qt.AlignCenter)
        self.thumb.setStyleSheet(
            f"background:{CARD_STROKE}; border:none; border-radius:10px; font-size:30px;")
        info = QVBoxLayout(spacing=3)
        self.title_lbl = QLabel("")
        self.title_lbl.setWordWrap(True)
        self.title_lbl.setStyleSheet("font-weight:600; font-size:13px;")
        self.meta_lbl = dim_label("")
        info.addWidget(self.title_lbl)
        info.addWidget(self.meta_lbl)
        lay.addWidget(self.thumb)
        lay.addLayout(info, stretch=1)
        return card

    def _card_options(self) -> QFrame:
        card = make_card()
        outer = QVBoxLayout(card)
        outer.setContentsMargins(14, 12, 14, 12)
        outer.setSpacing(10)

        row = QHBoxLayout(spacing=10)
        row.addWidget(dim_label("Формат"))
        self.fmt_combo = QComboBox()
        self.fmt_combo.addItems(["MP4", "MOV", "WebM", "MP3"])
        row.addWidget(self.fmt_combo)
        row.addSpacing(6)
        row.addWidget(dim_label("Якість"))
        self.res_combo = QComboBox()
        self.res_combo.addItems([r for r, _ in RES_MAP])
        self.res_combo.setCurrentText("1080p")
        row.addWidget(self.res_combo)
        row.addSpacing(6)
        row.addWidget(dim_label("Розмір"))
        self.size_combo = QComboBox()
        self.size_combo.addItems([s for s, _ in SIZE_MAP])
        row.addWidget(self.size_combo)
        row.addStretch(1)
        outer.addLayout(row)

        row2 = QHBoxLayout(spacing=10)
        self.clip_check = QCheckBox("Кліп ✂")
        self.clip_check.toggled.connect(self.toggle_clip)
        row2.addWidget(self.clip_check)
        row2.addStretch(1)
        b_dir = QPushButton("Папка збереження…")
        b_dir.clicked.connect(self.choose_dir)
        row2.addWidget(b_dir)
        self.b_download = QPushButton("⬇ Завантажити")
        self.b_download.setObjectName("primary")
        self.b_download.setEnabled(False)
        self.b_download.clicked.connect(self.start_download)
        row2.addWidget(self.b_download)
        outer.addLayout(row2)

        self.clipbar = ClipRangeBar()
        self.clipbar.setVisible(False)
        outer.addWidget(self.clipbar)
        return card

    def _card_video_tools(self) -> QFrame:
        card = make_card()
        outer = QVBoxLayout(card)
        outer.setContentsMargins(14, 12, 14, 12)
        outer.setSpacing(10)

        outer.addWidget(dim_label("🎬 Інструменти відео — будь-який локальний файл"))

        row = QHBoxLayout(spacing=8)
        b_open = QPushButton("Відкрити файл…")
        b_open.clicked.connect(self.vt_choose_file)
        self.vt_path_lbl = dim_label("Файл не обрано")
        row.addWidget(b_open)
        row.addWidget(self.vt_path_lbl, stretch=1)
        outer.addLayout(row)

        row2 = QHBoxLayout(spacing=10)
        row2.addWidget(dim_label("Режим петлі"))
        self.vt_loop_mode = QComboBox()
        self.vt_loop_mode.addItems(["Розумний (авто)", "Кросфейд", "Бумеранг"])
        row2.addWidget(self.vt_loop_mode)
        row2.addStretch(1)
        self.b_vt_crop = QPushButton("▭ Прибрати чорні смуги")
        self.b_vt_crop.setEnabled(False)
        self.b_vt_crop.clicked.connect(lambda: self.vt_run("crop"))
        self.b_vt_loop = QPushButton("🔁 Зробити loop")
        self.b_vt_loop.setEnabled(False)
        self.b_vt_loop.clicked.connect(lambda: self.vt_run("loop"))
        row2.addWidget(self.b_vt_crop)
        row2.addWidget(self.b_vt_loop)
        outer.addLayout(row2)

        self.vt_status = dim_label("")
        outer.addWidget(self.vt_status)
        return card

    def _card_lists(self) -> QFrame:
        card = make_card()
        lay = QVBoxLayout(card)
        lay.setContentsMargins(14, 12, 14, 12)
        lay.setSpacing(8)

        tabs = QHBoxLayout(spacing=6)
        self.tab_dl = QPushButton("Завантаження")
        self.tab_hist = QPushButton("Історія")
        for i, b in enumerate((self.tab_dl, self.tab_hist)):
            b.setCheckable(True)
        self.tab_dl.setChecked(True)
        self.tab_dl.clicked.connect(lambda: self.switch_tab(0))
        self.tab_hist.clicked.connect(lambda: self.switch_tab(1))
        tabs.addWidget(self.tab_dl)
        tabs.addWidget(self.tab_hist)
        tabs.addStretch(1)
        b_clear = QPushButton("Очистити список")
        b_clear.setObjectName("danger")
        b_clear.clicked.connect(self.clear_finished)
        tabs.addWidget(b_clear)
        lay.addLayout(tabs)

        self.stack = QStackedWidget()
        self.dl_col = QVBoxLayout()
        self.dl_col.setSpacing(2)
        holder = QWidget()
        holder.setLayout(self.dl_col)
        self.empty_lbl = dim_label("Ще нічого не завантажено.\nВстав посилання вище та натисни «Аналізувати».")
        self.empty_lbl.setAlignment(Qt.AlignCenter)
        self.dl_col.addWidget(self.empty_lbl)
        self.dl_col.addStretch(1)
        self.stack.addWidget(holder)

        self.hist_list = QListWidget()
        self.hist_list.itemDoubleClicked.connect(self.open_history_item)
        self.stack.addWidget(self.hist_list)
        lay.addWidget(self.stack, stretch=1)
        return card

    # -- actions --------------------------------------------------------
    def refresh_buttons(self):
        has_url = bool(first_url(self.url_edit.text()))
        self.b_analyze.setEnabled(has_url)
        self.b_download.setEnabled(has_url)

    def paste_and_analyze(self):
        url = first_url(QApplication.clipboard().text())
        if not url:
            return
        if url != first_url(self.url_edit.text()):
            self.url_edit.setText(url)
        self.analyze()

    def analyze(self):
        url = first_url(self.url_edit.text())
        if not url:
            return
        self.b_analyze.setEnabled(False)
        self.b_analyze.setText("Аналізую…")
        self.worker_a = AnalyzeWorker(url)
        self.worker_a.got_meta.connect(self.show_meta)
        self.worker_a.failed.connect(self.meta_failed)
        self.worker_a.finished.connect(self.analyze_finished)
        self.worker_a.start()

    def analyze_finished(self):
        self.b_analyze.setEnabled(True)
        self.b_analyze.setText("Аналізувати")

    def show_meta(self, meta: dict):
        self.meta = meta
        self.preview.setVisible(True)
        plat = meta.get("_platform", "")
        dur = fmt_duration(meta.get("duration"))
        self.title_lbl.setText(meta.get("title") or "Без назви")
        extra = []
        if meta.get("uploader"):
            extra.append(meta["uploader"])
        if dur:
            extra.append(dur)
        self.meta_lbl.setText(plat + ("   ·   " + "  ·  ".join(extra) if extra else ""))
        if meta.get("duration"):
            self.clipbar.set_duration(float(meta["duration"]))
        thumb_url = meta.get("thumbnail")
        if thumb_url:
            self.nam = getattr(self, "nam", None) or QNetworkAccessManager(self)
            reply = self.nam.get(QNetworkRequest(QUrl(thumb_url)))
            reply.finished.connect(lambda r=reply: self.thumb_loaded(r))

    def thumb_loaded(self, reply: QNetworkReply):
        if reply.error() == QNetworkReply.NoError:
            pix = QPixmap()
            if pix.loadFromData(reply.readAll()):
                self.thumb.setPixmap(pix.scaled(
                    self.thumb.size(), Qt.KeepAspectRatioByExpanding,
                    Qt.SmoothTransformation))
        reply.deleteLater()

    def meta_failed(self, msg: str):
        self.preview.setVisible(False)
        QMessageBox.warning(self, "Аналіз не вдався",
                            msg or "Не вдалося отримати інформацію про відео")

    def toggle_clip(self, on: bool):
        self.clipbar.setVisible(on)
        if on and self.meta.get("duration"):
            self.clipbar.set_duration(float(self.meta["duration"]))

    def choose_dir(self):
        d = QFileDialog.getExistingDirectory(self, "Папка збереження",
                                             str(self.settings.save_dir))
        if d:
            self.settings.data["save_dir"] = d
            self.settings.save()

    # -- video tools ------------------------------------------------------
    def vt_choose_file(self):
        path, _ = QFileDialog.getOpenFileName(
            self, "Обрати відео", str(self.settings.save_dir),
            "Відео (*.mp4 *.mov *.webm *.mkv *.avi)")
        if not path:
            return
        self.vt_path = path
        self.vt_path_lbl.setText(Path(path).name)
        self.b_vt_loop.setEnabled(True)
        self.b_vt_crop.setEnabled(True)
        self.vt_status.setText("")

    def vt_run(self, op: str):
        if not self.vt_path:
            return
        self.b_vt_loop.setEnabled(False)
        self.b_vt_crop.setEnabled(False)
        self.vt_status.setStyleSheet(f"color:{TEXT_DIM}; font-size:11px;")
        self.vt_status.setText("шукаю точку петлі…" if op == "loop" else "шукаю чорні смуги…")
        mode_map = {"Розумний (авто)": "smart", "Кросфейд": "crossfade", "Бумеранг": "boomerang"}
        loop_mode = mode_map[self.vt_loop_mode.currentText()]
        self.vt_worker = VideoToolWorker(self.vt_path, self.settings.save_dir, op, loop_mode)
        self.vt_worker.done_sig.connect(self.vt_done)
        self.vt_worker.start()

    def vt_done(self, out_path: str, err: object):
        self.b_vt_loop.setEnabled(True)
        self.b_vt_crop.setEnabled(True)
        if err:
            self.vt_status.setStyleSheet(f"color:{RED}; font-size:11px;")
            self.vt_status.setText(f"помилка: {err}")
            return
        self.vt_status.setStyleSheet(f"color:{GREEN}; font-size:11px;")
        self.vt_status.setText(f"готово ✓ {Path(out_path).name}")
        spec = TaskSpec(url=self.vt_path, title=Path(out_path).name,
                         platform="Video Tools", color=ACCENT)
        spec.output_path = out_path
        self.history.add(spec)

    def switch_tab(self, idx: int):
        self.tab_dl.setChecked(idx == 0)
        self.tab_hist.setChecked(idx == 1)
        self.stack.setCurrentIndex(idx)
        if idx == 1:
            self.reload_history()

    def reload_history(self):
        self.hist_list.clear()
        for e in self.history.entries[:HISTORY_LIMIT]:
            dt = e.get("date", "")[:16].replace("T", " ")
            item = QListWidgetItem(f"{dt}   [{e.get('platform', '')}]  {e.get('title', '')[:70]}")
            item.setData(Qt.UserRole, e.get("path", ""))
            self.hist_list.addItem(item)

    def open_history_item(self, item: QListWidgetItem):
        path = item.data(Qt.UserRole)
        if path and os.path.exists(path):
            QDesktopServices.openUrl(QUrl.fromLocalFile(Path(path).parent))

    # -- queue ----------------------------------------------------------
    def start_download(self):
        url = first_url(self.url_edit.text()) or self.meta.get("_effective_url", "")
        if not url:
            return
        res = dict(RES_MAP)[self.res_combo.currentText()]
        size = dict(SIZE_MAP)[self.size_combo.currentText()]
        plat_name, plat_color = detect_platform(url)
        clip_on = self.clip_check.isChecked()
        cs, ce = self.clipbar.values() if clip_on else (-1.0, -1.0)

        spec = TaskSpec(
            url=url,
            title=(self.meta.get("title") if self.meta else "") or url,
            platform=self.meta.get("_platform") or plat_name,
            color=self.meta.get("_color") or plat_color,
            fmt=self.fmt_combo.currentText().lower(),
            resolution=res,
            size_mb=size,
            clip_start=cs if clip_on else -1.0,
            clip_end=ce if clip_on else -1.0,
        )
        tid = self.next_task_id
        self.next_task_id += 1

        card = ProgressCard(tid, spec)
        card.cancel_clicked.connect(self.on_card_button)
        self.empty_lbl.setVisible(False)
        self.dl_col.insertWidget(self.dl_col.count() - 1, card)
        self.tasks[tid] = {"spec": spec, "card": card}
        self.pump_queue()

    def pump_queue(self):
        running = sum(1 for v in self.tasks.values() if v["spec"].status == "running")
        for tid, v in list(self.tasks.items()):
            if running >= MAX_CONCURRENT:
                break
            spec = v["spec"]
            if spec.status != "queued":
                continue
            spec.status = "running"
            v["card"].update_state(0.0, "у черзі → старт", False, False)
            worker = DownloadWorker(tid, spec, self.settings.save_dir)
            worker.changed.connect(self.on_task_changed)
            worker.done_sig.connect(self.on_task_done)
            v["worker"] = worker
            worker.start()
            running += 1

    def on_card_button(self, tid: int):
        v = self.tasks.get(tid)
        if not v:
            return
        spec = v["spec"]
        if spec.status == "running":
            DownloadWorker.cancel(tid)   # flag state before killing process
            spec.status = "failed"
            v["card"].update_state(0.0, "скасовано", False, True)
        elif spec.status in ("done", "failed"):
            if spec.output_path and os.path.exists(spec.output_path):
                QDesktopServices.openUrl(QUrl.fromLocalFile(Path(spec.output_path).parent))
            else:
                self.drop_task(tid)
        else:
            self.drop_task(tid)
        self.pump_queue()

    def drop_task(self, tid: int):
        v = self.tasks.pop(tid, None)
        if v:
            v["card"].setParent(None)
            v["card"].deleteLater()
        self.empty_lbl.setVisible(not any(
            v for v in self.tasks.values()))

    def clear_finished(self):
        for tid in [t for t, v in self.tasks.items()
                    if v["spec"].status in ("done", "failed")]:
            self.drop_task(tid)

    # -- worker callbacks -------------------------------------------------
    def on_task_changed(self, tid: int, progress: float, status: str):
        v = self.tasks.get(tid)
        if v:
            v["card"].update_state(progress, status, False, False)

    def on_task_done(self, tid: int, err: object):
        v = self.tasks.get(tid)
        if not v:
            return
        spec = v["spec"]
        if err:
            spec.status = "failed"
            v["card"].update_state(0.0, f"помилка: {err}", False, True)
        else:
            spec.status = "done"
            self.history.add(spec)
        self.pump_queue()


def main():
    app = QApplication(sys.argv)
    app.setStyle("Fusion")
    app.setStyleSheet(STYLE)
    app.setApplicationName("Clip")
    win = MainWindow()
    win.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
