# HANDOFF

## Стан
Повний вихідний код нативного macOS-аппу Clip (SwiftUI + yt-dlp). Проєкт створено на Windows — компіляції локально немає. Єдиний шлях перевірки — GitHub Actions (macos-14).

## Що зроблено
- project.yml (xcodegen): macOS 14, Swift 5.9, hardened runtime entitlements, preBuildScript fetch_binaries
- scripts/fetch_binaries.sh: yt-dlp_macos universal + ffmpeg/ffprobe (evermeet x86_64, lipo з arm64 за можливості)
- Swift: ClipApp (menu bar + clipboard + close-hides), ClipTheme (GlassCard/GlassProgressBar/pills), Models (Platform/DownloadItem/History/Metadata), ViewModels (MainVM/DownloadVM, черга max 3), Services (YTDLPService actor, FFmpegService, ProcessRunner, URLDetector, ClipboardMonitor, RedditResolver, UpdateService, MenuBarController+popover, TranslucentWindowBackground), Views (ContentView, URLInput, VideoPreview, FormatPicker, ClipRange drag handles, DownloadSection/List, History, Settings, MenuBarView)
- CI workflow: xcodegen → fetch binaries → xcodebuild Release → zip артефакт

## Перевірки
- Локально НЕ компілювалося (Windows, немає Xcode/Swift)
- Очікувана перевірка: green build у GitHub Actions; артефакт Clip-macOS.zip

## Ризики
- ~20 Swift-файлів писані без компілятора: перший CI-білд може падати на типових дрібницях (Sendable-замикання, Color(nsColor:) конверсії) — правиться ітераційно по логах CI
- ffmpeg arm64 залежить від osxexperts.net (сторонній хост); fallback Rosetta
- У DownloadRunner поле cancellations не використовується до кінця (cancel() має no-op для активних процесів поза YTDLPService) — якщо cancel не працює в CI-білді, треба пробросити ProcessRunner через holder

## Наступні кроки
1. Запушити в GitHub (Alexdrako/Clip) → дочекатись CI
2. За фейлом — читати build.log, правити, репушити
3. Після green: завантажити артефакт, xattr -cr, запустити
