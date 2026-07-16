ALTER TABLE disclosures ADD COLUMN state TEXT;
ALTER TABLE disclosures ADD COLUMN district INTEGER;
ALTER TABLE disclosures ADD COLUMN match_confidence REAL;

CREATE INDEX IF NOT EXISTS disclosures_representative_report
    ON disclosures(representative, report_date DESC);
CREATE INDEX IF NOT EXISTS disclosures_report_date
    ON disclosures(report_date DESC);
CREATE INDEX IF NOT EXISTS disclosures_transaction_date
    ON disclosures(transaction_date DESC);

CREATE TABLE IF NOT EXISTS disclosure_backfill_jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    filing_year INTEGER NOT NULL,
    chamber TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    attempts INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    records_seen INTEGER NOT NULL DEFAULT 0,
    records_written INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    started_at TEXT,
    finished_at TEXT,
    UNIQUE(filing_year, chamber)
);

CREATE INDEX IF NOT EXISTS disclosure_backfill_status_year
    ON disclosure_backfill_jobs(status, filing_year DESC, chamber);
