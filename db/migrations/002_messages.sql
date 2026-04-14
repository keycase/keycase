CREATE TABLE IF NOT EXISTS messages (
    id                  UUID PRIMARY KEY,
    sender_username     TEXT NOT NULL REFERENCES identities(username) ON DELETE CASCADE,
    recipient_username  TEXT NOT NULL REFERENCES identities(username) ON DELETE CASCADE,
    encrypted_body      TEXT NOT NULL,
    nonce               TEXT NOT NULL,
    sender_public_key   TEXT NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    read_at             TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_messages_recipient_created
    ON messages (recipient_username, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_messages_sender_created
    ON messages (sender_username, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_messages_recipient_unread
    ON messages (recipient_username, created_at DESC)
    WHERE read_at IS NULL;
