import type { Activation, Sql, Subscription } from "./db.js";
import type { SubscriptionUpdate } from "./billing/provider.js";

export async function subscriptionsFor(sql: Sql, accountId: string): Promise<Subscription[]> {
    return sql<Subscription[]>`SELECT * FROM subscriptions WHERE account_id = ${accountId} ORDER BY updated_at DESC`;
}

export async function upsertSubscription(sql: Sql, provider: string, accountId: string, u: SubscriptionUpdate): Promise<void> {
    await sql`
        INSERT INTO subscriptions (account_id, provider, provider_subscription, provider_customer, plan, status,
                                   current_period_end, cancel_at_period_end, provider_event_at)
        VALUES (${accountId}, ${provider}, ${u.providerSubscription}, ${u.providerCustomer}, ${u.plan}, ${u.status},
                ${u.currentPeriodEnd}, ${u.cancelAtPeriodEnd}, ${u.occurredAt})
        ON CONFLICT (provider, provider_subscription) DO UPDATE SET
            provider_customer    = COALESCE(EXCLUDED.provider_customer, subscriptions.provider_customer),
            plan                 = EXCLUDED.plan,
            status               = EXCLUDED.status,
            current_period_end   = COALESCE(EXCLUDED.current_period_end, subscriptions.current_period_end),
            cancel_at_period_end = EXCLUDED.cancel_at_period_end,
            provider_event_at    = EXCLUDED.provider_event_at,
            updated_at           = now()
        WHERE subscriptions.provider_event_at IS NULL OR subscriptions.provider_event_at <= EXCLUDED.provider_event_at`;
}

/** The account a provider customer already belongs to, from an earlier subscription. */
export async function accountForCustomer(sql: Sql, provider: string, customer: string): Promise<string | null> {
    const [row] = await sql<{ accountId: string }[]>`
        SELECT account_id FROM subscriptions WHERE provider = ${provider} AND provider_customer = ${customer} LIMIT 1`;
    return row?.accountId ?? null;
}

export async function activationsFor(sql: Sql, accountId: string): Promise<Activation[]> {
    return sql<Activation[]>`SELECT * FROM activations WHERE account_id = ${accountId} ORDER BY last_seen_at DESC`;
}

export type ActivateResult = { ok: true } | { ok: false; reason: "device_limit"; devices: Activation[] };

/** Registers the Mac or refreshes its last-seen time. A new Mac over the limit is refused. */
export async function activateDevice(
    sql: Sql,
    accountId: string,
    device: { deviceId: string; deviceName: string; appVersion: string },
    maxDevices: number,
): Promise<ActivateResult> {
    return sql.begin(async (tx) => {
        // Serialise activations of one account so two Macs can't both take the last seat.
        await tx`SELECT pg_advisory_xact_lock(hashtext(${accountId}))`;
        const [existing] = await tx<{ id: string }[]>`
            SELECT id FROM activations WHERE account_id = ${accountId} AND device_id = ${device.deviceId}`;
        if (existing) {
            await tx`UPDATE activations SET last_seen_at = now(), device_name = ${device.deviceName}, app_version = ${device.appVersion}
                     WHERE id = ${existing.id}`;
            return { ok: true } as const;
        }
        const devices = await tx<Activation[]>`SELECT * FROM activations WHERE account_id = ${accountId} ORDER BY last_seen_at DESC`;
        if (devices.length >= maxDevices) return { ok: false, reason: "device_limit", devices } as const;
        await tx`INSERT INTO activations (account_id, device_id, device_name, app_version)
                 VALUES (${accountId}, ${device.deviceId}, ${device.deviceName}, ${device.appVersion})`;
        return { ok: true } as const;
    });
}

export async function deactivateDevice(sql: Sql, accountId: string, deviceId: string): Promise<boolean> {
    const rows = await sql`DELETE FROM activations WHERE account_id = ${accountId} AND device_id = ${deviceId}`;
    return rows.count > 0;
}
