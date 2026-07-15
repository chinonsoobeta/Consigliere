# Architecture and production data boundary

The prototype deliberately separates the SwiftUI client from data acquisition. `IntelligenceProvider` is the client-facing boundary; `MockIntelligenceProvider` supplies deterministic preview data today. When `CONSILIERE_API_BASE_URL` is configured, `HybridIntelligenceProvider` obtains disclosures from the Consigliere backend while retaining prototype market data during development.

The `backend/` Cloudflare Worker is the Apify credential and normalization boundary. A scheduled job invokes Ryan Clinton's `congress-stock-tracker` Actor, stores normalized rows in D1, and preserves each raw Actor record. The mobile client receives only Consigliere's normalized contract; it never receives the Apify token. The client resolves Actor member names against the bundled Congress.gov roster and accepts only unique matches to stable Bioguide IDs. Failed backend requests fall back to fixtures in debug builds, while successful empty responses remain empty and are not replaced with invented records.

The initial adapter uses the Actor's full output profile and consumes only `trade` records as transactions. `filing` records—especially Senate or scanned reports without machine-readable transaction rows—are retained in `source_filings` with their extraction status and source URL. Unmapped names are excluded from politician profiles rather than guessed. The Actor's maximum 730-day lookback is suitable for forward collection and recent backfill, not the full ten-year requirement; archival coverage remains a separate ingestion concern.

For production, a backend should implement provider adapters for:

1. House and Senate periodic transaction reports, retaining source documents, amendments, transaction dates, filing dates, and retrieval timestamps.
2. A licensed Truth Social monitor with webhook or streaming delivery, retaining original URLs, edits, deletions, publication times, and measured retrieval latency.
3. Licensed U.S. and Canadian market data with explicit mobile redistribution rights, plus assessment publishers for non-exchange crude grades.

The backend should normalize these sources into the app’s `MarketInstrument` and `MarketEvent` contracts. Processing must be idempotent, replayable, and source-audited. Every response must carry freshness and provenance; the app must never silently label delayed or assessed data as live.

The politician directory is keyed by Congress.gov Bioguide ID. Production synchronization should refresh the sitting-member roster daily and preserve service intervals. House historical downloads currently span more than ten years, while Senate public-inspection retention can be shorter; the API must therefore return an explicit per-member, per-year coverage state instead of treating a missing source as zero transactions.

Trade event studies use trading-day windows of −30, −10, −5, −1, +1, +5, +10, +30, and +90. Production calculations must use adjusted prices and compare raw, broad-market, sector, and abnormal returns. Both the transaction timestamp and public filing timestamp are retained.

Politician Model Portfolios expose two series: a reported-holdings reconstruction and a point-in-time public-information simulation that rebalances only when filings were public. Both remain hypothetical and must disclose estimated weighting, ownership, stale reports, options treatment, and unavailable source years.

Portfolio features remain analytical: the client may calculate concentration and event exposure for user-selected hypothetical holdings, but neither the client nor backend should emit buy, sell, hold, suitability, target-price, or execution instructions.
