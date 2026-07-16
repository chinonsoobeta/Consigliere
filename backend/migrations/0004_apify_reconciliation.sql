DELETE FROM disclosures WHERE provider = 'fmp-reconciliation';
DELETE FROM source_health WHERE provider = 'fmp-reconciliation';

DELETE FROM disclosures
WHERE provider = 'apify' AND ranking_score = 0;

UPDATE disclosures SET chamber = LOWER(chamber)
WHERE chamber IS NOT NULL;

UPDATE source_filings SET chamber = LOWER(chamber)
WHERE chamber IS NOT NULL;
