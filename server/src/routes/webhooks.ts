import type { FastifyInstance } from "fastify";
import { findOrCreateAccount, normaliseEmail } from "../auth.js";
import type { WebhookEvent } from "../billing/provider.js";
import type { Deps } from "../context.js";
import { accountForCustomer, upsertSubscription } from "../store.js";

export async function webhookRoutes(app: FastifyInstance, deps: Deps): Promise<void> {
    const { sql, billing } = deps;

    // Signatures are computed over the exact bytes, so this route keeps the body raw.
    app.addContentTypeParser("application/json", { parseAs: "buffer" }, (_req, body, done) => done(null, body));

    app.post(`/webhooks/${billing.name}`, async (req, reply) => {
        let event: WebhookEvent;
        try {
            event = await billing.parseWebhook(req.body as Buffer, req.headers);
        } catch (err) {
            req.log.warn({ err }, "rejected webhook");
            return reply.code(400).send({ error: "invalid_webhook" });
        }

        const [inserted] = await sql<{ id: string }[]>`
            INSERT INTO webhook_events (provider, event_id, event_type, payload)
            VALUES (${billing.name}, ${event.eventId}, ${event.eventType}, ${sql.json(event.payload as never)})
            ON CONFLICT (provider, event_id) DO NOTHING
            RETURNING id`;
        // Already seen: providers retry until they get a 2xx.
        if (!inserted) return reply.code(200).send({ ok: true, duplicate: true });

        try {
            await applyEvent(deps, event);
            await sql`UPDATE webhook_events SET processed_at = now() WHERE id = ${inserted.id}`;
        } catch (err) {
            req.log.error({ err, eventId: event.eventId }, "webhook processing failed");
            // Drop the row so the provider's retry is processed again.
            await sql`DELETE FROM webhook_events WHERE id = ${inserted.id}`;
            return reply.code(500).send({ error: "processing_failed" });
        }
        return { ok: true };
    });
}

export async function applyEvent(deps: Deps, event: WebhookEvent): Promise<void> {
    const update = event.subscription;
    if (!update) return;
    const { sql, billing } = deps;

    let accountId = update.accountId;
    if (accountId) {
        const [exists] = await sql`SELECT 1 FROM accounts WHERE id = ${accountId}`;
        if (!exists) accountId = null;
    }
    if (!accountId && update.providerCustomer) accountId = await accountForCustomer(sql, billing.name, update.providerCustomer);
    if (!accountId) {
        // Bought without signing in first (e.g. a checkout link from the provider's dashboard): the e-mail
        // becomes the account, and the customer signs in with it later.
        const email = update.email ?? (update.providerCustomer ? await billing.customerEmail(update.providerCustomer) : null);
        if (!email) throw new Error(`cannot match subscription ${update.providerSubscription} to an account`);
        accountId = (await findOrCreateAccount(sql, normaliseEmail(email))).id;
    }
    await upsertSubscription(sql, billing.name, accountId, update);
}
