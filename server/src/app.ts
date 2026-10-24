import path from "node:path";
import { fileURLToPath } from "node:url";
import cors from "@fastify/cors";
import rateLimit from "@fastify/rate-limit";
import fastifyStatic from "@fastify/static";
import Fastify, { type FastifyInstance } from "fastify";
import { ZodError } from "zod";
import type { Deps } from "./context.js";
import { authRoutes } from "./routes/auth.js";
import { billingRoutes } from "./routes/billing.js";
import { licenseRoutes } from "./routes/license.js";
import { miscRoutes } from "./routes/misc.js";
import { webhookRoutes } from "./routes/webhooks.js";

const PUBLIC_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../public");

export async function buildApp(deps: Deps, opts: { logger?: boolean } = {}): Promise<FastifyInstance> {
    const app = Fastify({
        logger: opts.logger ?? true,
        // Behind Caddy: the client address comes from X-Forwarded-For (rate limits are per client).
        trustProxy: true,
        bodyLimit: 1_000_000,
    });

    const origins = deps.config.CORS_ORIGINS.split(",").map((s) => s.trim()).filter(Boolean);
    await app.register(cors, { origin: origins.length ? origins : false, methods: ["GET", "POST", "DELETE"] });
    await app.register(rateLimit, { max: 120, timeWindow: "1 minute" });

    app.setErrorHandler((err, req, reply) => {
        if (err instanceof ZodError) return reply.code(400).send({ error: "bad_request", issues: err.issues });
        const status = (err as { statusCode?: number }).statusCode ?? 500;
        if (status >= 500) req.log.error({ err }, "request failed");
        return reply.code(status).send({ error: status === 429 ? "rate_limited" : status >= 500 ? "server_error" : (err as Error).message });
    });

    // The account page: sign in, buy, manage the subscription and Macs. Served at /account.
    await app.register(fastifyStatic, { root: PUBLIC_DIR, prefix: "/", index: false });
    app.get("/account", (_req, reply) => reply.sendFile("account.html"));

    await app.register(async (scope) => authRoutes(scope, deps));
    await app.register(async (scope) => billingRoutes(scope, deps));
    await app.register(async (scope) => licenseRoutes(scope, deps));
    await app.register(async (scope) => miscRoutes(scope, deps));
    // Its own scope: the raw-body JSON parser must not leak into the other routes.
    await app.register(async (scope) => webhookRoutes(scope, deps));
    return app;
}
