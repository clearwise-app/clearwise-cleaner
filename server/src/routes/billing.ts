import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { requireAccount, type Deps } from "../context.js";
import { subscriptionsFor } from "../store.js";

const checkoutBody = z.object({ plan: z.enum(["monthly", "yearly"]) });

export async function billingRoutes(app: FastifyInstance, deps: Deps): Promise<void> {
    const { sql, billing } = deps;

    app.post("/api/billing/checkout", async (req, reply) => {
        const account = await requireAccount(deps, req, reply);
        if (!account) return;
        const { plan } = checkoutBody.parse(req.body);
        return billing.checkout({ plan, accountId: account.id, email: account.email });
    });

    app.post("/api/billing/portal", async (req, reply) => {
        const account = await requireAccount(deps, req, reply);
        if (!account) return;
        const sub = (await subscriptionsFor(sql, account.id)).find((s) => s.provider === billing.name && s.providerCustomer);
        if (!sub?.providerCustomer) return reply.code(404).send({ error: "no_customer" });
        const url = await billing.portalUrl(sub.providerCustomer);
        if (!url) return reply.code(404).send({ error: "no_portal" });
        return { url };
    });
}
