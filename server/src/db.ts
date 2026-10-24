import postgres from "postgres";

export type Sql = postgres.Sql;

export function connect(url: string): Sql {
    return postgres(url, {
        max: 10,
        // Columns come back camelCased, so rows match the TypeScript types below.
        transform: postgres.camel,
        onnotice: () => {},
    });
}

export interface Account {
    id: string;
    email: string;
    locale: string;
    createdAt: Date;
}

export type SubscriptionStatus = "trialing" | "active" | "past_due" | "paused" | "canceled";

export interface Subscription {
    id: string;
    accountId: string;
    provider: string;
    providerSubscription: string;
    providerCustomer: string | null;
    plan: string;
    status: SubscriptionStatus;
    currentPeriodEnd: Date | null;
    cancelAtPeriodEnd: boolean;
    updatedAt: Date;
}

export interface Activation {
    id: string;
    accountId: string;
    deviceId: string;
    deviceName: string;
    appVersion: string;
    lastSeenAt: Date;
}
