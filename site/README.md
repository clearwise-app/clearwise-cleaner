# Сайт Clearwise Cleaner

Статический сайт без сборки и без сторонних скриптов: HTML + CSS + немного JS.

| Путь | Что это |
|---|---|
| `index.html`, `en/index.html` | Главная: возможности, безопасность, полная версия и Lite, установка, FAQ |
| `privacy.html`, `en/privacy.html` | Политика конфиденциальности (URL для App Store Connect) |
| `support.html`, `en/support.html` | Поддержка (URL для App Store Connect) |
| `assets/img/` | Скриншоты из `docs/screenshots` в WebP, иконка, картинка для превью ссылок |

Посмотреть локально: `python3 -m http.server -d site 8000` → http://localhost:8000

## Что править при релизе и перед запуском

Метки в HTML-комментариях, их удобно искать через `grep -rn "DOWNLOAD_URL\|NOTARIZATION\|SUPPORT_EMAIL" site`:

- `DOWNLOAD_URL` — ссылки на DMG содержат номер версии (`v1.2.1/Clearwise-Cleaner-1.2.1.dmg`), размер и версия указаны в тексте. Обновлять при каждом релизе.
- `NOTARIZATION` — шаг «Всё равно открыть» и предупреждение убрать после подписи Developer ID и нотаризации.
- `SUPPORT_EMAIL` — вписать адрес поддержки.

Скриншоты в английской версии пока на русском: пересобрать их на английском интерфейсе через `--snapshot`.
