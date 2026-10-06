-- House transactions read directly from the Clerk's PTR PDFs, one row of state per report.
-- status: running | extracted | empty | needs-review | failed | paper
CREATE TABLE IF NOT EXISTS house_ptr_extractions (
    doc_id TEXT PRIMARY KEY,
    filing_url TEXT NOT NULL,
    disclosure_date TEXT NOT NULL,
    status TEXT NOT NULL,
    parser_version INTEGER NOT NULL DEFAULT 0,
    transactions INTEGER NOT NULL DEFAULT 0,
    attempts INTEGER NOT NULL DEFAULT 0,
    warnings TEXT,
    error TEXT,
    claimed_at TEXT,
    extracted_at TEXT
);
CREATE INDEX IF NOT EXISTS house_ptr_extractions_status ON house_ptr_extractions(status, disclosure_date);

-- The report's asset-type code ("ST", "OP" for options, "GS" for government securities) and the
-- filer's description, which carries option strikes and expiries.
ALTER TABLE disclosures ADD COLUMN asset_type TEXT;
ALTER TABLE disclosures ADD COLUMN description TEXT;
-- NULL rows are served. "shadow" holds back extractor rows while they are compared with Apify;
-- "house-ptr" holds back Apify rows for reports the extractor has replaced.
ALTER TABLE disclosures ADD COLUMN suppressed_by TEXT;
CREATE INDEX IF NOT EXISTS disclosures_source_provider ON disclosures(source_url, provider);
CREATE INDEX IF NOT EXISTS disclosures_provider_suppressed ON disclosures(provider, suppressed_by);
