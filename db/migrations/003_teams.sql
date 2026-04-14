CREATE TABLE IF NOT EXISTS teams (
    id            UUID PRIMARY KEY,
    name          TEXT NOT NULL UNIQUE,
    display_name  TEXT NOT NULL,
    created_by    TEXT NOT NULL REFERENCES identities(username) ON DELETE CASCADE,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS team_members (
    id         UUID PRIMARY KEY,
    team_id    UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    username   TEXT NOT NULL REFERENCES identities(username) ON DELETE CASCADE,
    role       TEXT NOT NULL,
    joined_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (team_id, username)
);

CREATE INDEX IF NOT EXISTS idx_team_members_team
    ON team_members (team_id);

CREATE INDEX IF NOT EXISTS idx_team_members_username
    ON team_members (username);

CREATE TABLE IF NOT EXISTS team_messages (
    id                  UUID PRIMARY KEY,
    team_id             UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
    sender_username     TEXT NOT NULL REFERENCES identities(username) ON DELETE CASCADE,
    recipient_username  TEXT NOT NULL REFERENCES identities(username) ON DELETE CASCADE,
    encrypted_body      TEXT NOT NULL,
    nonce               TEXT NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_team_messages_team_created
    ON team_messages (team_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_team_messages_recipient
    ON team_messages (team_id, recipient_username, created_at DESC);
