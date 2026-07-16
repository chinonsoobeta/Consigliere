ALTER TABLE disclosures ADD COLUMN confidence REAL NOT NULL DEFAULT 0.9;
ALTER TABLE disclosures ADD COLUMN ranking_score REAL NOT NULL DEFAULT 0;
ALTER TABLE disclosures ADD COLUMN ranking_reasons TEXT NOT NULL DEFAULT '[]';
ALTER TABLE disclosures ADD COLUMN why_it_matters TEXT;

CREATE TABLE IF NOT EXISTS social_posts (
    id TEXT PRIMARY KEY,
    provider TEXT NOT NULL,
    author TEXT NOT NULL,
    body TEXT NOT NULL,
    source_url TEXT NOT NULL,
    published_at TEXT NOT NULL,
    retrieved_at TEXT NOT NULL,
    edited_at TEXT,
    deleted_at TEXT,
    policy_topics TEXT NOT NULL DEFAULT '[]',
    mentioned_symbols TEXT NOT NULL DEFAULT '[]',
    confidence REAL NOT NULL DEFAULT 0.8,
    ranking_score REAL NOT NULL DEFAULT 0,
    ranking_reasons TEXT NOT NULL DEFAULT '[]',
    why_it_matters TEXT,
    raw_json TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS market_instruments (
    symbol TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    exchange_name TEXT NOT NULL,
    currency TEXT NOT NULL,
    region TEXT NOT NULL,
    instrument_kind TEXT NOT NULL,
    price REAL NOT NULL,
    change_percent REAL NOT NULL,
    updated_at TEXT NOT NULL,
    sector TEXT,
    provider TEXT NOT NULL,
    attribution TEXT NOT NULL,
    raw_json TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS source_health (
    provider TEXT PRIMARY KEY,
    display_name TEXT NOT NULL,
    status TEXT NOT NULL,
    last_attempt_at TEXT,
    last_success_at TEXT,
    records_seen INTEGER NOT NULL DEFAULT 0,
    message TEXT,
    coverage_start TEXT,
    coverage_end TEXT
);

CREATE INDEX IF NOT EXISTS disclosures_ranking
    ON disclosures(ranking_score DESC, report_date DESC);
CREATE INDEX IF NOT EXISTS social_posts_ranking
    ON social_posts(ranking_score DESC, published_at DESC);
