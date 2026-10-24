import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { requireAccount, type Deps } from "../context.js";
import { activeSubscription, buildPayload } from "../license.js";
import { activateDevice, deactivateDevice, subscriptionsFor } from "../store.js";

const activateBody = z.object({
    deviceId: z.string().regex(/^[A-Za-z0-9_-]{16,128}$/),
    deviceName: z.string().max(100).default(""),
    appVersion: z.string().max(32).default(""),
});

export async function licenseRoutes(app: FastifyInstance, deps: Deps): Promise<void> {
    const { sql, config, signer } = deps;

    // The app calls this after sign-in and then about once a day. It registers the Mac (within MAX_DEVICES)
    // and returns a fresh signed token. 402: no paid subscription. 409: too many Macs, the body lists them.
    app.post("/api/license/activate", async (req, reply) => {
        const account = await requireAccount(deps, req, reply);
        if (!account) return;
        const device = activateBody.parse(req.body);

        const sub = activeSubscription(await subscriptionsFor(sql, account.id), config.LICENSE_GRACE_DAYS);
        if (!sub) return reply.code(402).send({ error: "no_subscription" });

        const result = await activateDevice(sql, account.id, device, config.MAX_DEVICES);
        if (!result.ok) {
            return reply.code(409).send({
                error: "device_limit",
                maxDevices: config.MAX_DEVICES,
                devices: result.devices.map((d) => ({ deviceId: d.deviceId, deviceName: d.deviceName, lastSeenAt: d.lastSeenAt })),
            });
        }
        const payload = buildPayload(account, sub, device.deviceId, {
            offlineDays: config.LICENSE_OFFLINE_DAYS,
            graceDays: config.LICENSE_GRACE_DAYS,
        });
        return { token: signer.sign(payload), license: payload };
    });

    // Frees a seat: "Sign out on this Mac" in the app, or the device list on the account page.
    app.delete<{ Params: { deviceId: string } }>("/api/license/devices/:deviceId", async (req, reply) => {
        const account = await requireAccount(deps, req, reply);
        if (!account) return;
        const removed = await deactivateDevice(sql, account.id, req.params.deviceId);
        return reply.code(removed ? 204 : 404).send();
    });

    app.get("/api/license/public-key", async () => ({ algorithm: "Ed25519", publicKey: config.LICENSE_PUBLIC_KEY }));
}
