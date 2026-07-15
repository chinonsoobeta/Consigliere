# Consigliere

Consigliere is a North America-focused market intelligence prototype for iOS. It connects political events and public congressional disclosures with transparent, timestamped market context while avoiding personalized investment recommendations.

## Prototype capabilities

- U.S. and Canadian market pulse with European, Asia-Pacific, and global context
- Congressional disclosure and presidential social-post event feed
- Search across equities, indices, ETFs, futures, and physical crude assessments
- Search all current House and Senate members using a bundled Congress.gov roster
- Ten-year disclosure coverage, transaction event studies, and source-level filing dates
- Politician Model Portfolios with reported-holdings and public-information simulations
- Event-window market analysis with provenance and freshness labels
- Watchlist and hypothetical portfolio exposure diagnostics
- Light/dark appearance and US English, Canadian English, Spanish, and French localization
- Accessibility support for Dynamic Type, VoiceOver, and color-independent status cues

The included provider is deterministic prototype data. An Apify-ready ingestion service now lives in `backend/`; it keeps the Apify token server-side, runs Ryan Clinton's `congress-stock-tracker` Actor, stores raw source payloads for audits, preserves filing-only records, and exposes normalized disclosures to the iOS client. Production deployment still requires an Apify account with Actor access, licensed market/social feeds, legal review, and verification of data-use rights.

See [the architecture note](docs/architecture.md) for the production ingestion boundary and compliance posture.

## Open the project

Open `Consigliere.xcodeproj` in Xcode 15 or newer and run the `Consigliere` scheme on iOS 17 or newer.

If Xcode has never been launched on the machine, accept Apple’s Xcode license before running command-line builds.

The project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
xcodegen generate
```

## Apify ingestion setup

The production backend is deployed at `https://consigliere-ingestion.chinonsoobeta.workers.dev`. It is a Cloudflare Worker with a D1 database and a cost-conscious six-hour scheduled sync. It invokes `ryanclinton/congress-stock-tracker` through Apify's synchronous Actor API. Do not put the Apify token in Xcode or commit `.dev.vars`.

1. In `backend/`, run `npm install` and `npx wrangler d1 create consigliere-data`.
2. Replace the placeholder `database_id` in `backend/wrangler.toml` and apply the D1 migration.
3. Store credentials with `npx wrangler secret put APIFY_API_TOKEN` and `npx wrangler secret put SYNC_TOKEN`.
4. Deploy the Worker, then set the Xcode build setting `CONSILIERE_API_BASE_URL` to its HTTPS origin.

Without that base URL, the iOS app deliberately remains on bundled prototype data. The scheduled Actor input looks back three days, uses watchlist mode, limits output to 200 records, and enables a residential proxy for Senate reliability. The authenticated `/internal/backfill` route supports explicit windows, but this Actor limits an individual run to 730 days and 1,000 results. It cannot by itself satisfy the complete ten-year-history requirement; older history will need archival imports or another source. Filing-only and metadata-only results are stored separately at `/v1/source-filings` instead of being represented as stock trades.

## Disclaimer

Consigliere is an informational research tool. Nothing in the app constitutes investment advice, a recommendation, or an offer to buy or sell a security.
