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

The iOS app consumes normalized endpoints from the Cloudflare Worker:

```text
GET /v1/snapshot       ranked feed, source health, per-politician summaries, pending filings
GET /v1/disclosures    paginated history (politician_id, representative, ticker, chamber, from/to)
GET /v1/portfolios/{id}  estimated member, Congress and committee holdings
GET /v1/portfolios/{id}/changes  source-linked position changes
GET /v1/statements     presidential actions, briefings and remarks with quoted tags
GET /v1/statements/{id}  statement, related holdings and trades
GET /v1/members?country=uk  UK roster
GET /v1/interests?country=uk  declared interests, optionally by member_id or ticker
POST /v1/statement-corrections  queues a tag report for human review
```

The app opens on **Latest** (counts since the previous visit, followed filings, a rules-selected notable trade, a weekly pulse, and compact recent lists), with **Trades**, **Members**, and **Settings** tabs; **Markets** appears once licensed market data is connected. See [docs/architecture.md](docs/architecture.md#app-structure).

The Worker stores normalized records and raw provider payloads in D1. Its adapters cover:

- Official House filing metadata from the Clerk's annual ZIP index (there is no direct Senate eFD collector; Senate transactions come only from Apify)
- House transactions read directly from the Clerk's electronically filed PTR PDFs (`backend/src/house-ptr.js`, provider `house-ptr`); scanned paper reports are not read yet
- Apify actor `pink_comic/congress-stock-trading-disclosures` for Senate transactions, earlier House years, and House reports the PDF reader has not replaced
- House annual Schedule A assets used as year-end portfolio anchors when the report validates; unreadable reports keep the trade-only estimate
- UK Commons and Lords declared interests, with unmatched organisations preserved
- White House action, briefing and remarks feeds, plus Federal Register confirmations and document metadata
- SEC issuer/SIC metadata with a declared contact, and bounded OpenFIGI company matching
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

Three crons run: `0 */12 * * *` syncs live sources, reads up to three annual reports, re-ranks the last 60 days, matches new filers and rebuilds reference portfolios; `15 * * * *` processes one queued historical backfill job and advances bounded security matching; `45 * * * *` reads up to 30 unread House PTR PDFs and three queued annual reports. The annual index is the reporting year’s archive, not the year in which the report was filed. Routine House Apify collection continues until every indexed current-year report is extracted, empty or paper; thereafter routine runs request Senate only. Explicit historical backfills remain available. Backfill jobs whose provider is skipped or unconfigured are deferred rather than failed.

`HOUSE_PTR_MODE` in `wrangler.toml` decides what the House PDF reader's rows do. `shadow` stores them without serving them; `live` serves them and holds back Apify's rows for each report the reader has replaced; `off` stops reading PDFs. Every run reconciles stored rows with the current mode, so switching back needs only a config change and a deploy. Reports that do not read cleanly are marked `needs-review` and keep their Apify rows. To compare the reader with whatever the production API serves:

```sh
node backend/scripts/validate-house-ptr.mjs --year 2026
```

Operational endpoints (bearer `SYNC_TOKEN`), each resumable with the returned `nextAfterID`:

```text
POST /internal/rematch   {"retryUnmatched": false, "afterID": null, "limit": 500}
POST /internal/rerank    {"all": true, "afterID": null, "limit": 500}
```

Run both once after deploying migration `0006` so existing rows get politician IDs and current scores.

The congressional roster is bundled at `Consigliere/Resources/Data/current-politicians.json` and shared by the app and Worker. Refresh it after elections or special elections with `node backend/scripts/update-roster.mjs`, then redeploy the Worker and ship an app build.

## Publishing and data rights

Consigliere is positioned as a public-interest news and research publisher. Public release still requires legal review confirming that storage, analysis, citation, and mobile display comply with the House/Senate disclosure rules and every market/social-data agreement. Free personal-use API plans are not assumed to permit redistribution.

## Build plan and release status

See [the build record](docs/build-status.md) for implemented features, exact checks and remaining gates, and [the permission-request drafts](docs/permission-requests.md) for Canada/Australia access requests and a legal-review brief. This revision has been tested locally; it has not been deployed. Apply migration `0008_research.sql` before deploying it. The migration namespaces existing US member IDs and preserves disclosure IDs and source payloads.

The public-source sync exceeds the free Worker’s 50-subrequest/query limits; verify the deployment’s Worker/D1 plan before release. The configured collector limits bound each run, and bulk JSON writes avoid one SQL query per member. No account plan or billing was changed during this build.

## Disclaimer

Consigliere is an informational research publication. Nothing in the app constitutes investment advice, a recommendation, or an offer to buy or sell a security.
