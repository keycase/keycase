CREATE TABLE IF NOT EXISTS identities (
    username     TEXT PRIMARY KEY,
    public_key   TEXT NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_identities_username_prefix
    ON identities (username text_pattern_ops);

CREATE TABLE IF NOT EXISTS proofs (
    id                 TEXT PRIMARY KEY,
    identity_username  TEXT NOT NULL REFERENCES identities(username) ON DELETE CASCADE,
    type               TEXT NOT NULL,
    status             TEXT NOT NULL,
    target             TEXT NOT NULL,
    signature          TEXT NOT NULL,
    statement          TEXT,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    verified_at        TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_proofs_identity
    ON proofs (identity_username);

CREATE TABLE IF NOT EXISTS key_signatures (
    id                TEXT PRIMARY KEY,
    signer_username   TEXT NOT NULL REFERENCES identities(username) ON DELETE CASCADE,
    target_username   TEXT NOT NULL REFERENCES identities(username) ON DELETE CASCADE,
    signature         TEXT NOT NULL,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (signer_username, target_username)
);

CREATE INDEX IF NOT EXISTS idx_key_signatures_target
    ON key_signatures (target_username);
