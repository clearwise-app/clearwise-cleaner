import type { Config } from "../config.js";
import { ManualProvider } from "./manual.js";
import { PaddleProvider } from "./paddle.js";
import type { BillingProvider } from "./provider.js";

export function createBillingProvider(config: Config): BillingProvider {
    switch (config.BILLING_PROVIDER) {
        case "paddle":
            return new PaddleProvider(config);
        case "manual":
            return new ManualProvider();
    }
}
