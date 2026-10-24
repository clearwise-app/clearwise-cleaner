# Развёртывание: домен, сервер, платежи, загрузки

Итоговая схема:

```
clearwise.app             → GitHub Pages (репозиторий clearwise-app.github.io), лендинг
api.clearwise.app         → VPS: Caddy (HTTPS) → API (server/) → PostgreSQL
downloads.clearwise.app   → объектное хранилище (Cloudflare R2 / Backblaze B2): DMG и appcast.xml
```

`clearwise.app` здесь только пример, домен ещё не выбран. Время: около 2 часов, если аккаунты уже есть.

## 1. Домен

1. Выберите имя и проверьте, что оно свободно, а торговая марка не занята: поиск по [WIPO Brand Database](https://branddb.wipo.int).
2. Регистратор. Namecheap с 2022 года не обслуживает клиентов из России ([TechRadar](https://www.techradar.com/news/namecheap-scraps-domain-services-for-customers-in-russia-following-ukraine-invasion)). Подходят:
   - **Cloudflare Registrar** продаёт домены по себестоимости, а DNS и R2 будут в том же кабинете. Нужна иностранная карта.
   - **REG.RU / RU-CENTER** принимают российские карты и продают .app, .com и .ru. Подходят, если сервер и юрлицо в РФ.
3. Зона `.app` всегда работает только по HTTPS (HSTS preload). Caddy и GitHub Pages выдают сертификаты сами, так что это не мешает.
4. DNS-записи:

| Имя | Тип | Значение |
|---|---|---|
| `@` | A | 185.199.108.153, .109.153, .110.153, .111.153 (GitHub Pages, [docs](https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/managing-a-custom-domain-for-your-github-pages-site)) |
| `www` | CNAME | `clearwise-app.github.io` |
| `api` | A | IP вашего VPS |
| `downloads` | CNAME | адрес бакета R2/B2 (custom domain) |

5. Свой домен для сайта: в репозитории `clearwise-app.github.io` откройте Settings → Pages → Custom domain, впишите домен и включите Enforce HTTPS. В корне репозитория появится файл `CNAME`.

## 2. Почта

Коды входа уходят по SMTP, а на адрес поддержки (SUPPORT_EMAIL на сайте) пишут пользователи.

- **Отправка:** [Resend](https://resend.com), [Postmark](https://postmarkapp.com) или Amazon SES. Добавьте в DNS записи SPF и DKIM, которые выдаст сервис, затем впишите в `.env` строку `SMTP_URL=smtps://USER:PASS@smtp.host:465` и `MAIL_FROM=Clearwise <no-reply@clearwise.app>`.
- **Входящие:** Cloudflare Email Routing (бесплатно переадресует support@ на ваш ящик), Яндекс 360 или Zoho Mail.

## 3. Сервер

**Требования:** 1 vCPU, 1–2 ГБ RAM, 20 ГБ SSD, Ubuntu 24.04. Этого хватит на десятки тысяч пользователей, потому что приложение обращается к серверу примерно раз в сутки.

**Где взять.** Hetzner в конце 2023 года прекратил обслуживать клиентов из России ([Habr](https://habr.com/ru/news/779360/)). Варианты:

- зарубежный продавец: DigitalOcean, Vultr, Hetzner с картой и документами страны продавца;
- данные покупателей из РФ или продавец в РФ: Selectel, Timeweb Cloud, Yandex Cloud (см. раздел про 152-ФЗ в [SUBSCRIPTIONS.md](SUBSCRIPTIONS.md)).

**Установка** (под root на свежем сервере):

```bash
# Docker
curl -fsSL https://get.docker.com | sh

# Брандмауэр: снаружи открыты только SSH и веб
ufw allow OpenSSH && ufw allow 80 && ufw allow 443 && ufw --force enable

# Код. Репозиторий приватный, поэтому нужен deploy key (только чтение):
# ssh-keygen -t ed25519 -f ~/.ssh/clearwise_deploy, затем GitHub → репо → Settings → Deploy keys
git clone git@github.com:clearwise-app/clearwise-cleaner.git /opt/clearwise
cd /opt/clearwise/server
cp .env.example .env
```

**Ключи.** Заполните в `.env` `API_DOMAIN`, `PUBLIC_URL` и `POSTGRES_PASSWORD` (`openssl rand -base64 32`), затем сгенерируйте ключи:

```bash
docker compose build api
docker compose run --rm --no-deps api node dist/keys.js
# → LICENSE_PRIVATE_KEY, LICENSE_PUBLIC_KEY, AUTH_PEPPER, ADMIN_TOKEN: вставьте в .env
```

`LICENSE_PUBLIC_KEY` скопируйте в `Sources/MacCleaner/Licensing/LicenseConfig.swift` (`publicKey`). Закрытый ключ существует только в `.env` на сервере, сделайте его копию в менеджере паролей. Если ключ потерять или сменить, все выданные лицензии перестанут проверяться, пока приложения не обновят токен. Старые сборки приложения со старым открытым ключом перестанут работать совсем.

**Запуск:**

```bash
docker compose up -d --build
docker compose logs -f api            # "Server listening", миграции применились
curl https://api.clearwise.app/healthz  # {"ok":true}
```

**Обновление:** `git pull && docker compose up -d --build`. Миграции БД применяются при старте.

**Бэкапы БД** раз в сутки в 03:00, хранятся 14 дней:

```bash
mkdir -p /opt/backups
cat >/etc/cron.d/clearwise-backup <<'EOF'
0 3 * * * root cd /opt/clearwise/server && docker compose exec -T db pg_dump -U clearwise clearwise | gzip > /opt/backups/clearwise-$(date +\%F).sql.gz && find /opt/backups -name '*.sql.gz' -mtime +14 -delete
EOF
```

Копируйте `/opt/backups` за пределы сервера, например `rclone` в тот же R2.

## 4. Paddle

1. Зарегистрируйтесь на [paddle.com](https://www.paddle.com) от лица продавца (юрлицо или ИП вне РФ, см. [SUBSCRIPTIONS.md](SUBSCRIPTIONS.md)). Сначала работайте в **sandbox**: [sandbox-vendors.paddle.com](https://sandbox-vendors.paddle.com).
2. **Catalog → Products:** продукт «Clearwise Cleaner» и две цены, recurring monthly и yearly. Цены `pri_…` впишите в `PADDLE_PRICE_MONTHLY` и `PADDLE_PRICE_YEARLY`.
3. **Developer tools → Authentication:** API key пойдёт в `PADDLE_API_KEY`, client-side token в `PADDLE_CLIENT_TOKEN`.
4. **Developer tools → Notifications:** новое назначение `https://api.clearwise.app/webhooks/paddle` с событиями `subscription.*`. Secret key впишите в `PADDLE_WEBHOOK_SECRET`.
5. **Checkout settings:** default payment link `https://api.clearwise.app/account`, approved domain `api.clearwise.app`.
6. Для одобрения аккаунта Paddle проверяет сайт: нужны цены, условия (Terms), политика возврата (Refund) и конфиденциальности, контакты ([Paddle: domain approval](https://www.paddle.com/help/start/account-verification/what-is-domain-approval)).
7. Проверьте покупку в sandbox тестовой картой `4242 4242 4242 4242` ([Paddle: sandbox](https://www.paddle.com/blog/sandbox)). На `/account` должна появиться активная подписка, а приложение после «Проверить подписку» должно её подхватить.
8. Боевой режим: `PADDLE_ENV=production`, ключи и цены из боевого кабинета, `docker compose up -d`.

Без Paddle можно запуститься с `BILLING_PROVIDER=manual`. Тогда подписки выдаются вручную:

```bash
curl -X POST https://api.clearwise.app/admin/grant -H "Authorization: Bearer $ADMIN_TOKEN" \
     -H 'Content-Type: application/json' -d '{"email":"tester@example.com","days":90}'
```

## 5. Загрузка DMG

Репозиторий приложения теперь приватный, и ссылки на GitHub Releases с сайта перестанут работать. DMG кладём в объектное хранилище:

1. Создайте бакет в Cloudflare R2 (10 ГБ и исходящий трафик бесплатно, [цены](https://developers.cloudflare.com/r2/pricing/)) и привяжите домен `downloads.clearwise.app`.
2. При релизе загружайте нотаризованный `Clearwise-Cleaner-X.Y.Z.dmg`, `.sha256`, а позже и `appcast.xml` для Sparkle.
3. В `.env` укажите `DOWNLOAD_URL=https://downloads.clearwise.app/Clearwise-Cleaner-X.Y.Z.dmg`, `LATEST_VERSION=X.Y.Z` и `APPCAST_URL=https://downloads.clearwise.app/appcast.xml`, затем выполните `docker compose up -d`.
4. На сайте все кнопки «Скачать» ведут на `https://api.clearwise.app/download`. При релизе сайт больше не нужно править.

## 6. Сайт (clearwise-app.github.io)

- Кнопки «Скачать» → `https://api.clearwise.app/download`.
- В шапку добавить ссылку «Аккаунт» → `https://api.clearwise.app/account`.
- Блок с ценами (месяц и год, пробная неделя) вместо «Бесплатно».
- Страницы `terms.html` и `refund.html`. Дополнить `privacy.html`: сервер хранит почту, анонимный идентификатор Mac и статус подписки, а оплату обрабатывает Paddle.
- `CORS_ORIGINS` в `.env` должен содержать домен сайта.

## Чек-лист запуска

- [ ] Домен куплен, DNS настроен, сайт открывается по HTTPS
- [ ] VPS поднят, `https://api.…/healthz` отвечает `{"ok":true}`
- [ ] SMTP настроен, код входа приходит на почту
- [ ] Открытый ключ лицензии вписан в `LicenseConfig.swift`, `apiBase` указывает на домен
- [ ] Sandbox-покупка проходит до конца: оплата → вебхук → `/account` → приложение
- [ ] Бэкап БД настроен и проверен восстановлением (`gunzip -c … | docker compose exec -T db psql -U clearwise clearwise`)
- [ ] DMG лежит в хранилище, `/download` отдаёт его
- [ ] Paddle переведён в production
