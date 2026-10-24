# Публикация в Mac App Store с подпиской

Версия для App Store (Lite) собирается с флагом `CLEARWISE_LITE`. Подписку обслуживает StoreKit 2 (`Sources/MacCleaner/Licensing/StoreSubscription.swift`), сервер для неё не нужен. Ниже шаги по порядку. Шаги 1–3 занимают больше всего календарного времени, потому что проверки Apple идут днями.

## 1. Аккаунт Apple Developer у продавца вне РФ

- Аккаунтам из РФ Apple не подключает договор Paid Apps, без которого не продаются ни платные приложения, ни подписки ([Developer Forums](https://developer.apple.com/forums/thread/827175), [ещё тред](https://developer.apple.com/forums/thread/849726)). Аккаунт должен принадлежать тому же продавцу вне РФ, что и аккаунт Paddle (см. [SUBSCRIPTIONS.md](SUBSCRIPTIONS.md)).
- **Individual** проще: нужны Apple ID с двухфакторной аутентификацией, документ и карта. Имя человека будет видно в App Store как имя продавца.
- **Organization** показывает в App Store название компании, но требует номер D-U-N-S ([Apple](https://developer.apple.com/support/D-U-N-S/)). Номер выдают бесплатно, около 5 рабочих дней.
- Стоимость $99 в год ([Apple Developer Program](https://developer.apple.com/programs/)). Тот же аккаунт даёт сертификат Developer ID для нотаризации версии с сайта ([SIGNING.md](SIGNING.md)).

## 2. Договор, банк и налоги

App Store Connect → **Business** (раньше Agreements, Tax, and Banking):

1. Примите **Paid Apps Agreement**.
2. Укажите банковский счёт продавца. Нужна страна, куда Apple платит, и валюта счёта.
3. Заполните налоговые формы: **W-8BEN** для физлица или W-8BEN-E для компании. Если со страной продавца есть налоговый договор с США, удержание снижается.
4. Подайте заявку в **App Store Small Business Program**, это комиссия 15% вместо 30%, пока доход меньше $1 млн в год ([Apple](https://developer.apple.com/app-store/small-business-program/)). Ставка действует со следующего месяца после одобрения, поэтому подавайте сразу.

Статус договора должен стать **Active**. Пока он не активен, `Product.products(for:)` возвращает пустой список, и экран подписки покажет бесконечную загрузку.

## 3. Приложение в App Store Connect

1. **Certificates, IDs & Profiles → Identifiers:** App ID для Lite, например `app.clearwise.lite`, с включённой capability *In-App Purchase*. Bundle ID у полной версии другой (`app.clearwise.cleaner`). Окончательные имена ещё не выбраны, см. ТЗ.
2. **App Store Connect → Apps → +:** платформа macOS, название (проверьте, что «Clearwise» свободно), основной язык Русский, SKU `clearwise-lite`.
3. **Цена приложения:** Free. Деньги идут через подписку.

## 4. Подписки

**Monetization → Subscriptions:**

1. Создайте группу подписок «Clearwise Pro». Пользователь может держать только одну подписку из группы.
2. Добавьте два продукта с id **точно как в `LicenseConfig.storeProductIDs`**:
   - `app.clearwise.lite.pro.monthly`, длительность 1 месяц;
   - `app.clearwise.lite.pro.yearly`, длительность 1 год.

   Если id поменяются, поменяйте их и в коде.
3. Для каждого продукта заполните цену (Apple сам пересчитает её по странам), локализации RU и EN (название и описание) и скриншот экрана подписки для ревью.
4. **Introductory offer → Free trial → 1 week** на оба продукта. Это и есть пробный период. Самодельный пробный период по таймеру в App Store-версии делать нельзя ([App Review Guidelines 3.1.1](https://developer.apple.com/app-store/review/guidelines/#in-app-purchase)). Экран подписки сам показывает «Сначала бесплатно», если пользователь может взять предложение.
5. **Availability:** при желании исключите страны. Россия в списке витрин всё равно недоступна для платных покупок.

## 5. Сборка для App Store

App Store принимает только архив Xcode с песочницей. Что нужно сделать в коде (подробно в ТЗ, раздел «Lite для App Store»):

- Xcode-проект или схема, которые используют пакет и задают `SWIFT_ACTIVE_COMPILATION_CONDITIONS = CLEARWISE_LITE`. Без проекта собрать с флагом можно так: `swift build -Xswiftc -DCLEARWISE_LITE` (это проверяет CI).
- Entitlements: `com.apple.security.app-sandbox`, `com.apple.security.files.user-selected.read-write`. Для StoreKit сетевое entitlement не нужно.
- Убрать из Lite модули с root, `Process` и MCP (флаг `CLEARWISE_LITE` в AppModule и Sidebar, по ТЗ).
- `PrivacyInfo.xcprivacy`. Privacy Nutrition Label: «Данные не собираются». Покупки обрабатывает Apple, Lite никуда не ходит.
- **StoreKit Configuration File** (`Clearwise.storekit`) в схеме, чтобы тестировать покупки локально без App Store Connect ([Apple: Testing in Xcode](https://developer.apple.com/documentation/xcode/setting-up-storekit-testing-in-xcode)).

## 6. Тестирование покупок

1. **Локально:** Xcode → Scheme → Run → Options → StoreKit Configuration. Покупка, отмена, продление и возврат проверяются через Debug → StoreKit → Manage Transactions.
2. **Sandbox:** App Store Connect → Users and Access → Sandbox Testers, тестовый Apple ID. На Mac: System Settings → App Store → Sandbox Account. В sandbox месячная подписка продлевается каждые 5 минут.
3. **TestFlight для macOS:** загрузите архив и раздайте тестерам.

Проверить:
- [ ] Первая покупка с бесплатной неделей открывает очистку
- [ ] «Восстановить покупки» на другом Mac с тем же Apple ID возвращает подписку
- [ ] После отмены и окончания периода очистка снова закрыта, а сканирование работает
- [ ] Возврат (refund) закрывает доступ (`revocationDate`)

## 7. Карточка и ревью

**Метаданные:**
- описание RU/EN без слов «ускоряет Mac» (правило 2.3.1), только про место на диске и порядок;
- скриншоты от 1280×800;
- URL политики конфиденциальности и поддержки (страницы на сайте уже есть);
- **Terms of Use (EULA):** ссылка на стандартный EULA Apple в описании или свой документ в поле License Agreement. Для подписок это обязательно (правило 3.1.2).

**Экран подписки** уже содержит всё, что проверяет ревью по правилу 3.1.2: название и длительность, цену из App Store, текст про автопродление, «Восстановить покупки», ссылки на условия и конфиденциальность.

**Упоминание версии с сайта.** Внутри Lite нельзя звать покупать на сайте. Ссылки на внешнюю оплату разрешены только для витрины США, и правила там меняются, поэтому перед подачей перечитайте 3.1.1 и 3.1.3 ([Guidelines](https://developer.apple.com/app-store/review/guidelines/)). Безопасный вариант: нейтральная строка в «О программе» без ссылки на оплату.

**Review Notes** (заметки для ревьюера):
> Clearwise Lite finds caches, large and duplicate files in folders the user picks. Scanning is free; cleaning requires the Clearwise Pro subscription (1-week free trial). Purchase and restore are in Settings → Subscription or appear when you press Clean. The app works only inside folders chosen through the open panel (sandbox, security-scoped bookmarks).

**Подача:** Xcode → Product → Archive → Distribute App → App Store Connect. Затем в App Store Connect выберите сборку, прикрепите обе подписки к первой версии (при первой подаче они уходят на ревью вместе с приложением) и нажмите Submit for Review. Ревью обычно занимает 1–3 дня.

## Частые причины отказа

| Причина | Что делать |
|---|---|
| 3.1.2: нет ссылки на EULA или конфиденциальность | ссылки есть на экране подписки, проверьте их в метаданных |
| 2.1: ревьюер не нашёл покупку | опишите путь в Review Notes, приложите видео |
| 2.4.5: запрос прав администратора или запуск внешних программ | Lite не должен содержать AdminShell и `Process` (флаг `CLEARWISE_LITE`) |
| 2.3.1: «ускоряет Mac», «чистит вирусы» | переписать тексты |
| Подписки не загружаются | Paid Apps Agreement не Active или продукты не в статусе Ready to Submit |
