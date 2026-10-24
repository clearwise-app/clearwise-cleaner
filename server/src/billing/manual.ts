import type { BillingProvider, CheckoutSession, WebhookEvent } from "./provider.js";

// No payment provider: subscriptions are granted by hand through /admin/grant. For local development,
// beta testers and the period before a merchant account is approved.
export class ManualProvider implements BillingProvider {
    readonly name = "manual";

    async parseWebhook(): Promise<WebhookEvent> {
        throw new Error("the manual provider has no webhooks");
    }

    async checkout(): Promise<CheckoutSession> {
        return { provider: this.name, message: "Purchases are not open yet" };
    }

    async portalUrl(): Promise<string | null> {
        return null;
    }

    async customerEmail(): Promise<string | null> {
        return null;
    }
}
