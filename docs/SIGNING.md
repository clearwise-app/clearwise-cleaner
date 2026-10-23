# Подпись Developer ID и нотаризация

Как выпустить DMG, который macOS открывает без предупреждения «не удаётся проверить разработчика»: приложение и образ подписаны сертификатом **Developer ID Application**, образ прошёл нотаризацию Apple, а квитанция (ticket) прикреплена к нему через `stapler`.

Всё делает `scripts/package_release.sh`, если передать ему `SIGN_IDENTITY`. Без этой переменной релиз, как и раньше, собирается с подписью ad-hoc.

## Что нужно один раз

### 1. Apple Developer Program

Платная подписка ($99 в год) на аккаунт, который будет издателем. Сертификат Developer ID может создать только **Account Holder** (владелец аккаунта), не участник команды.

Запишите **Team ID**: [developer.apple.com/account](https://developer.apple.com/account) → Membership details. Это 10 символов вроде `AB12CD34EF`.

### 2. Сертификат Developer ID Application в связке ключей

Проще всего через Xcode: **Xcode → Settings → Accounts →** ваш Apple ID **→ Manage Certificates… → + → Developer ID Application**. Сертификат и закрытый ключ сразу окажутся в связке ключей «Вход».

Проверка:

```bash
security find-identity -v -p codesigning
# 1) 3F2A…C9 "Developer ID Application: Dmitrii Bondarenko (AB12CD34EF)"
```

Строка в кавычках (или 40-символьный SHA-1 перед ней) и есть `SIGN_IDENTITY`.

Сразу сделайте резервную копию: **Связка ключей → Мои сертификаты →** правый щелчок по сертификату **→ Экспортировать… → .p12** с паролем. Храните её в менеджере паролей, не в репозитории (`*.p12` уже в `.gitignore`). Без закрытого ключа подписать новую версию тем же сертификатом нельзя, а новый сертификат даёт новую подпись.

### 3. Учётные данные для нотаризации — в связку ключей, не в репозиторий

`notarytool` хранит их в связке ключей под именем профиля. Скрипт по умолчанию ищет профиль `clearwise-notary` (другое имя: `NOTARY_PROFILE=…`). Нужен один из двух вариантов.

**Вариант А: Apple ID и пароль приложения** (быстрее для одного человека).

1. [account.apple.com](https://account.apple.com) → Вход и безопасность → **Пароли приложений** → создайте пароль, например «clearwise notary».
2. Сохраните профиль. Пароль не пишите в команду: `notarytool` сам спросит его и не оставит в истории терминала.

```bash
xcrun notarytool store-credentials clearwise-notary \
    --apple-id "ваш-apple-id@example.com" \
    --team-id AB12CD34EF
# Password for ваш-apple-id@example.com: <пароль приложения>
```

**Вариант Б: ключ App Store Connect API** (удобнее для CI и не привязан к личному паролю).

1. [App Store Connect → Users and Access → Integrations → Team Keys](https://appstoreconnect.apple.com/access/integrations/api) → создайте ключ с ролью **Developer**, скачайте `AuthKey_XXXXXXXXXX.p8` (скачать можно только один раз), запишите **Key ID** и **Issuer ID**.
2. Положите `.p8` вне репозитория, например в `~/.appstoreconnect/private_keys/` (`*.p8` тоже в `.gitignore`).

```bash
xcrun notarytool store-credentials clearwise-notary \
    --key ~/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8 \
    --key-id XXXXXXXXXX \
    --issuer 00000000-0000-0000-0000-000000000000
```

Проверка, что профиль работает:

```bash
xcrun notarytool history --keychain-profile clearwise-notary
```

## Выпуск релиза

```bash
SIGN_IDENTITY="Developer ID Application: Dmitrii Bondarenko (AB12CD34EF)" \
VERSION=1.3.0 scripts/package_release.sh
```

Скрипт по порядку:

1. Проверяет, что сертификат есть в связке ключей и профиль `notarytool` входит, — до долгой универсальной сборки.
2. Собирает приложение (`build_app.sh`): Hardened Runtime, защищённая метка времени, сначала вложенный `clearwise-mcp`, потом бандл.
3. Проверяет, что в бандле нет пути к домашней папке и имени пользователя и что подпись именно Developer ID, а не Apple Development (в той записан Apple ID).
4. Собирает DMG и подписывает его тем же сертификатом.
5. Отправляет DMG в нотаризацию и ждёт ответа (обычно несколько минут). Ответ сохраняется в `build/notarytool-<версия>.json`; при отказе печатается подробный журнал Apple.
6. Прикрепляет квитанцию к DMG (`stapler staple`) и проверяет её (`stapler validate`).
7. Проверяет, что скажет Gatekeeper о скачанном образе и о приложении внутри него (`spctl --assess`).
8. Пишет `.sha256`.

`NOTARIZE=0` пропускает шаги 5–7: так можно сначала проверить одну подпись, не тратя попытку нотаризации.

Ручная проверка готового файла:

```bash
spctl -a -t open --context context:primary-signature -vv build/Clearwise-Cleaner-1.3.0.dmg
# … accepted, source=Notarized Developer ID
xcrun stapler validate build/Clearwise-Cleaner-1.3.0.dmg
```

## Что стоит знать

- **Квитанция прикреплена к DMG, а не к .app.** Пока пользователь открывает образ, Gatekeeper видит её даже без интернета. Приложение, скопированное в «Программы», проверяется по той же квитанции онлайн; это стандартная схема для DMG. Если понадобится раздавать .app отдельно (zip, обновления), его нужно нотаризовать и «степлить» отдельно.
- **Полный доступ к диску придётся выдать заново один раз.** macOS привязывает разрешение к подписи. Версии до 1.3 подписаны ad-hoc, поэтому после перехода на Developer ID пользователи увидят запрос снова. Дальше подпись постоянна, и разрешение переживает обновления. Об этом стоит написать в заметках к релизу.
- **Bundle ID.** В коде `app.clearwise.cleaner`, в ТЗ `com.bondarenko.maccleaner`. Для Developer ID регистрировать идентификатор не нужно, но после первого подписанного релиза менять его не стоит: для macOS это будет другое приложение (свои настройки, свой Полный доступ к диску).
- **Срок сертификата** — 5 лет. Уже нотаризованные и выпущенные файлы продолжают открываться и после его окончания, а для новых релизов понадобится новый сертификат.

## Источники

- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) — Apple
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow) — `notarytool`, `stapler`, профили в связке ключей
- [Resolving common notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues) — Hardened Runtime, метка времени
- [Developer ID](https://developer.apple.com/developer-id/) и [Create Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/) — только Account Holder
- [Sign in to apps with your Apple Account using app-specific passwords](https://support.apple.com/102654)
