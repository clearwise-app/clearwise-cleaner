# Платная подписка: как устроено и что заполнить

Clearwise Cleaner продаётся по подписке через два канала:

| | Версия с сайта (полная) | Версия из App Store (Lite) |
|---|---|---|
| Кто берёт деньги | Paddle, Merchant of Record: сам берёт налоги и выставляет чеки | Apple |
| Комиссия | 5% + $0.50 с платежа ([Paddle](https://www.paddle.com/pricing)) | 15% в Small Business Program, иначе 30% ([Apple](https://developer.apple.com/app-store/small-business-program/)) |
| Проверка подписки | наш сервер `server/` выдаёт подписанную лицензию | StoreKit 2 на устройстве, сервер не нужен |
| Пробный период | 7 дней с первого запуска, считает приложение | бесплатная неделя как introductory offer в App Store Connect |
| Код в приложении | `Sources/MacCleaner/Licensing/SiteLicense.swift` | `Sources/MacCleaner/Licensing/StoreSubscription.swift` |

Сканирование бесплатное всегда. Подписка нужна для очистки: после пробного периода нажатие «Очистить» в любом разделе открывает экран подписки (`AccessModel.requireAccess` в `RootView`).

## Главный риск: продавец из РФ

- **Paddle, Lemon Squeezy и Polar** не работают с продавцами из России и не продают покупателям в России ([Paddle](https://www.paddle.com/help/start/intro-to-paddle/which-countries-are-supported-by-paddle), [Lemon Squeezy](https://docs.lemonsqueezy.com/help/getting-started/supported-countries), [Polar](https://polar.sh/docs/merchant-of-record/supported-countries)).
- **Apple** на аккаунтах из РФ отвечает, что платные приложения и встроенные покупки недоступны ([Apple Developer Forums](https://developer.apple.com/forums/thread/827175), [ещё тред](https://developer.apple.com/forums/thread/849726)).

Отсюда варианты:

1. **Продавец вне РФ.** ИП или компания в стране, где у вас есть резидентство и банковский счёт, и оттуда же аккаунт Apple Developer. По документации выплаты Polar через Stripe проходят в Казахстан, Армению, Сербию и ОАЭ ([Polar](https://polar.sh/docs/merchant-of-record/supported-countries)). У Paddle Россия и Беларусь в списке запрещённых, а остальные страны СНГ нет. Каркас рассчитан на этот вариант.
2. **Покупатели из РФ** через ИП в РФ и ЮKassa (рубли, чеки по 54-ФЗ). Для этого нужен второй адаптер в `server/src/billing/`, интерфейс под него уже готов (`BillingProvider`).
3. **До открытия продаж** можно поставить `BILLING_PROVIDER=manual` и выдавать подписки тестерам руками (`POST /admin/grant`).

Персональные данные. С 1 июля 2025 года первичный сбор персональных данных граждан РФ должен идти в базы, которые находятся в России ([Habr](https://habr.com/ru/articles/943422), [ComNews](https://www.comnews.ru/digital-economy/content/241730/2025-10-13/2025-w42/1016/granica-zamke-osobennosti-raboty-personalnymi-dannymi-rossii)). Сервер хранит только почту и анонимный идентификатор Mac. Если продавец российский или покупатели в основном из РФ, сервер лучше держать в РФ. Если продавец иностранный, применимо ли это требование, стоит уточнить у юриста.

## Как работает версия с сайта

```
Mac app ──(почта)──▶ POST /api/auth/request-code ──▶ письмо с 6-значным кодом
Mac app ──(код)────▶ POST /api/auth/verify-code  ──▶ токен сессии (Keychain)
Mac app ──────────▶ POST /api/license/activate   ──▶ лицензия CW1.<payload>.<Ed25519>
                                                    402 — нет подписки, 409 — занято 3 Mac
Браузер  /account?plan=yearly ──▶ Paddle.js checkout ──▶ Paddle ──▶ POST /webhooks/paddle ──▶ subscriptions
```

- **Лицензия** подписана закрытым ключом сервера. Приложение проверяет её открытым ключом из `LicenseConfig.swift`, сеть для этого не нужна. Токен привязан к Mac (SHA-256 от аппаратного UUID) и живёт `LICENSE_OFFLINE_DAYS` дней (по умолчанию 14). Пока есть сеть, приложение обновляет его раз в сутки.
- **Отмена и неоплата.** После отмены подписка работает до конца оплаченного периода. Если продление не прошло (past_due), даётся ещё `LICENSE_GRACE_DAYS` дней (по умолчанию 7). Срок токена не выходит за эти границы.
- **Лимит Mac** задаётся в `MAX_DEVICES` (по умолчанию 3). Лишний Mac отвязывается в приложении или на странице `/account`.
- **Покупка без входа**, например по ссылке из кабинета Paddle, тоже засчитывается: сервер находит или создаёт аккаунт по почте покупателя.
- **Вебхуки** сохраняются с `event_id`, поэтому повтор не обрабатывается дважды. Событие, пришедшее с опозданием, не перезаписывает более новое (`provider_event_at`).
- **MCP-сервер** (`clearwise-mcp`) лицензию пока не проверяет. Если это важно, проверку стоит добавить следующим шагом.

## Что заполнить перед релизом

| Где | Что |
|---|---|
| `server/.env` | всё по `server/.env.example`, см. [DEPLOY.md](DEPLOY.md) |
| `Sources/MacCleaner/Licensing/LicenseConfig.swift` | `apiBase` (домен сервера), `publicKey` (= `LICENSE_PUBLIC_KEY`), `storeProductIDs`, `termsURL`, `privacyURL` |
| Сайт | кнопка «Скачать» → `https://API_DOMAIN/download`, ссылка «Аккаунт» → `/account`, страницы условий, возврата и политики конфиденциальности (Paddle проверяет их до одобрения) |
| Тексты | убрать «Бесплатно» с сайта и из README, переписать «работает без интернета» (приложение уже говорит «в сеть ходит только проверка подписки») |
| Строки | новые строки экрана подписки пока только на русском, их нужно добавить в `Localizable.xcstrings` |

## Сборка двух версий

- Версия с сайта собирается как раньше (`scripts/build_app.sh`).
- Версия для App Store собирается с флагом `CLEARWISE_LITE`: `swift build -Xswiftc -DCLEARWISE_LITE`. Флаг подключает StoreKit вместо серверной лицензии. Отдельная цель Xcode, песочница и вырезание модулей описаны в ТЗ и делаются отдельно, см. [APP_STORE.md](APP_STORE.md).
