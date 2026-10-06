-- Rebuild politicians for server-side identity matching. The old table had a UNIQUE
-- normalized_name (two members can share a name) and no state code or district.
-- It was never populated, and disclosures.politician_id was always NULL.
PRAGMA defer_foreign_keys = true;

CREATE TABLE politicians_v2 (
    bioguide_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    normalized_name TEXT NOT NULL,
    party TEXT,
    chamber TEXT,
    state TEXT,
    state_code TEXT,
    district INTEGER,
    image_url TEXT,
    service_start INTEGER,
    updated_at TEXT NOT NULL
);
INSERT INTO politicians_v2(bioguide_id, name, normalized_name, party, chamber, state, image_url, updated_at)
SELECT bioguide_id, name, normalized_name, party, chamber, state, image_url, updated_at FROM politicians;
DROP TABLE politicians;
ALTER TABLE politicians_v2 RENAME TO politicians;
CREATE INDEX IF NOT EXISTS politicians_state_chamber ON politicians(state_code, chamber);

CREATE TABLE IF NOT EXISTS app_metadata (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS source_filings_provider_doc ON source_filings(provider, doc_id);
CREATE INDEX IF NOT EXISTS disclosures_match_queue ON disclosures(politician_id, match_confidence, id);

-- Backfill runs no longer write per-job rows into source_health.
DELETE FROM source_health WHERE provider LIKE 'apify-backfill-%';

-- Jobs exhausted by the Apify 403 outage become eligible again once access is restored.
UPDATE disclosure_backfill_jobs SET attempts = 0, status = 'pending'
WHERE status IN ('pending', 'failed');
