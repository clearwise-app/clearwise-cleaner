import { createHmac, timingSafeEqual } from "node:crypto";
import type { Config } from "../config.js";
import type { SubscriptionStatus } from "../db.js";
import type { BillingProvider, CheckoutSession, Plan, WebhookEvent } from "./provider.js";

// Paddle Billing (not Paddle Classic). Paddle is the merchant of record: it charges, handles VAT and sends
// subscription.* webhooks. Docs: https://developer.paddle.com/webhooks/signature-verification
//                               https://developer.paddle.com/webhooks/subscriptions/subscription-updated

const SIGNATURE_TOLERANCE_SECONDS = 5 * 60;

interface PaddleSubscription {
    id: string;
    status: "active" | "canceled" | "past_due" | "paused" | "trialing";
    customer_id: string | null;
    custom_data: Record<string, unknown> | null;
    items: { price: { id: string } }[];
    current_billing_period: { starts_at: string; ends_at: string } | null;
    scheduled_change: { action: "cancel" | "pause" | "resume"; effective_at: string } | null;
}

export class PaddleProvider implements BillingProvider {
    readonly name = "paddle";
    private readonly apiBase: string;

    constructor(private readonly config: Config) {
        this.apiBase = config.PADDLE_ENV === "production" ? "https://api.paddle.com" : "https://sandbox-api.paddle.com";
    }

    async parseWebhook(rawBody: Buffer, headers: Record<string, string | string[] | undefined>): Promise<WebhookEvent> {
        this.verifySignature(rawBody, headerValue(headers["paddle-signature"]));
        const event = JSON.parse(rawBody.toString("utf8")) as { event_id: string; event_type: string; occurred_at: string; data: unknown };
        const isSubscription = event.event_type.startsWith("subscription.");
        return {
            eventId: event.event_id,
            eventType: event.event_type,
            payload: event,
            subscription: isSubscription ? this.toUpdate(event.data as PaddleSubscription, new Date(event.occurred_at)) : null,
        };
    }

    private verifySignature(rawBody: Buffer, header: string | undefined): void {
        if (!this.config.PADDLE_WEBHOOK_SECRET) throw new Error("PADDLE_WEBHOOK_SECRET is not set");
        if (!header) throw new Error("missing Paddle-Signature");
        // Format: ts=1671552777;h1=eb4d0dc8853be92b7f063b9f3ba5233eb920a09459b6e6b2c26705b4364db151
        const parts = Object.fromEntries(header.split(";").map((kv) => kv.split("=", 2) as [string, string]));
        const ts = parts["ts"];
        const h1 = parts["h1"];
        if (!ts || !h1) throw new Error("malformed Paddle-Signature");
        if (Math.abs(Date.now() / 1000 - Number(ts)) > SIGNATURE_TOLERANCE_SECONDS) throw new Error("stale Paddle-Signature");
        const expected = createHmac("sha256", this.config.PADDLE_WEBHOOK_SECRET).update(`${ts}:`).update(rawBody).digest();
        const given = Buffer.from(h1, "hex");
        if (given.length !== expected.length || !timingSafeEqual(given, expected)) throw new Error("bad Paddle-Signature");
    }

    private toUpdate(sub: PaddleSubscription, occurredAt: Date) {
        const priceId = sub.items[0]?.price.id;
        const plan: Plan = priceId === this.config.PADDLE_PRICE_MONTHLY ? "monthly" : "yearly";
        const accountId = typeof sub.custom_data?.["account_id"] === "string" ? (sub.custom_data["account_id"] as string) : null;
        const end = sub.current_billing_period?.ends_at ?? sub.scheduled_change?.effective_at;
        return {
            providerSubscription: sub.id,
            providerCustomer: sub.customer_id,
            accountId,
            email: null,
            plan,
            status: sub.status satisfies SubscriptionStatus,
            currentPeriodEnd: end ? new Date(end) : null,
            cancelAtPeriodEnd: sub.scheduled_change?.action === "cancel",
            occurredAt,
        };
    }

    // The account page opens Paddle.js overlay checkout with these values:
    // https://developer.paddle.com/paddlejs/methods/paddle-checkout-open
    async checkout(input: { plan: Plan; accountId: string; email: string }): Promise<CheckoutSession> {
        const priceId = input.plan === "monthly" ? this.config.PADDLE_PRICE_MONTHLY : this.config.PADDLE_PRICE_YEARLY;
        return {
            provider: this.name,
            environment: this.config.PADDLE_ENV,
            clientToken: this.config.PADDLE_CLIENT_TOKEN,
            items: [{ priceId, quantity: 1 }],
            customer: { email: input.email },
            customData: { account_id: input.accountId },
        };
    }

    async portalUrl(providerCustomer: string): Promise<string | null> {
        const res = await this.api(`/customers/${encodeURIComponent(providerCustomer)}/portal-sessions`, { method: "POST", body: "{}" });
        const body = (await res.json()) as { data?: { urls?: { general?: { overview?: string } } } };
        return body.data?.urls?.general?.overview ?? null;
    }

    async customerEmail(providerCustomer: string): Promise<string | null> {
        const res = await this.api(`/customers/${encodeURIComponent(providerCustomer)}`);
        const body = (await res.json()) as { data?: { email?: string } };
        return body.data?.email ?? null;
    }

    private async api(path: string, init: RequestInit = {}): Promise<Response> {
        const res = await fetch(this.apiBase + path, {
            ...init,
            headers: { Authorization: `Bearer ${this.config.PADDLE_API_KEY}`, "Content-Type": "application/json" },
        });
        if (!res.ok) throw new Error(`Paddle ${path}: HTTP ${res.status} ${await res.text()}`);
        return res;
    }
}

function headerValue(v: string | string[] | undefined): string | undefined {
    return Array.isArray(v) ? v[0] : v;
}
