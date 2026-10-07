-- Estimates use disclosed ranges, never current prices or actual shares.
CREATE TABLE reference_portfolios (
 id TEXT PRIMARY KEY, kind TEXT NOT NULL, members TEXT NOT NULL,
 method_version INTEGER NOT NULL, built_at TEXT NOT NULL, history_start TEXT, frozen_at TEXT,
 anchor_as_of TEXT, anchor_filed_date TEXT, anchor_source_url TEXT
);
CREATE TABLE reference_positions (
 portfolio_id TEXT NOT NULL REFERENCES reference_portfolios(id), position_key TEXT NOT NULL,
 ticker TEXT NOT NULL, asset_name TEXT NOT NULL, asset_group TEXT NOT NULL, owner TEXT NOT NULL,
 estimate REAL NOT NULL, low REAL NOT NULL, high REAL, members_holding INTEGER NOT NULL,
 first_added TEXT, last_activity TEXT NOT NULL, status TEXT NOT NULL, sector TEXT,
 PRIMARY KEY(portfolio_id, position_key)
);
CREATE TABLE reference_changes (
 id TEXT PRIMARY KEY, portfolio_id TEXT NOT NULL REFERENCES reference_portfolios(id),
 ticker TEXT NOT NULL, asset_name TEXT NOT NULL, action TEXT NOT NULL, filed_date TEXT NOT NULL,
 disclosure_id TEXT NOT NULL, source_url TEXT NOT NULL, note TEXT
);
CREATE INDEX reference_changes_portfolio_date ON reference_changes(portfolio_id, filed_date DESC);
CREATE TABLE securities (
 ticker TEXT PRIMARY KEY, name TEXT NOT NULL, cik TEXT, sic TEXT, sector TEXT, exchange TEXT,
 figi TEXT, confidence REAL NOT NULL DEFAULT 1, source_url TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE TABLE committee_assignments (
 committee_id TEXT NOT NULL, member_id TEXT NOT NULL, start_date TEXT NOT NULL, end_date TEXT,
 source_url TEXT NOT NULL, name TEXT, PRIMARY KEY(committee_id, member_id, start_date)
);
CREATE TABLE statements (
 id TEXT PRIMARY KEY, provider TEXT NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL,
 body TEXT NOT NULL, source_url TEXT NOT NULL UNIQUE, published_at TEXT NOT NULL, signed_at TEXT,
 document_number TEXT, tags TEXT NOT NULL, tier TEXT NOT NULL, priority INTEGER NOT NULL,
 raw_json TEXT NOT NULL, retrieved_at TEXT NOT NULL
);
CREATE INDEX statements_date ON statements(published_at DESC);
CREATE TABLE statement_corrections (
 id TEXT PRIMARY KEY, statement_id TEXT NOT NULL REFERENCES statements(id), tag_id TEXT NOT NULL,
 reason TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending', created_at TEXT NOT NULL
);
ALTER TABLE politicians ADD COLUMN country TEXT NOT NULL DEFAULT 'us';
ALTER TABLE politicians ADD COLUMN source_id TEXT;
ALTER TABLE politicians ADD COLUMN legislature TEXT NOT NULL DEFAULT 'Congress';
ALTER TABLE politicians ADD COLUMN region_label TEXT NOT NULL DEFAULT 'State';
ALTER TABLE politicians ADD COLUMN party_color TEXT;
ALTER TABLE politicians ADD COLUMN wikidata_id TEXT;
ALTER TABLE politicians ADD COLUMN photo_source TEXT;
ALTER TABLE politicians ADD COLUMN service_end TEXT;
CREATE TABLE interest_records (
 id TEXT PRIMARY KEY, member_id TEXT NOT NULL REFERENCES politicians(bioguide_id), country TEXT NOT NULL,
 category TEXT NOT NULL, organisation TEXT NOT NULL, exchange TEXT, ticker TEXT, figi TEXT,
 threshold_text TEXT, action TEXT NOT NULL, owner TEXT NOT NULL,
 registered_at TEXT, effective_at TEXT, published_at TEXT, ended_at TEXT,
 source_url TEXT NOT NULL, raw_json TEXT NOT NULL, parser_version INTEGER NOT NULL,
 confidence REAL NOT NULL, review_status TEXT NOT NULL DEFAULT 'unmatched'
);
CREATE INDEX interests_country_member ON interest_records(country, member_id, published_at DESC);

-- Preserve Bioguide as source_id; namespace the identifier shared by every country.
PRAGMA defer_foreign_keys = true;
UPDATE politicians SET source_id=bioguide_id WHERE country='us' AND source_id IS NULL;
UPDATE politicians SET bioguide_id='us:' || bioguide_id WHERE country='us' AND bioguide_id NOT LIKE 'us:%';
UPDATE disclosures SET politician_id='us:' || politician_id WHERE politician_id IS NOT NULL AND politician_id NOT LIKE '%:%';
DELETE FROM app_metadata WHERE key='roster_version';

ALTER TABLE interest_records ADD COLUMN match_confidence REAL NOT NULL DEFAULT 0;
ALTER TABLE interest_records ADD COLUMN candidate_matches TEXT NOT NULL DEFAULT '[]';


-- Annual assets are evidence for an optional year-end anchor, never transactions.
CREATE TABLE house_annual_reports (
 doc_id TEXT PRIMARY KEY, member_id TEXT NOT NULL REFERENCES politicians(bioguide_id),
 reporting_year INTEGER NOT NULL, filed_date TEXT NOT NULL, source_url TEXT NOT NULL,
 parser_version INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'pending',
 attempts INTEGER NOT NULL DEFAULT 0, assets TEXT NOT NULL DEFAULT '[]',
 error TEXT, retrieved_at TEXT
);
CREATE INDEX house_annual_member_year ON house_annual_reports(member_id,reporting_year DESC,filed_date DESC);
