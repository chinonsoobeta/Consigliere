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
- `politicianSummaries`: stored record count and date range per bioguide ID (all history, not just the snapshot window)
- `unmatchedFilers`: filer names that could not be attributed to a sitting member, usually former members
- `pendingFilings`: official House PTRs from the last 45 days whose transactions have not been extracted yet

Disclosure items carry `politicianID` and `timePrecision: "date"`; filings have calendar dates only, so clients display them as UTC days rather than times. Clients must tolerate the newer fields being absent.

## Identity

Filers are resolved to bioguide IDs server-side (`backend/src/identity.js`) at ingestion, with the result and a `match_confidence` stored on each disclosure. Chamber and state are hard constraints; district and party only break ties because providers lag redistricting. Matching tiers are exact name, surname plus canonical given name, surname plus initial, unique surname within a state, then a guarded fuzzy match. Unmatched rows keep `match_confidence = 0` and are never dropped; the app falls back to the same rules for older rows.

Each intelligence item includes a research-priority score, human-readable ranking reasons, a source URL, confidence, publication/retrieval timestamps, and a rules-derived “Why it matters” explanation. The latest licensed session move may be shown as broad current context; it is not labelled as a timestamp-aligned event reaction. True reaction windows remain hidden until historical intraday data is attached.

## Ranking

Disclosure ranking weights public recency (30%), financial materiality (25%), political relevance (20%), current licensed market context (15%), and source confidence (10%). Superseded and ambiguous records receive penalties. The score prioritizes research attention and must never be presented as an investment signal.

Because recency decays, scores are recomputed when served (`/v1/snapshot`, `/v1/disclosures`) and persisted for the last 60 days on every scheduled sync, so stored ordering never freezes at ingestion time.

## Coverage and failure behavior

The app makes no fixed ten-year claim. Coverage is computed from available normalized records and labelled accordingly. Source outages, missing licenses, extraction failures, and empty datasets are visible to users with last-sync metadata; no fixture fallback is permitted. The app distinguishes a source that is not connected (no retry offered) from one that failed (retry offered), and warns on the Latest tab when a source has failed or has not succeeded in 36 hours.

## App structure

The app has four tabs (five once licensed market data is connected):

- **Latest** groups the last 90 days of filings (`/v1/disclosures?date_basis=filed`) into periodic transaction reports by source document, then surfaces followed members, the newest filings, the largest trades, the most active members, and late reports.
- **Trades** lists the same window trade by trade, filterable by buys and sells and searchable by ticker, company, or member, with filings awaiting extraction kept separate.
- **Members** covers the full roster, with follows and filters by party and chamber, plus filers who could not be matched to a sitting member.
- **Markets** appears only when instruments are available or the market data source is configured.
- **Settings** holds appearance, language, source health, methodology, and legal pages.

A report is "late" when it was filed more than 45 days after the transaction, the STOCK Act's outer deadline. Follows and the last-visit time are stored on device only.
