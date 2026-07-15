# Architecture and production data boundary

The prototype deliberately separates the SwiftUI client from data acquisition. `IntelligenceProvider` is the client-facing boundary; `MockIntelligenceProvider` supplies deterministic preview data today.

For production, a backend should implement provider adapters for:

1. House and Senate periodic transaction reports, retaining source documents, amendments, transaction dates, filing dates, and retrieval timestamps.
2. A licensed Truth Social monitor with webhook or streaming delivery, retaining original URLs, edits, deletions, publication times, and measured retrieval latency.
3. Licensed U.S. and Canadian market data with explicit mobile redistribution rights, plus assessment publishers for non-exchange crude grades.

The backend should normalize these sources into the app’s `MarketInstrument` and `MarketEvent` contracts. Processing must be idempotent, replayable, and source-audited. Every response must carry freshness and provenance; the app must never silently label delayed or assessed data as live.

The politician directory is keyed by Congress.gov Bioguide ID. Production synchronization should refresh the sitting-member roster daily and preserve service intervals. House historical downloads currently span more than ten years, while Senate public-inspection retention can be shorter; the API must therefore return an explicit per-member, per-year coverage state instead of treating a missing source as zero transactions.

Trade event studies use trading-day windows of −30, −10, −5, −1, +1, +5, +10, +30, and +90. Production calculations must use adjusted prices and compare raw, broad-market, sector, and abnormal returns. Both the transaction timestamp and public filing timestamp are retained.

Politician Model Portfolios expose two series: a reported-holdings reconstruction and a point-in-time public-information simulation that rebalances only when filings were public. Both remain hypothetical and must disclose estimated weighting, ownership, stale reports, options treatment, and unavailable source years.

Portfolio features remain analytical: the client may calculate concentration and event exposure for user-selected hypothetical holdings, but neither the client nor backend should emit buy, sell, hold, suitability, target-price, or execution instructions.
