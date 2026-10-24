import type { SubscriptionStatus } from "../db.js";

// The billing provider is behind this interface so Paddle can be swapped (Polar, Lemon Squeezy, YooKassa for
// buyers in Russia) without touching accounts, licenses or the app. A provider turns its webhooks into
// SubscriptionUpdate values; routes/webhooks.ts stores them.

export type Plan = "monthly" | "yearly";

export interface SubscriptionUpdate {
    providerSubscription: string;
    providerCustomer: string | null;
    /** Our account id, when the checkout carried it (custom data). */
    accountId: string | null;
    /** Fallback when there is no account id: the customer's e-mail. */
    email: string | null;
    plan: Plan;
    status: SubscriptionStatus;
    currentPeriodEnd: Date | null;
    cancelAtPeriodEnd: boolean;
    /** When the provider produced the event; older events never overwrite newer state. */
    occurredAt: Date;
}

export interface WebhookEvent {
    eventId: string;
    eventType: string;
    payload: unknown;
    /** null for events we keep but don't act on (payments, customers, …). */
    subscription: SubscriptionUpdate | null;
}

/** What the account page needs to open the provider's checkout in the browser. */
export interface CheckoutSession {
    provider: string;
    [key: string]: unknown;
}

export interface BillingProvider {
    readonly name: string;
    /** Verifies the signature and parses the event. Throws on a bad signature. */
    parseWebhook(rawBody: Buffer, headers: Record<string, string | string[] | undefined>): Promise<WebhookEvent>;
    checkout(input: { plan: Plan; accountId: string; email: string }): Promise<CheckoutSession>;
    /** A link where the customer manages the card, plan and cancellation. */
    portalUrl(providerCustomer: string): Promise<string | null>;
    /** Looks up a customer's e-mail when a webhook carries only the customer id. */
    customerEmail(providerCustomer: string): Promise<string | null>;
}
