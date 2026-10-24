import { z } from "zod";

// Every setting comes from the environment (see .env.example). The server refuses to start on a bad value
// instead of failing on the first request that needs it.
const schema = z.object({
    NODE_ENV: z.enum(["development", "production", "test"]).default("development"),
    PORT: z.coerce.number().int().default(3000),
    HOST: z.string().default("0.0.0.0"),
    // Public origin of this server, e.g. https://api.clearwise.app. Used in e-mails and checkout return URLs.
    PUBLIC_URL: z.string().url(),
    // Origins allowed to call the API from a browser (the marketing site), comma-separated.
    CORS_ORIGINS: z.string().default(""),

    DATABASE_URL: z.string().min(1),

    // Ed25519 key pair for license tokens, base64 of the raw 32-byte keys (npm run keys).
    // The public key is also compiled into the app (LicenseConfig.swift).
    LICENSE_PRIVATE_KEY: z.string().min(40),
    LICENSE_PUBLIC_KEY: z.string().min(40),
    // How long a token stays valid without the server: the app works offline this long.
    LICENSE_OFFLINE_DAYS: z.coerce.number().int().positive().default(14),
    // Grace period after a failed renewal (past_due) before the license stops.
    LICENSE_GRACE_DAYS: z.coerce.number().int().nonnegative().default(7),
    MAX_DEVICES: z.coerce.number().int().positive().default(3),

    // Random secret mixed into hashes of sign-in codes and session tokens.
    AUTH_PEPPER: z.string().min(32),
    LOGIN_CODE_TTL_MINUTES: z.coerce.number().int().positive().default(15),
    APP_SESSION_DAYS: z.coerce.number().int().positive().default(365),
    WEB_SESSION_DAYS: z.coerce.number().int().positive().default(30),

    // SMTP for sign-in codes, e.g. smtps://user:pass@smtp.provider.com:465. Empty: codes are printed to the log.
    SMTP_URL: z.string().default(""),
    MAIL_FROM: z.string().default("Clearwise <no-reply@example.com>"),

    BILLING_PROVIDER: z.enum(["paddle", "manual"]).default("paddle"),
    PADDLE_ENV: z.enum(["sandbox", "production"]).default("sandbox"),
    PADDLE_API_KEY: z.string().default(""),
    PADDLE_WEBHOOK_SECRET: z.string().default(""),
    // Client-side token for Paddle.js on the account page (Paddle > Developer tools > Authentication).
    PADDLE_CLIENT_TOKEN: z.string().default(""),
    PADDLE_PRICE_MONTHLY: z.string().default(""),
    PADDLE_PRICE_YEARLY: z.string().default(""),

    // Where /download sends the browser: a public object-storage URL of the latest notarized DMG.
    DOWNLOAD_URL: z.string().default(""),
    LATEST_VERSION: z.string().default(""),
    // Sparkle appcast URL, served as /appcast.xml redirect when set.
    APPCAST_URL: z.string().default(""),

    // Bearer token for /admin endpoints (manual grants, webhook replay). Empty disables them.
    ADMIN_TOKEN: z.string().default(""),
});

export type Config = z.infer<typeof schema>;

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
    const parsed = schema.safeParse(env);
    if (!parsed.success) {
        const lines = parsed.error.issues.map((i) => `  ${i.path.join(".")}: ${i.message}`);
        throw new Error(`Invalid configuration:\n${lines.join("\n")}`);
    }
    const config = parsed.data;
    if (config.NODE_ENV === "production" && config.BILLING_PROVIDER === "paddle") {
        for (const key of ["PADDLE_API_KEY", "PADDLE_WEBHOOK_SECRET", "PADDLE_CLIENT_TOKEN", "PADDLE_PRICE_MONTHLY", "PADDLE_PRICE_YEARLY"] as const) {
            if (!config[key]) throw new Error(`Invalid configuration:\n  ${key}: required in production with Paddle`);
        }
    }
    return config;
}
