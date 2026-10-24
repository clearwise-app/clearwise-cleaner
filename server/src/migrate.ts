import { readdir, readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";
import type { Sql } from "./db.js";

// Plain SQL migrations from ../migrations, applied in file-name order, each once, each in a transaction.
const MIGRATIONS_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../migrations");

export async function migrate(sql: Sql, log: (msg: string) => void = console.log): Promise<void> {
    await sql`CREATE TABLE IF NOT EXISTS schema_migrations (name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())`;
    const applied = new Set((await sql<{ name: string }[]>`SELECT name FROM schema_migrations`).map((r) => r.name));
    const files = (await readdir(MIGRATIONS_DIR)).filter((f) => f.endsWith(".sql")).sort();
    for (const file of files) {
        if (applied.has(file)) continue;
        const body = await readFile(path.join(MIGRATIONS_DIR, file), "utf8");
        await sql.begin(async (tx) => {
            await tx.unsafe(body);
            await tx`INSERT INTO schema_migrations (name) VALUES (${file})`;
        });
        log(`migrated ${file}`);
    }
}

// `npm run migrate` / `node dist/migrate.js`
if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
    const { loadConfig } = await import("./config.js");
    const { connect } = await import("./db.js");
    const sql = connect(loadConfig().DATABASE_URL);
    try {
        await migrate(sql);
    } finally {
        await sql.end();
    }
}
