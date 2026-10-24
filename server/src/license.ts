import { createPrivateKey, createPublicKey, generateKeyPairSync, sign, verify, type KeyObject } from "node:crypto";
import type { Subscription } from "./db.js";

// License token: "CW1.<payload>.<signature>", both parts base64url. The signature is Ed25519 over "CW1.<payload>".
// The app checks it with the public key compiled into it (LicenseVerifier.swift), so it works offline until `exp`.

export interface LicensePayload {
    v: 1;
    sub: string;          // account id
    email: string;
    dev: string;          // device id the token is bound to
    plan: string;         // monthly | yearly
    status: string;       // normalised subscription status
    iat: number;          // issued at, unix seconds
    exp: number;          // the app stops trusting the token after this, unix seconds
    paidUntil: number | null;
}

const PREFIX = "CW1";

export function generateKeyPair(): { privateKey: string; publicKey: string } {
    const { privateKey, publicKey } = generateKeyPairSync("ed25519");
    const priv = privateKey.export({ format: "jwk" });
    const pub = publicKey.export({ format: "jwk" });
    return { privateKey: b64urlToB64(priv.d!), publicKey: b64urlToB64(pub.x!) };
}

export class LicenseSigner {
    private readonly privateKey: KeyObject;
    private readonly publicKey: KeyObject;

    constructor(privateKeyB64: string, publicKeyB64: string) {
        const d = b64ToB64url(privateKeyB64);
        const x = b64ToB64url(publicKeyB64);
        this.privateKey = createPrivateKey({ key: { kty: "OKP", crv: "Ed25519", d, x }, format: "jwk" });
        this.publicKey = createPublicKey({ key: { kty: "OKP", crv: "Ed25519", x }, format: "jwk" });
        // A mismatched pair would produce tokens no app accepts; fail at start-up instead.
        const probe = this.sign({ v: 1, sub: "probe", email: "", dev: "", plan: "", status: "", iat: 0, exp: 0, paidUntil: null });
        if (!this.verify(probe)) throw new Error("LICENSE_PRIVATE_KEY and LICENSE_PUBLIC_KEY are not a pair");
    }

    sign(payload: LicensePayload): string {
        const body = Buffer.from(JSON.stringify(payload)).toString("base64url");
        const signed = `${PREFIX}.${body}`;
        const signature = sign(null, Buffer.from(signed), this.privateKey).toString("base64url");
        return `${signed}.${signature}`;
    }

    /** Returns the payload when the signature is valid. Expiry is the caller's business. */
    verify(token: string): LicensePayload | null {
        const parts = token.split(".");
        if (parts.length !== 3 || parts[0] !== PREFIX) return null;
        const ok = verify(null, Buffer.from(`${parts[0]}.${parts[1]}`), this.publicKey, Buffer.from(parts[2]!, "base64url"));
        if (!ok) return null;
        try {
            return JSON.parse(Buffer.from(parts[1]!, "base64url").toString("utf8")) as LicensePayload;
        } catch {
            return null;
        }
    }
}

const DAY = 86_400_000;

/** The subscription that grants access right now, if any. Past-due and canceled ones count until their grace ends. */
export function activeSubscription(subs: Subscription[], graceDays: number, now = new Date()): Subscription | null {
    const live = subs.filter((s) => entitledUntil(s, graceDays) > now.getTime());
    live.sort((a, b) => entitledUntil(b, graceDays) - entitledUntil(a, graceDays));
    return live[0] ?? null;
}

function entitledUntil(s: Subscription, graceDays: number): number {
    const end = s.currentPeriodEnd?.getTime();
    switch (s.status) {
        case "active":
        case "trialing":
            // No period end yet (first webhook before billing details): trust the status.
            return end === undefined ? Number.MAX_SAFE_INTEGER : end + graceDays * DAY;
        case "past_due":
            return end === undefined ? 0 : end + graceDays * DAY;
        case "canceled":
        case "paused":
            // Paid time is still the customer's.
            return end ?? 0;
    }
}

export function buildPayload(
    account: { id: string; email: string },
    sub: Subscription,
    deviceId: string,
    opts: { offlineDays: number; graceDays: number },
    now = new Date(),
): LicensePayload {
    const iat = Math.floor(now.getTime() / 1000);
    let exp = iat + opts.offlineDays * 86_400;
    const until = entitledUntil(sub, opts.graceDays);
    if (until !== Number.MAX_SAFE_INTEGER) exp = Math.min(exp, Math.floor(until / 1000));
    return {
        v: 1,
        sub: account.id,
        email: account.email,
        dev: deviceId,
        plan: sub.plan,
        status: sub.status,
        iat,
        exp,
        paidUntil: sub.currentPeriodEnd ? Math.floor(sub.currentPeriodEnd.getTime() / 1000) : null,
    };
}

function b64ToB64url(s: string): string {
    return s.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function b64urlToB64(s: string): string {
    const b = s.replace(/-/g, "+").replace(/_/g, "/");
    return b + "=".repeat((4 - (b.length % 4)) % 4);
}
