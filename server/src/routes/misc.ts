import { timingSafeEqual } from "node:crypto";
import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";
import { findOrCreateAccount, normaliseEmail } from "../auth.js";
import { bearer, type Deps } from "../context.js";
import { upsertSubscription } from "../store.js";

const grantBody = z.object({
    email: z.string().email(),
    plan: z.enum(["monthly", "yearly"]).default("yearly"),
    days: z.number().int().positive().max(3650),
});

export async function miscRoutes(app: FastifyInstance, deps: Deps): Promise<void> {
    const { sql, config } = deps;

    app.get("/healthz", async () => {
        await sql`SELECT 1`;
        return { ok: true };
    });

    // The site's "Download" button points here, so the DMG location can change without touching the site.
    app.get("/download", async (_req, reply) => {
        if (!config.DOWNLOAD_URL) return reply.code(503).send({ error: "download_not_configured" });
        return reply.redirect(config.DOWNLOAD_URL, 302);
    });

    app.get("/api/version", async () => ({ version: config.LATEST_VERSION || null, downloadUrl: `${config.PUBLIC_URL}/download` }));

    app.get("/appcast.xml", async (_req, reply) => {
        if (!config.APPCAST_URL) return reply.code(404).send();
        return reply.redirect(config.APPCAST_URL, 302);
    });

    // Gives an account a subscription without payment: testers, refunds handled by hand, the manual provider.
    app.post("/admin/grant", async (req, reply) => {
        if (!(await requireAdmin(config.ADMIN_TOKEN, req, reply))) return;
        const body = grantBody.parse(req.body);
        const account = await findOrCreateAccount(sql, normaliseEmail(body.email));
        const now = new Date();
        await upsertSubscription(sql, "manual", account.id, {
            providerSubscription: `manual-${account.id}-${now.getTime()}`,
            providerCustomer: null,
            accountId: account.id,
            email: account.email,
            plan: body.plan,
            status: "active",
            currentPeriodEnd: new Date(now.getTime() + body.days * 86_400_000),
            cancelAtPeriodEnd: true,
            occurredAt: now,
        });
        return { ok: true, accountId: account.id };
    });
}

async function requireAdmin(adminToken: string, req: FastifyRequest, reply: FastifyReply): Promise<boolean> {
    const token = bearer(req);
    const ok = adminToken.length > 0 && token !== null && token.length === adminToken.length &&
        timingSafeEqual(Buffer.from(token), Buffer.from(adminToken));
    if (!ok) await reply.code(404).send();
    return ok;
}
