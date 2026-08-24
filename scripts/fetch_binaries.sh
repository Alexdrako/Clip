#!/bin/bash
# Fetches yt-dlp + ffmpeg/ffprobe into $1 (default: Clip/Resources/bin).
# Strategy:
#   yt-dlp        – official universal binary from yt-dlp releases.
#   ffmpeg/ffprobe– try lipo(arm64 from osxexperts + x86_64 from evermeet);
#                   fall back to x86_64-only (runs under Rosetta 2).
set -euo pipefail

DEST="${1:-$(dirname "$0")/../Clip/Resources/bin}"
mkdir -p "$DEST"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "==> yt-dlp (universal)"
curl -fsSL --retry 3 -o "$DEST/yt-dlp" \
  "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"
chmod +x "$DEST/yt-dlp"

fetch_evermeet() { # $1 = name -> x86_64 binary at $2
  curl -fsSL --retry 3 -o "$work/$1.zip" "https://evermeet.cx/ffmpeg/getrelease/$1/zip"
  unzip -oq "$work/$1.zip" -d "$work"
  cp "$work/$1" "$2"
}

fetch_arm64() { # best-effort arm64 from osxexperts; $1 = name
  local url
  case "$1" in
    ffmpeg)  url="https://www.osxexperts.net/ffmpeg8arm64.zip" ;;
    ffprobe) url="https://www.osxexperts.net/ffprobe8arm64.zip" ;;
  esac
  curl -fsSL --retry 2 -o "$work/${1}_arm.zip" "$url"
  unzip -oq "$work/${1}_arm.zip" -d "$work/arm" 2>/dev/null || return 1
  find "$work/arm" -name "$1" -type f -exec cp {} "$work/${1}_arm64" \;
  [[ -f "$work/${1}_arm64" ]]
}

for bin in ffmpeg ffprobe; do
  echo "==> $bin"
  rm -f "$DEST/$bin"
  # x86_64 from evermeet is the reliable base; arm64 slice is best-effort.
  if ! fetch_evermeet "$bin" "$work/${bin}_x64"; then
    echo "    WARN: evermeet fetch failed for $bin, trying static build" >&2
    if [[ "$bin" == "ffmpeg" ]]; then
      curl -fsSL --retry 2 -o "$work/ffmpeg.zip" "https://github.com/eugeneware/ffmpeg-static/releases/latest/download/ffmpeg-darwin-arm64" || true
      [[ -s "$work/ffmpeg.zip" ]] && { mv "$work/ffmpeg.zip" "$DEST/ffmpeg"; chmod +x "$DEST/ffmpeg"; }
    fi
  fi
  if [[ "$(uname -m)" == "arm64" ]] && fetch_arm64 "$bin"; then
    echo "    lipo universal (arm64 + x86_64)"
    lipo -create -output "$DEST/$bin" "$work/${bin}_arm64" "$work/${bin}_x64" || cp "$work/${bin}_x64" "$DEST/$bin"
  elif [[ -f "$work/${bin}_x64" ]]; then
    echo "    x86_64 only (Rosetta 2 on Apple Silicon)"
    cp "$work/${bin}_x64" "$DEST/$bin"
  fi
  chmod +x "$DEST/$bin" 2>/dev/null || true
  [[ -f "$DEST/$bin" ]] || { echo "ERROR: $bin missing after all strategies" >&2; }
done

# Never hard-fail the build here — app still builds; downloads will just fail at runtime.
echo "==> fetched:"
ls -la "$DEST"
file "$DEST"/* 2>/dev/null || true