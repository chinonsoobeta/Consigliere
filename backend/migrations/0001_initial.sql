CREATE TABLE IF NOT EXISTS politicians (
    bioguide_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    normalized_name TEXT NOT NULL UNIQUE,
    party TEXT,
    chamber TEXT,
    state TEXT,
    image_url TEXT,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS disclosures (
    id TEXT PRIMARY KEY,
    provider TEXT NOT NULL,
    politician_id TEXT,
    representative TEXT NOT NULL,
    report_date TEXT NOT NULL,
    transaction_date TEXT NOT NULL,
    ticker TEXT NOT NULL,
    asset_name TEXT NOT NULL,
    transaction_type TEXT NOT NULL,
    owner TEXT NOT NULL,
    amount_range TEXT NOT NULL,
    chamber TEXT,
    party TEXT,
    source_url TEXT,
    raw_json TEXT NOT NULL,
    observed_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY (politician_id) REFERENCES politicians(bioguide_id)
);

CREATE INDEX IF NOT EXISTS disclosures_politician_date
    ON disclosures(politician_id, transaction_date DESC);
CREATE INDEX IF NOT EXISTS disclosures_ticker_date
    ON disclosures(ticker, transaction_date DESC);

CREATE TABLE IF NOT EXISTS source_filings (
    id TEXT PRIMARY KEY,
    provider TEXT NOT NULL,
    representative TEXT NOT NULL,
    chamber TEXT,
    disclosure_date TEXT NOT NULL,
    filing_url TEXT NOT NULL,
    doc_id TEXT,
    extraction_status TEXT,
    raw_json TEXT NOT NULL,
    observed_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS source_filings_member_date
    ON source_filings(representative, disclosure_date DESC);

CREATE TABLE IF NOT EXISTS sync_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    provider TEXT NOT NULL,
    started_at TEXT NOT NULL,
    finished_at TEXT,
    status TEXT NOT NULL,
    records_seen INTEGER NOT NULL DEFAULT 0,
    records_written INTEGER NOT NULL DEFAULT 0,
    error_message TEXT
);
