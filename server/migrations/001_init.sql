-- Accounts, sign-in codes, app sessions, subscriptions, device activations and the webhook log.
-- One account per e-mail. A subscription comes from the billing provider's webhooks; the app never writes it.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE accounts (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email        text NOT NULL UNIQUE,              -- stored lower-cased
    locale       text NOT NULL DEFAULT 'ru',
    created_at   timestamptz NOT NULL DEFAULT now()
);

-- One-time 6-digit codes for password-less sign-in (website and app use the same flow).
CREATE TABLE login_codes (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email        text NOT NULL,
    code_hash    text NOT NULL,                     -- sha256(code + pepper)
    attempts     int  NOT NULL DEFAULT 0,
    expires_at   timestamptz NOT NULL,
    used_at      timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX login_codes_email_idx ON login_codes (email, created_at DESC);

-- Bearer sessions. Only the hash of the token is stored.
CREATE TABLE sessions (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id   uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    token_hash   text NOT NULL UNIQUE,
    kind         text NOT NULL CHECK (kind IN ('web', 'app')),
    expires_at   timestamptz NOT NULL,
    last_used_at timestamptz NOT NULL DEFAULT now(),
    created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX sessions_account_idx ON sessions (account_id);

CREATE TABLE subscriptions (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id            uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    provider              text NOT NULL,            -- 'paddle' | 'polar' | 'yookassa' | 'manual'
    provider_subscription text NOT NULL,
    provider_customer     text,
    plan                  text NOT NULL,            -- 'monthly' | 'yearly'
    -- Normalised status: trialing | active | past_due | paused | canceled
    status                text NOT NULL,
    current_period_end    timestamptz,              -- paid through
    cancel_at_period_end  boolean NOT NULL DEFAULT false,
    -- occurred_at of the webhook that last wrote the row: providers may deliver events out of order.
    provider_event_at     timestamptz,
    updated_at            timestamptz NOT NULL DEFAULT now(),
    created_at            timestamptz NOT NULL DEFAULT now(),
    UNIQUE (provider, provider_subscription)
);
CREATE INDEX subscriptions_account_idx ON subscriptions (account_id);

-- One row per Mac that holds a license. The device id is a hash the app derives from the hardware UUID.
CREATE TABLE activations (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id    uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    device_id     text NOT NULL,
    device_name   text NOT NULL DEFAULT '',
    app_version   text NOT NULL DEFAULT '',
    last_seen_at  timestamptz NOT NULL DEFAULT now(),
    created_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (account_id, device_id)
);

-- Every processed webhook is kept: duplicates are skipped by event id. A failed one is not stored, so the provider retries it.
CREATE TABLE webhook_events (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    provider      text NOT NULL,
    event_id      text NOT NULL,
    event_type    text NOT NULL,
    payload       jsonb NOT NULL,
    processed_at  timestamptz,
    received_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (provider, event_id)
);
