import { buildApp } from "./app.js";
import { createBillingProvider } from "./billing/index.js";
import { loadConfig } from "./config.js";
import { connect } from "./db.js";
import { LicenseSigner } from "./license.js";
import { createMailer } from "./mailer.js";
import { migrate } from "./migrate.js";

const config = loadConfig();
const sql = connect(config.DATABASE_URL);
await migrate(sql);

const deps = {
    config,
    sql,
    billing: createBillingProvider(config),
    signer: new LicenseSigner(config.LICENSE_PRIVATE_KEY, config.LICENSE_PUBLIC_KEY),
    mailer: createMailer(config, (msg) => app.log.info(msg)),
};
const app = await buildApp(deps);

for (const signal of ["SIGINT", "SIGTERM"] as const) {
    process.on(signal, async () => {
        await app.close();
        await sql.end();
        process.exit(0);
    });
}

await app.listen({ port: config.PORT, host: config.HOST });
