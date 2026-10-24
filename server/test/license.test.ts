import assert from "node:assert/strict";
import { test } from "node:test";
import type { Subscription } from "../src/db.js";
import { activeSubscription, buildPayload, generateKeyPair, LicenseSigner } from "../src/license.js";

const DAY = 86_400_000;
const keys = generateKeyPair();
const signer = new LicenseSigner(keys.privateKey, keys.publicKey);

function sub(status: Subscription["status"], endInDays: number | null, extra: Partial<Subscription> = {}): Subscription {
    return {
        id: "s", accountId: "a", provider: "paddle", providerSubscription: "sub_1", providerCustomer: "ctm_1", plan: "yearly",
        status, currentPeriodEnd: endInDays === null ? null : new Date(Date.now() + endInDays * DAY), cancelAtPeriodEnd: false,
        updatedAt: new Date(), ...extra,
    };
}

test("token round-trips and rejects tampering", () => {
    const payload = buildPayload({ id: "acc", email: "a@b.c" }, sub("active", 30), "device-0123456789", { offlineDays: 14, graceDays: 7 });
    const token = signer.sign(payload);
    assert.deepEqual(signer.verify(token), payload);

    const [p, body, sig] = token.split(".");
    const forged = Buffer.from(JSON.stringify({ ...payload, exp: payload.exp + 10 * 365 * 86400 })).toString("base64url");
    assert.equal(signer.verify(`${p}.${forged}.${sig}`), null);
    assert.equal(signer.verify(`${p}.${body}`), null);
    const other = generateKeyPair();
    assert.equal(new LicenseSigner(other.privateKey, other.publicKey).verify(token), null);
});

test("mismatched key pair is refused at start-up", () => {
    const other = generateKeyPair();
    assert.throws(() => new LicenseSigner(keys.privateKey, other.publicKey));
});

test("token expiry: offline window, capped by paid time plus grace", () => {
    const opts = { offlineDays: 14, graceDays: 7 };
    const long = buildPayload({ id: "a", email: "" }, sub("active", 300), "d", opts);
    assert.equal(long.exp - long.iat, 14 * 86400);
    const ending = buildPayload({ id: "a", email: "" }, sub("canceled", 2), "d", opts);
    assert.ok(ending.exp - ending.iat <= 2 * 86400 + 1);
});

test("entitlement rules", () => {
    assert.ok(activeSubscription([sub("active", 10)], 7));
    assert.ok(activeSubscription([sub("active", null)], 7), "fresh subscription without a period yet");
    assert.ok(activeSubscription([sub("past_due", -3)], 7), "inside grace");
    assert.equal(activeSubscription([sub("past_due", -8)], 7), null, "grace over");
    assert.ok(activeSubscription([sub("canceled", 5)], 7), "paid time left");
    assert.equal(activeSubscription([sub("canceled", -1)], 7), null);
    assert.equal(activeSubscription([], 7), null);
});
