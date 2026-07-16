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

The iOS app consumes one normalized endpoint from the Cloudflare Worker:

```text
GET /v1/snapshot
```

The Worker stores normalized records and raw provider payloads in D1. Its adapters cover:

- Official House filing metadata from the Clerk's annual ZIP index and a compliant Senate eFD collector
- Optional FMP reconciliation for structured congressional transactions
- Licensed Truth Social monitoring
- Licensed Twelve Data market data with attribution

Official filings remain canonical provenance. Filing-only records are preserved separately and are not represented as trades.

## Local setup

Open `Consigliere.xcodeproj` in Xcode 15 or newer and run the `Consigliere` scheme on iOS 17 or newer. The project is generated with XcodeGen:

```sh
xcodegen generate
```

Set `APIFY_RUN_URL` to an Apify actor-run URL, or set `APIFY_API_TOKEN` and `APIFY_ACTOR_ID` to run the configured actor directly. The app fetches Apify dataset items and expects the first dataset item to contain the normalized Consigliere snapshot payload. If the Apify configuration is absent or the actor fails, Consigliere shows an explicit live-source error and never substitutes sample data.

## Publishing and data rights

Consigliere is positioned as a public-interest news and research publisher. Public release still requires legal review confirming that storage, analysis, citation, and mobile display comply with the House/Senate disclosure rules and every market/social-data agreement. Free personal-use API plans are not assumed to permit redistribution.

## Disclaimer

Consigliere is an informational research publication. Nothing in the app constitutes investment advice, a recommendation, or an offer to buy or sell a security.
