# Architecture and production data boundary

The prototype deliberately separates the SwiftUI client from data acquisition. `IntelligenceProvider` is the client-facing boundary; `MockIntelligenceProvider` supplies deterministic preview data today.

For production, a backend should implement provider adapters for:

1. House and Senate periodic transaction reports, retaining source documents, amendments, transaction dates, filing dates, and retrieval timestamps.
2. A licensed Truth Social monitor with webhook or streaming delivery, retaining original URLs, edits, deletions, publication times, and measured retrieval latency.
3. Licensed U.S. and Canadian market data with explicit mobile redistribution rights, plus assessment publishers for non-exchange crude grades.

The backend should normalize these sources into the app’s `MarketInstrument` and `MarketEvent` contracts. Processing must be idempotent, replayable, and source-audited. Every response must carry freshness and provenance; the app must never silently label delayed or assessed data as live.

Portfolio features remain analytical: the client may calculate concentration and event exposure for user-selected hypothetical holdings, but neither the client nor backend should emit buy, sell, hold, suitability, target-price, or execution instructions.

