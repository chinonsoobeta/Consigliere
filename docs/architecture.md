# Live intelligence architecture

`IntelligenceProvider` is a live-only boundary. The production app requests a unified snapshot from the Cloudflare Worker; an absent URL, failed request, or unconfigured source produces an explicit error state. Synthetic records exist only inside tests.

The Worker owns credentials, retrieval, normalization, ranking, provenance, and source health. D1 retains official filing metadata, structured disclosures, social posts, market instruments, raw provider payloads, retrieval timestamps, and sync outcomes. Per-provider leases prevent overlapping scheduled/manual syncs, and bounded D1 batches avoid excessive serial writes.

## Source policy

Official House and Senate filings are canonical provenance. The House collector reads the official annual disclosure index and preserves PTR documents as filing records. Structured House and Senate transactions are retrieved through the configured Apify actor and must retain official Clerk or Senate eFD document links. A filing that cannot be parsed remains a filing; it is never converted into an inferred trade.

Every displayed disclosure must link to the official filing. Truth Social monitoring and market quotes require licensed publisher/display access. Twelve Data attribution is retained in the normalized market record. Physical crude assessments remain unavailable until a suitable display license is configured.

## Intelligence contract

`GET /v1/snapshot` returns:

- `instruments`: licensed quotes with source timestamps and freshness
- `intelligence`: ranked disclosure and political items
- `disclosures`: normalized transactions with official links
- `sourceHealth`: per-provider availability and last successful sync
- `coverage`: earliest/latest available normalized records by chamber

Each intelligence item includes a research-priority score, human-readable ranking reasons, a source URL, confidence, publication/retrieval timestamps, and a rules-derived “Why it matters” explanation. The latest licensed session move may be shown as broad current context; it is not labelled as a timestamp-aligned event reaction. True reaction windows remain hidden until historical intraday data is attached.

## Ranking

Disclosure ranking weights public recency (30%), financial materiality (25%), political relevance (20%), current licensed market context (15%), and source confidence (10%). Superseded and ambiguous records receive penalties. The score prioritizes research attention and must never be presented as an investment signal.

## Coverage and failure behavior

The app makes no fixed ten-year claim. Coverage is computed from available normalized records and labelled accordingly. Source outages, missing licenses, extraction failures, and empty datasets are visible to users with last-sync metadata and retry behavior; no fixture fallback is permitted.
