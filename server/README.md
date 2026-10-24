# Clearwise server

Accounts, subscriptions, licenses and downloads for the direct-download edition of Clearwise Cleaner.
Fastify + PostgreSQL, Docker Compose with Caddy. Architecture: [docs/SUBSCRIPTIONS.md](../docs/SUBSCRIPTIONS.md),
deployment: [docs/DEPLOY.md](../docs/DEPLOY.md).

## Local development

```bash
docker compose -f docker-compose.dev.yml up -d        # PostgreSQL on :5432
npm install
cp .env.example .env && npm run keys                  # paste the keys into .env
# in .env: PUBLIC_URL=http://localhost:3000, BILLING_PROVIDER=manual,
#          DATABASE_URL=postgres://clearwise:clearwise@localhost:5432/clearwise
npm run dev                                           # http://localhost:3000/account
```

Without `SMTP_URL` the sign-in code is printed to the server log.

```bash
TEST_DATABASE_URL=postgres://clearwise:clearwise@localhost:5432/clearwise_test npm test   # drops and recreates the schema
```

## API

| Method | Path | Auth | |
|---|---|---|---|
| POST | `/api/auth/request-code` | — | `{email, locale?}` → 204, e-mails a 6-digit code |
| POST | `/api/auth/verify-code` | — | `{email, code, client: "web"\|"app"}` → `{token, account}` |
| POST | `/api/auth/logout` | session | revokes the session |
| GET | `/api/me` | session | account, subscription, Macs |
| POST | `/api/billing/checkout` | session | `{plan}` → Paddle.js checkout parameters |
| POST | `/api/billing/portal` | session | → `{url}` of the Paddle customer portal |
| POST | `/api/license/activate` | session | `{deviceId, deviceName, appVersion}` → `{token}`; 402 no subscription, 409 device limit |
| DELETE | `/api/license/devices/:deviceId` | session | frees a seat |
| GET | `/api/license/public-key` | — | Ed25519 public key |
| POST | `/webhooks/paddle` | Paddle signature | subscription.* events |
| GET | `/download`, `/appcast.xml` | — | redirects to object storage |
| GET | `/api/version`, `/healthz` | — | |
| POST | `/admin/grant` | `ADMIN_TOKEN` | `{email, days, plan?}` gives a subscription without payment |
| GET | `/account` | — | account page (sign in, buy, manage, Macs) |

## Another billing provider

Implement `BillingProvider` (`src/billing/provider.ts`): verify and parse webhooks into `SubscriptionUpdate`,
describe the checkout, return the portal URL. Register it in `src/billing/index.ts` and `BILLING_PROVIDER` in
`src/config.ts`. Accounts, licenses and the app don't change.
