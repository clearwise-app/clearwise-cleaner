import { createHash, randomBytes, randomInt, timingSafeEqual } from "node:crypto";
import type { Config } from "./config.js";
import type { Account, Sql } from "./db.js";

// Password-less sign-in: a 6-digit code goes to the e-mail, the website or the app sends it back and gets a
// bearer session. Codes and session tokens are stored only as peppered SHA-256 hashes.

const MAX_CODE_ATTEMPTS = 5;

export function normaliseEmail(email: string): string {
    return email.trim().toLowerCase();
}

export function hash(value: string, pepper: string): string {
    return createHash("sha256").update(pepper).update(value).digest("hex");
}

export async function createLoginCode(sql: Sql, config: Config, email: string): Promise<string> {
    const code = randomInt(0, 1_000_000).toString().padStart(6, "0");
    const expires = new Date(Date.now() + config.LOGIN_CODE_TTL_MINUTES * 60_000);
    // A new code replaces the previous ones, so only the latest e-mail works.
    await sql`UPDATE login_codes SET used_at = now() WHERE email = ${email} AND used_at IS NULL`;
    await sql`INSERT INTO login_codes (email, code_hash, expires_at) VALUES (${email}, ${hash(code, config.AUTH_PEPPER)}, ${expires})`;
    return code;
}

/** Checks the code and, on success, returns the account (created on first sign-in). */
export async function consumeLoginCode(sql: Sql, config: Config, email: string, code: string): Promise<Account | null> {
    const [row] = await sql<{ id: string; codeHash: string; attempts: number }[]>`
        SELECT id, code_hash, attempts FROM login_codes
        WHERE email = ${email} AND used_at IS NULL AND expires_at > now()
        ORDER BY created_at DESC LIMIT 1`;
    if (!row || row.attempts >= MAX_CODE_ATTEMPTS) return null;

    const expected = Buffer.from(row.codeHash, "hex");
    const given = Buffer.from(hash(code.trim(), config.AUTH_PEPPER), "hex");
    if (!timingSafeEqual(expected, given)) {
        await sql`UPDATE login_codes SET attempts = attempts + 1 WHERE id = ${row.id}`;
        return null;
    }
    await sql`UPDATE login_codes SET used_at = now() WHERE id = ${row.id}`;
    return findOrCreateAccount(sql, email);
}

export async function findOrCreateAccount(sql: Sql, email: string, locale?: string): Promise<Account> {
    const [account] = await sql<Account[]>`
        INSERT INTO accounts (email, locale) VALUES (${email}, ${locale ?? "ru"})
        ON CONFLICT (email) DO UPDATE SET email = EXCLUDED.email
        RETURNING *`;
    return account!;
}

export async function createSession(sql: Sql, config: Config, accountId: string, kind: "web" | "app"): Promise<string> {
    const token = `cws_${randomBytes(32).toString("base64url")}`;
    const days = kind === "app" ? config.APP_SESSION_DAYS : config.WEB_SESSION_DAYS;
    const expires = new Date(Date.now() + days * 86_400_000);
    await sql`INSERT INTO sessions (account_id, token_hash, kind, expires_at)
              VALUES (${accountId}, ${hash(token, config.AUTH_PEPPER)}, ${kind}, ${expires})`;
    return token;
}

export async function accountForToken(sql: Sql, config: Config, token: string): Promise<Account | null> {
    const [account] = await sql<Account[]>`
        UPDATE sessions s SET last_used_at = now()
        FROM accounts a
        WHERE s.token_hash = ${hash(token, config.AUTH_PEPPER)} AND s.expires_at > now() AND a.id = s.account_id
        RETURNING a.*`;
    return account ?? null;
}

export async function revokeSession(sql: Sql, config: Config, token: string): Promise<void> {
    await sql`DELETE FROM sessions WHERE token_hash = ${hash(token, config.AUTH_PEPPER)}`;
}
