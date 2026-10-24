import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { consumeLoginCode, createLoginCode, createSession, normaliseEmail, revokeSession } from "../auth.js";
import { bearer, requireAccount, type Deps } from "../context.js";
import { activationsFor, subscriptionsFor } from "../store.js";
import { activeSubscription } from "../license.js";

const requestCodeBody = z.object({ email: z.string().email().max(254), locale: z.string().max(10).optional() });
const verifyCodeBody = z.object({
    email: z.string().email().max(254),
    code: z.string().regex(/^\s*\d{6}\s*$/),
    client: z.enum(["web", "app"]).default("web"),
});

export async function authRoutes(app: FastifyInstance, deps: Deps): Promise<void> {
    const { sql, config, mailer } = deps;

    app.post("/api/auth/request-code", { config: { rateLimit: { max: 5, timeWindow: "10 minutes" } } }, async (req, reply) => {
        const body = requestCodeBody.parse(req.body);
        const email = normaliseEmail(body.email);
        // One e-mail per address per minute, whoever asks.
        const [recent] = await sql`SELECT 1 FROM login_codes WHERE email = ${email} AND created_at > now() - interval '60 seconds'`;
        if (!recent) {
            const code = await createLoginCode(sql, config, email);
            await mailer.sendLoginCode(email, code, body.locale ?? "ru");
        }
        // Same answer either way, so the endpoint doesn't reveal anything about the address.
        return reply.code(204).send();
    });

    app.post("/api/auth/verify-code", { config: { rateLimit: { max: 10, timeWindow: "10 minutes" } } }, async (req, reply) => {
        const body = verifyCodeBody.parse(req.body);
        const account = await consumeLoginCode(sql, config, normaliseEmail(body.email), body.code);
        if (!account) return reply.code(400).send({ error: "invalid_code" });
        const token = await createSession(sql, config, account.id, body.client);
        return { token, account: { id: account.id, email: account.email } };
    });

    app.post("/api/auth/logout", async (req, reply) => {
        const token = bearer(req);
        if (token) await revokeSession(sql, config, token);
        return reply.code(204).send();
    });

    app.get("/api/me", async (req, reply) => {
        const account = await requireAccount(deps, req, reply);
        if (!account) return;
        const subs = await subscriptionsFor(sql, account.id);
        const active = activeSubscription(subs, config.LICENSE_GRACE_DAYS);
        const shown = active ?? subs[0] ?? null;
        const devices = await activationsFor(sql, account.id);
        return {
            account: { id: account.id, email: account.email },
            entitled: active !== null,
            subscription: shown && {
                provider: shown.provider,
                plan: shown.plan,
                status: shown.status,
                currentPeriodEnd: shown.currentPeriodEnd,
                cancelAtPeriodEnd: shown.cancelAtPeriodEnd,
            },
            devices: devices.map((d) => ({ deviceId: d.deviceId, deviceName: d.deviceName, appVersion: d.appVersion, lastSeenAt: d.lastSeenAt })),
            maxDevices: config.MAX_DEVICES,
        };
    });
}
