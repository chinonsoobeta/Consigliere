# Live intelligence architecture

`IntelligenceProvider` is a live-only boundary. The production app requests a unified snapshot from the Cloudflare Worker; an absent URL, failed request, or unconfigured source produces an explicit error state. Synthetic records exist only inside tests.

The Worker owns credentials, retrieval, normalization, ranking, provenance, and source health. D1 retains official filing metadata, structured disclosures, annual asset anchors, reference portfolios, declared interests, statements, market instruments, raw provider payloads, retrieval timestamps, and sync outcomes. Per-provider leases prevent overlapping scheduled/manual syncs, and bounded D1 batches avoid excessive serial writes.

## Source policy

Official House and Senate filings are canonical provenance. The House collector reads the official annual disclosure index and preserves PTR documents as filing records. Electronically filed House PTRs are then read directly from the Clerk's PDFs: column positions come from each page's header row, and each row keeps its owner, asset-type code (`OP` marks options), ticker when the filer gave one, and the filer's note. Senate transactions, earlier House years, and House reports the reader has not replaced come from the configured Apify actor and must retain official Clerk or Senate eFD document links. A filing that cannot be parsed remains a filing; it is never converted into an inferred trade.

`house_ptr_extractions` records one outcome per House report: `extracted`, `empty`, `needs-review` (warnings or a filing-ID mismatch; its Apify rows stay), `failed` (retried up to three times), or `paper` (a scan with no text layer). `disclosures.suppressed_by` holds rows back without deleting them: `shadow` for reader rows under comparison, `house-ptr` for Apify rows of a report the reader has replaced. Every query that serves disclosures requires `suppressed_by IS NULL`.

A retryable House PDF failure does not degrade source health until three attempts have been exhausted. Routine Apify runs request Senate only once every indexed current-year House report is classified as extracted, empty or paper. Review reports and exhausted failures keep routine House collection eligible. Explicit historical backfills retain their requested chambers.

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

US filers are resolved to Bioguide IDs server-side (`backend/src/identity.js`) at ingestion, with the result and a `match_confidence` stored on each disclosure. The shared member identifier is namespaced (`us:P000197`, `uk:5158`); `source_id` preserves the original source identifier. Migration 0008 updates existing US member references while retaining disclosure IDs and payloads. The app accepts earlier unprefixed US IDs and migrates device follows when they are read. Chamber and state are hard constraints; district and party only break ties because providers lag redistricting. Matching tiers are exact name, surname plus canonical given name, surname plus initial, unique surname within a state, then a guarded fuzzy match. Unmatched rows keep `match_confidence = 0` and are never dropped; the app falls back to the same rules for older rows.

Member records include country, legislature, chamber, region label, source party colour, photo provenance, optional Wikidata ID and service end. Only US disclosures use the 45-day late-report label. UK members have declared-interest profiles without trade-based statistics.

Each intelligence item includes a research-priority score, human-readable ranking reasons, a source URL, confidence, publication/retrieval timestamps, and a rules-derived “Why it matters” explanation. The latest licensed session move may be shown as broad current context; it is not labelled as a timestamp-aligned event reaction. True reaction windows remain hidden until historical intraday data is attached.

## Ranking

Disclosure ranking weights public recency (30%), financial materiality (25%), political relevance (20%), current licensed market context (15%), and source confidence (10%). Superseded and ambiguous records receive penalties. The score prioritizes research attention and must never be presented as an investment signal.

Because recency decays, scores are recomputed when served (`/v1/snapshot`, `/v1/disclosures`) and persisted for the last 60 days on every scheduled sync, so stored ordering never freezes at ingestion time.

## Coverage and failure behavior

The app makes no fixed ten-year claim. Coverage is computed from available normalized records and labelled accordingly. Source outages, missing licenses, extraction failures, and empty datasets are visible to users with last-sync metadata; no fixture fallback is permitted. The app distinguishes a source that is not connected (no retry offered) from one that failed (retry offered), and warns on the Latest tab when a source has failed or has not succeeded in 36 hours.

Member and stock histories use paginated disclosure endpoints rather than the ranked snapshot and continue until the server has no next cursor. Repeated cursors fail explicitly without presenting a partial history as complete. Home uses the existing 90-day filed-date window. Applying a Home filter clears the Trades search/type selection, including when the same Home filter is requested again; history failures have a visible retry state in Trades.

## Reference portfolios and statements

Migration 0008 adds `reference_portfolios`, `reference_positions`, `reference_changes`, `securities`, `committee_assignments`, `house_annual_reports`, `statements` and `statement_corrections`. Reference method version 2 uses band midpoints and propagated intervals, separates owners and asset classes, records missing prior holdings, and freezes departed members at the roster's last term end. Unspecified sale extent remains explicitly uncertain. Congress and committee views count unique members holding each position; dollar estimates are secondary and are not current market values.

Validated House annual Schedule A reports supply year-end anchors. The reporting-year archive can contain reports filed the following year. Later transaction dates adjust the anchor; older trades are not counted twice. Unreadable, scanned, mismatched or review reports cannot supply anchors. The annual collector processes three reports per run and records parser version and bounded attempts. Source dates and links are returned with member estimates. Senate annual reports are not collected.

SEC ticker/CIK and SIC metadata supplies a coarse eleven-sector mapping. A declared SEC contact is required. Non-SEC securities are excluded from EDGAR enrichment. Committee assignments preserve the first date observed and subsequent end dates; these dates do not assert reconstructed historical membership.

White House actions, briefings and remarks retain their published text. Federal Register records add signing dates and document numbers; a conservative title/date match confirms a White House record without replacing its quoted text. Rules identify company, sector, country, commodity and policy mentions. Optional Haiku tagging accepts only exact quotes and permitted dictionary values, with model and prompt versions stored. Relevance tiers and first-mention ranking are independent of investment predictions.

Research routes serve portfolios, source-linked changes, statements, company holdings and trades within 30 transaction days either side of a statement. `POST /v1/statement-corrections` validates a tag and queues a report. Bearer-authenticated `GET /internal/review` supplies pending correction and ambiguous security-match records for human review; no automatic approval is implied.

## Declared interests

The UK collector retrieves the paginated Members API roster, incrementally retrieves Commons shareholdings by update date, and retrieves Lords Category 2 entries including ceased interests. Commons category number 7 is resolved to its API category ID instead of assuming the two are identical. Dates, thresholds, source payloads and unmatched private companies are retained in `interest_records`.

Exact issuer-name matches can use SEC metadata or bounded OpenFIGI search results. Ambiguous results remain in the review queue. Exchange-qualified tickers and FIGIs are retained when supplied; an issuer-name match does not establish an undisclosed security class or amount. OpenFIGI search follows the configured public or API-key rate window. No paid listing service was introduced.

Canada and Australia return `permission_pending` until an explicit permission configuration is present. Their collectors have not been built or run because written access/reuse permission is absent. Setting the flag alone does not create a collector. Permission requests and the legal-review brief are in `permission-requests.md`.

## App structure

The app has four tabs (five once licensed market data is connected):

- **Latest** shows counts since the previous visit (the latest week on first launch), followed filings or mixed suggestions, one rules-selected notable trade, a twelve-week filing pulse, compact recent and late lists, active members, White House statements and a Congress portfolio link. Countries other than the US can be enabled in Settings.
- **Trades** lists the same window trade by trade, with Home filters for filed date, members, minimum band, late reports and options, plus ticker/company/member search. Filings awaiting extraction remain separate.
- **Members** provides a country picker, follows and country-specific party/chamber filters. US profiles load complete available history, monthly activity and filing-delay charts, a ten-position estimated-holdings preview and full portfolio navigation. UK profiles show declared interests and changes. Congress and committee portfolios are accessible from Members.
- **Markets** appears only when instruments are available or the market data source is configured.
- **Settings** holds appearance, language (en, en-CA, es, fr, fr-CA), Home countries, source health, methodology and legal pages.

Stock pages show transaction/filed-date markers sized by disclosed band, members who traded, estimated Congress holders, UK declared holders when matched, and company mentions in presidential actions. Every new chart has an accessibility descriptor. Price lines, reactions, performance and paid alerts remain dependent on licensed data and legal review.

A report is "late" when it was filed more than 45 days after the transaction, the STOCK Act's outer deadline. Follows and the last-visit time are stored on device only.
