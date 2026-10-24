import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { after, before, test } from "node:test";
import type { FastifyInstance } from "fastify";
import { buildApp } from "../src/app.js";
import { PaddleProvider } from "../src/billing/paddle.js";
import { loadConfig } from "../src/config.js";
import { connect, type Sql } from "../src/db.js";
import { generateKeyPair, LicenseSigner } from "../src/license.js";
import { migrate } from "../src/migrate.js";

// Integration test against a real PostgreSQL: TEST_DATABASE_URL (the schema is dropped and recreated).
const DB = process.env.TEST_DATABASE_URL ?? "postgres://clearwise:clearwise@localhost:5432/clearwise_test";
const keys = generateKeyPair();
const config = loadConfig({
    NODE_ENV: "test",
    PUBLIC_URL: "http://localhost:3000",
    DATABASE_URL: DB,
    LICENSE_PRIVATE_KEY: keys.privateKey,
    LICENSE_PUBLIC_KEY: keys.publicKey,
    AUTH_PEPPER: "test-pepper-test-pepper-test-pepper-0000",
    MAX_DEVICES: "2",
    PADDLE_WEBHOOK_SECRET: "pdl_ntfset_test",
    PADDLE_PRICE_MONTHLY: "pri_month",
    PADDLE_PRICE_YEARLY: "pri_year",
    DOWNLOAD_URL: "https://downloads.example.com/Clearwise-Cleaner-1.3.0.dmg",
    ADMIN_TOKEN: "admin-secret",
});

let sql: Sql;
let app: FastifyInstance;
const codes = new Map<string, string>();
const signer = new LicenseSigner(keys.privateKey, keys.publicKey);

before(async () => {
    sql = connect(DB);
    await sql`DROP SCHEMA public CASCADE`;
    await sql`CREATE SCHEMA public`;
    await migrate(sql, () => {});
    app = await buildApp({
        config, sql, signer,
        billing: new PaddleProvider(config),
        mailer: { async sendLoginCode(to, code) { codes.set(to, code); } },
    }, { logger: false });
});

after(async () => {
    await app.close();
    await sql.end();
});

async function signIn(email: string, client: "web" | "app" = "app"): Promise<{ token: string; accountId: string }> {
    const r1 = await app.inject({ method: "POST", url: "/api/auth/request-code", payload: { email } });
    assert.equal(r1.statusCode, 204);
    const code = codes.get(email.toLowerCase())!;
    const bad = await app.inject({ method: "POST", url: "/api/auth/verify-code", payload: { email, code: code === "000000" ? "111111" : "000000" } });
    assert.equal(bad.statusCode, 400);
    const r2 = await app.inject({ method: "POST", url: "/api/auth/verify-code", payload: { email, code, client } });
    assert.equal(r2.statusCode, 200);
    const body = r2.json();
    return { token: body.token, accountId: body.account.id };
}

function paddleWebhook(event: object, secret = config.PADDLE_WEBHOOK_SECRET) {
    const body = JSON.stringify(event);
    const ts = Math.floor(Date.now() / 1000);
    const h1 = createHmac("sha256", secret).update(`${ts}:${body}`).digest("hex");
    return app.inject({ method: "POST", url: "/webhooks/paddle", payload: body,
        headers: { "content-type": "application/json", "paddle-signature": `ts=${ts};h1=${h1}` } });
}

function subscriptionEvent(id: string, opts: { accountId?: string; status?: string; occurredAt?: string; endsAt?: string; cancel?: boolean }) {
    return {
        event_id: id,
        event_type: "subscription.updated",
        occurred_at: opts.occurredAt ?? new Date().toISOString(),
        data: {
            id: "sub_01", status: opts.status ?? "active", customer_id: "ctm_01",
            custom_data: opts.accountId ? { account_id: opts.accountId } : null,
            items: [{ price: { id: "pri_year" } }],
            current_billing_period: { starts_at: new Date().toISOString(), ends_at: opts.endsAt ?? new Date(Date.now() + 365 * 86_400_000).toISOString() },
            scheduled_change: opts.cancel ? { action: "cancel", effective_at: opts.endsAt } : null,
        },
    };
}

const device = (n: number) => ({ deviceId: `mac-device-id-000000${n}`, deviceName: `MacBook ${n}`, appVersion: "1.3.0" });

test("full purchase flow: sign in, pay, activate, device limit", async () => {
    const { token, accountId } = await signIn("Dima@Example.com");
    const auth = { authorization: `Bearer ${token}` };

    const me0 = (await app.inject({ method: "GET", url: "/api/me", headers: auth })).json();
    assert.equal(me0.entitled, false);
    assert.equal(me0.account.email, "dima@example.com");

    const noSub = await app.inject({ method: "POST", url: "/api/license/activate", headers: auth, payload: device(1) });
    assert.equal(noSub.statusCode, 402);

    const checkout = (await app.inject({ method: "POST", url: "/api/billing/checkout", headers: auth, payload: { plan: "yearly" } })).json();
    assert.deepEqual(checkout.customData, { account_id: accountId });
    assert.equal(checkout.items[0].priceId, "pri_year");

    // Bad signature is refused and changes nothing.
    assert.equal((await paddleWebhook(subscriptionEvent("evt_bad", { accountId }), "wrong")).statusCode, 400);

    const ok = await paddleWebhook(subscriptionEvent("evt_1", { accountId, occurredAt: "2026-10-24T10:00:00Z" }));
    assert.equal(ok.statusCode, 200);
    const dup = await paddleWebhook(subscriptionEvent("evt_1", { accountId }));
    assert.equal(dup.json().duplicate, true);

    const a1 = await app.inject({ method: "POST", url: "/api/license/activate", headers: auth, payload: device(1) });
    assert.equal(a1.statusCode, 200);
    const payload = signer.verify(a1.json().token)!;
    assert.equal(payload.sub, accountId);
    assert.equal(payload.dev, device(1).deviceId);
    assert.equal(payload.exp - payload.iat, 14 * 86400);

    // Refreshing the same Mac doesn't take another seat.
    assert.equal((await app.inject({ method: "POST", url: "/api/license/activate", headers: auth, payload: device(1) })).statusCode, 200);
    assert.equal((await app.inject({ method: "POST", url: "/api/license/activate", headers: auth, payload: device(2) })).statusCode, 200);
    const limit = await app.inject({ method: "POST", url: "/api/license/activate", headers: auth, payload: device(3) });
    assert.equal(limit.statusCode, 409);
    assert.equal(limit.json().devices.length, 2);

    assert.equal((await app.inject({ method: "DELETE", url: `/api/license/devices/${device(2).deviceId}`, headers: auth })).statusCode, 204);
    assert.equal((await app.inject({ method: "POST", url: "/api/license/activate", headers: auth, payload: device(3) })).statusCode, 200);

    // An older event delivered late doesn't undo a newer one.
    await paddleWebhook(subscriptionEvent("evt_2", { accountId, status: "canceled", endsAt: new Date(Date.now() - 86_400_000).toISOString(), occurredAt: "2026-10-24T12:00:00Z" }));
    await paddleWebhook(subscriptionEvent("evt_3", { accountId, status: "active", occurredAt: "2026-10-24T11:00:00Z" }));
    const me1 = (await app.inject({ method: "GET", url: "/api/me", headers: auth })).json();
    assert.equal(me1.subscription.status, "canceled");
    assert.equal(me1.entitled, false);
    assert.equal((await app.inject({ method: "POST", url: "/api/license/activate", headers: auth, payload: device(1) })).statusCode, 402);
});

test("auth: 401 without a session, logout revokes it", async () => {
    assert.equal((await app.inject({ method: "GET", url: "/api/me" })).statusCode, 401);
    const { token } = await signIn("logout@example.com", "web");
    const auth = { authorization: `Bearer ${token}` };
    assert.equal((await app.inject({ method: "GET", url: "/api/me", headers: auth })).statusCode, 200);
    await app.inject({ method: "POST", url: "/api/auth/logout", headers: auth });
    assert.equal((await app.inject({ method: "GET", url: "/api/me", headers: auth })).statusCode, 401);
});

test("admin grant and download redirect", async () => {
    assert.equal((await app.inject({ method: "POST", url: "/admin/grant", payload: { email: "t@example.com", days: 30 } })).statusCode, 404);
    const r = await app.inject({ method: "POST", url: "/admin/grant", headers: { authorization: "Bearer admin-secret" }, payload: { email: "tester@example.com", days: 30 } });
    assert.equal(r.statusCode, 200);
    const { token } = await signIn("tester@example.com");
    const a = await app.inject({ method: "POST", url: "/api/license/activate", headers: { authorization: `Bearer ${token}` }, payload: device(9) });
    assert.equal(a.statusCode, 200);

    const d = await app.inject({ method: "GET", url: "/download" });
    assert.equal(d.statusCode, 302);
    assert.equal(d.headers.location, config.DOWNLOAD_URL);
    assert.equal((await app.inject({ method: "GET", url: "/account" })).statusCode, 200);
    assert.equal((await app.inject({ method: "GET", url: "/healthz" })).statusCode, 200);
});
