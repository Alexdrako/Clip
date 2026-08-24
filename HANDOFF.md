# HANDOFF

## Стан
Windows GUI-завантажувач відео (PySide6 + yt-dlp + ffmpeg), один файл clip_app.py.
macOS/Swift-версію видалено з репо за рішенням користувача (була попередньо запушена).

## Що зроблено
- clip_app.py: URL-картка (Вставити/Аналізувати/Ctrl+V), прев'ю (thumbnail через QNetworkAccessManager),
  опції (формат/якість/розмір/кліп-слайдери), черга max 3 (DownloadWorker QThread, terminate для cancel),
  прогрес-бари, історія в JSON, налаштування папки в JSON, темна glass-тема через QSS.
- Бінарники: shutil.which + WinGet fallback (yt-dlp, ffmpeg, ffprobe є на машині).
- Reddit фікс через api.reddit.com; Instagram --cookies-from-browser chrome.

## Перевірки
- py_compile OK; offscreen smoke-тест 12 с без крашів (QT_QPA_PLATFORM=offscreen, exit 124 = timeout живого процесу).
- Живий тест із реальним URL ще не проведений — зробити першим ділом.

## Ризики / відомі місця
- Цільовий розмір рахується двопрохідно приблизно (bitrate budget), точність ±10%.
- Кліп для mp3 не застосовується (mp3 = тільки аудіо).
- Instagram cookies працюють лише якщо користувач залогінений у Chrome.
- Скасування під час ffmpeg-паса не перериває ffmpeg (тільки yt-dlp процес).

## Наступні кроки
1. Живий тест: python clip_app.py → завантажити щось з YouTube.
2. Опційно: PyInstaller --onefile для exe без консолі.
