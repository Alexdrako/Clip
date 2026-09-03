# Clip — завантажувач відео для Windows

GUI-обгортка над yt-dlp + ffmpeg. PySide6, темна «glass» тема.
Платформи: YouTube, X/Twitter, Instagram, TikTok, Reddit (+ будь-які сайти yt-dlp).

## Запуск
```bash
pip install PySide6
python C:\Users\alexd\projects\Clip\clip_app.py
```

Вимоги: yt-dlp та ffmpeg у PATH (у мене стоять через pip + winget — підхоплюються автоматично).

## Можливості
- Поле URL + Вставити/Аналізувати (Ctrl+V глобально), прев'ю з thumbnail і тривалістю
- Формат: MP4 / MOV / WebM / MP3 · Якість: 4K–360p · Цільовий розмір: оригінал/50/100/200/500 MB
- Кліп ✂ — слайдери початок/кінець, трим у ffmpeg після завантаження
- Черга до 3 паралельних завантажень, прогрес, скасування, відкрити папку 📁
- Історія (подвійний клік — відкрити папку), JSON-персист
- Папка збереження налаштовується (за замовчуванням Downloads)

## Фікси всередині
- Reddit: yt-dlp extractor зламаний → прямий резолв через api.reddit.com
- Instagram: --cookies-from-browser chrome

## Batch-конвеєр (batch.py)
Обробка вже наявних відео пресетами, без GUI:
```bash
python batch.py IN_DIR OUT_DIR --preset vertical                       # 9:16 під TikTok/Reels/Shorts
python batch.py IN_DIR OUT_DIR --preset horizontal                     # 16:9
python batch.py IN_DIR OUT_DIR --preset audio                          # витягти mp3
python batch.py IN_DIR OUT_DIR --preset copy --size-mb 50              # стиснути під розмір
python batch.py IN_DIR OUT_DIR --preset vertical --watermark X,Y,W,H   # + видалити watermark (delogo)
```
`--watermark X,Y,W,H` — координати фіксованого прямокутника (лого/нашивка) в пікселях від
лівого верхнього кута вихідного відео; підбираються вручну (напр. через `ffprobe`/перегляд кадру).
Це `ffmpeg delogo` — інтерполяція сусідніх пікселів, не AI-inpainting: працює добре на
статичному лого на рівному фоні, гірше — на складному/рухомому фоні.

Генерація нового контенту через API/MCP — поки не реалізовано (свідомо відкладено).

## Файли
- clip_app.py — GUI-застосунок (завантаження)
- ffmpeg_core.py — спільні ffmpeg/ffprobe хелпери (бінарники, run, probe_duration)
- batch.py — CLI batch-конвеєр для обробки наявних відео (пресети + watermark removal)
- clip_history.json / clip_settings.json — створюються поруч при роботі
