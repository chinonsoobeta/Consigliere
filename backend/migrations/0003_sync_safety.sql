CREATE TABLE IF NOT EXISTS sync_locks (
    provider TEXT PRIMARY KEY,
    token TEXT NOT NULL,
    acquired_at TEXT NOT NULL,
    locked_until TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS sync_runs_provider_started
    ON sync_runs(provider, started_at DESC);
