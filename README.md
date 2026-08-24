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

## Файли
- clip_app.py — весь апп (один файл)
- clip_history.json / clip_settings.json — створюються поруч при роботі
