# Clip — macOS video downloader (yt-dlp + SwiftUI)

Native macOS app wrapping yt-dlp/ffmpeg. Tahoe Liquid Glass design, macOS 14+, Swift 5.9.

## Layout
- `project.yml` — xcodegen spec (app target, entitlements, pre-build binary fetch)
- `Clip/` — sources: App, Theme, Constants, Models/, ViewModels/, Views/, Services/
- `scripts/fetch_binaries.sh` — downloads yt-dlp (universal) + ffmpeg/ffprobe into Resources/bin
- `.github/workflows/build.yml` — builds Clip.app on macos-14 runner, uploads artifact

## Build locally (needs a Mac)
```bash
brew install xcodegen && xcodegen generate
bash scripts/fetch_binaries.sh Clip/Resources/bin   # optional; CI does it too
xcodebuild -project Clip.xcodeproj -scheme Clip build
rm -rf /Applications/Clip.app && cp -R build/Build/Products/Debug/Clip.app /Applications/
xattr -cr /Applications/Clip.app && open /Applications/Clip.app
```

## Build without a Mac
Push to `main` → GitHub Actions → download `Clip-macOS` artifact from the run page.
First launch after download: `xattr -cr ~/Downloads/Clip.app` (unsigned binary).

## Critical patterns baked in
1. Bundled binary paths via `Bundle.main.bundlePath + "/Contents/Resources/bin"` (never path(forResource:))
2. PATH prepends bundled bin + homebrew dirs for child processes
3. Reddit resolved manually via api.reddit.com (yt-dlp extractor broken)
4. Instagram auto-detects browser cookies (`--cookies-from-browser`)
5. Cancel flags state before terminating the Process
6. Queue calls `startNextQueued()` after completion/failure/cancel (max 3 concurrent)
7. Window close = hide (WindowCloseInterceptor)
8. Thread safety: @MainActor VMs, actor YTDLPService, NSLock OutputPathHolder
9. Deploy uses rm -rf before cp -R
10. Animations: easeInOut 0.2s pills, spring clip-range, crossfade tabs, bounce scissors

## Known limitations
- No code-signing / notarization (ad-hoc only) → Gatekeeper needs xattr -cr
- ffmpeg arm64 slice best-effort from osxexperts; falls back to x86_64+Rosetta
- Update check compares GitHub "latest" tag against CFBundleShortVersionString
