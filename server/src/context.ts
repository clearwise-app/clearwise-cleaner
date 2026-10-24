import type { FastifyReply, FastifyRequest } from "fastify";
import { accountForToken } from "./auth.js";
import type { BillingProvider } from "./billing/provider.js";
import type { Config } from "./config.js";
import type { Account, Sql } from "./db.js";
import { LicenseSigner } from "./license.js";
import type { Mailer } from "./mailer.js";

/** Everything a route needs, passed explicitly so tests can build the server with fakes. */
export interface Deps {
    config: Config;
    sql: Sql;
    billing: BillingProvider;
    mailer: Mailer;
    signer: LicenseSigner;
}

export function bearer(req: FastifyRequest): string | null {
    const header = req.headers.authorization;
    if (!header?.startsWith("Bearer ")) return null;
    return header.slice(7).trim() || null;
}

/** Resolves the signed-in account or answers 401 and returns null. */
export async function requireAccount(deps: Deps, req: FastifyRequest, reply: FastifyReply): Promise<Account | null> {
    const token = bearer(req);
    const account = token ? await accountForToken(deps.sql, deps.config, token) : null;
    if (!account) {
        await reply.code(401).send({ error: "unauthorized" });
        return null;
    }
    return account;
}
