CREATE TABLE IF NOT EXISTS folders (
    id                UUID PRIMARY KEY,
    owner_username    TEXT NOT NULL REFERENCES identities(username) ON DELETE CASCADE,
    name              TEXT NOT NULL,
    parent_folder_id  UUID REFERENCES folders(id) ON DELETE CASCADE,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_folders_owner_parent
    ON folders (owner_username, parent_folder_id);

CREATE TABLE IF NOT EXISTS files (
    id              UUID PRIMARY KEY,
    owner_username  TEXT NOT NULL REFERENCES identities(username) ON DELETE CASCADE,
    filename        TEXT NOT NULL,
    mime_type       TEXT NOT NULL,
    size_bytes      BIGINT NOT NULL,
    encrypted_key   TEXT NOT NULL,
    nonce           TEXT NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_files_owner
    ON files (owner_username);

CREATE TABLE IF NOT EXISTS shared_files (
    id                     UUID PRIMARY KEY,
    file_id                UUID NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    shared_with_username   TEXT NOT NULL REFERENCES identities(username) ON DELETE CASCADE,
    encrypted_key          TEXT NOT NULL,
    nonce                  TEXT NOT NULL,
    shared_by_username     TEXT NOT NULL REFERENCES identities(username) ON DELETE CASCADE,
    shared_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (file_id, shared_with_username)
);

CREATE INDEX IF NOT EXISTS idx_shared_files_recipient
    ON shared_files (shared_with_username);

CREATE TABLE IF NOT EXISTS file_folders (
    file_id    UUID NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    folder_id  UUID NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
    PRIMARY KEY (file_id, folder_id)
);

CREATE INDEX IF NOT EXISTS idx_file_folders_folder
    ON file_folders (folder_id);
