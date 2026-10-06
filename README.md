# Consigliere

Consigliere is an iOS political-market intelligence publication for self-directed investors and researchers. It presents newly public congressional disclosures and political statements alongside timestamped market context, source evidence, and explicit uncertainty. It does not provide personalized investment recommendations.

## Product principles

- Political-market intelligence, with primary-source evidence
- Transaction dates and public disclosure dates are always distinct
- “Why it matters” summaries are generated from visible evidence, not predictions
- Research-priority rankings explain their factors and are never buy/sell signals
- Missing or failed sources produce explicit status screens; the app has no runtime fixture fallback
- Historical claims reflect retrieved coverage rather than a fixed ten-year promise

## Architecture

The iOS app consumes two normalized endpoints from the Cloudflare Worker:

```text
GET /v1/snapshot       ranked feed, source health, per-politician summaries, pending filings
GET /v1/disclosures    paginated history (politician_id, representative, ticker, chamber, from/to)
```

The app opens on **Latest** (recent filings, followed members, largest and late trades), with **Trades**, **Members**, and **Settings** tabs; **Markets** appears once licensed market data is connected. See [docs/architecture.md](docs/architecture.md#app-structure).

The Worker stores normalized records and raw provider payloads in D1. Its adapters cover:

- Official House filing metadata from the Clerk's annual ZIP index and a compliant Senate eFD collector
- Apify actor `pink_comic/congress-stock-trading-disclosures` for structured House and Senate transactions
- Licensed Truth Social monitoring
- Licensed Twelve Data market data with attribution

Official filings remain canonical provenance. Filing-only records are preserved separately and are not represented as trades.

## Local setup

Open `Consigliere.xcodeproj` in Xcode 15 or newer and run the `Consigliere` scheme on iOS 17 or newer. The project is generated with XcodeGen:

```sh
xcodegen generate
```

The app defaults to the production Worker; set `CONSIGLIERE_API_BASE_URL` (in the scheme environment or build settings) to point at another deployment such as `http://localhost:8787`. If it is absent or the service fails, Consigliere shows an explicit live-source error and never substitutes sample data.

For the Worker:

```sh
cd backend
npm install
npx wrangler d1 migrations apply consigliere-data --local
npx wrangler dev
```

Copy `.dev.vars.example` to `.dev.vars` and configure only the sources you are licensed to use. Production credentials must be stored with `wrangler secret put`. Never place an Apify token in the app bundle, Git history, or a committed URL.

Apply every D1 migration before deploying a Worker revision. The sync path uses per-provider leases and writes an auditable `sync_runs` record, so overlapping scheduled and manual runs do not duplicate work.

```sh
npx wrangler d1 migrations apply consigliere-data --remote
npx wrangler deploy
```

Two crons run: `0 */12 * * *` syncs live sources, re-ranks the last 60 days, and matches new filers to politicians; `15 * * * *` processes one queued historical backfill job. Backfill jobs whose provider is skipped or unconfigured are deferred rather than failed.

Operational endpoints (bearer `SYNC_TOKEN`), each resumable with the returned `nextAfterID`:

```text
POST /internal/rematch   {"retryUnmatched": false, "afterID": null, "limit": 500}
POST /internal/rerank    {"all": true, "afterID": null, "limit": 500}
```

Run both once after deploying migration `0006` so existing rows get politician IDs and current scores.

The congressional roster is bundled at `Consigliere/Resources/Data/current-politicians.json` and shared by the app and Worker. Refresh it after elections or special elections with `node backend/scripts/update-roster.mjs`, then redeploy the Worker and ship an app build.

## Publishing and data rights

Consigliere is positioned as a public-interest news and research publisher. Public release still requires legal review confirming that storage, analysis, citation, and mobile display comply with the House/Senate disclosure rules and every market/social-data agreement. Free personal-use API plans are not assumed to permit redistribution.

## Disclaimer

Consigliere is an informational research publication. Nothing in the app constitutes investment advice, a recommendation, or an offer to buy or sell a security.
