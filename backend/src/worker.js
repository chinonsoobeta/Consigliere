import {
  collectApifyDisclosures, collectMarketData, collectOfficialFilings, collectTruthPosts
} from "./providers.js";
import { rankDisclosure, rankSocialPost, whyDisclosureMatters } from "./ranking.js";
import { stableUUID } from "./normalization.js";

const EXPECTED_SOURCES = [
  ["official-disclosures", "Official House disclosure index"],
  ["apify", "Structured House and Senate disclosures"],
  ["truth-api", "Truth Social political monitoring"],
  ["twelve-data", "Licensed market data"]
];
const MAX_INTERNAL_BODY_BYTES = 4096;
const SYNC_LOCK_MS = 15 * 60_000;
const WORKER_VERSION = "2026-07-16-apify-v2";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/health") return health(env);
    if (request.method === "GET" && url.pathname === "/v1/snapshot") return snapshot(env);
    if (request.method === "GET" && url.pathname === "/v1/disclosures") return listDisclosures(url, env);
    if (request.method === "GET" && url.pathname === "/v1/intelligence") return listIntelligence(url, env);
    if (request.method === "GET" && url.pathname === "/v1/source-filings") return listSourceFilings(url, env);
    if (request.method === "POST" && url.pathname === "/internal/sync") {
      if (!await authorized(request, env)) return json({ error: "unauthorized" }, 401);
      return json(await syncAll(env));
    }
    if (request.method === "POST" && url.pathname === "/internal/backfill") {
      if (!await authorized(request, env)) return json({ error: "unauthorized" }, 401);
      const bodyResult = await readSmallJSON(request);
      if (bodyResult.error) return json({ error: bodyResult.error }, bodyResult.status);
      const body = bodyResult.value;
      const currentYear = new Date().getUTCFullYear();
      const requestedYear = Number(body.year ?? currentYear);
      if (!Number.isInteger(requestedYear) || requestedYear < 2008 || requestedYear > currentYear) {
        return json({ error: "invalid_year", minimum: 2008, maximum: currentYear }, 400);
      }
      const results = await Promise.allSettled([
        syncOfficial(env, requestedYear),
        syncApify(env, {
          chamber: body.chamber,
          filingYear: requestedYear,
          maxResults: body.maxResults,
          query: body.query,
          state: body.state
        })
      ]);
      return json(settledResponse(results));
    }
    return json({ error: "not_found" }, 404);
  },

  async scheduled(_controller, env, ctx) {
    ctx.waitUntil(syncAll(env));
  }
};

async function health(env) {
  const result = await env.DB.prepare(`
    SELECT provider, display_name, status, last_attempt_at, last_success_at,
           records_seen, message, coverage_start, coverage_end
    FROM source_health ORDER BY provider
  `).all();
  const sources = mergeSourceHealth(result.results);
  const degraded = sources.some((source) => source.status !== "available");
  return json({ status: degraded ? "degraded" : "ok", version: WORKER_VERSION, sources });
}

async function snapshot(env) {
  const [instruments, disclosures, posts, healthRows, coverage] = await Promise.all([
    env.DB.prepare(`
      SELECT symbol, name, exchange_name, currency, region, instrument_kind, price,
             change_percent, updated_at, sector, provider, attribution
      FROM market_instruments ORDER BY symbol
    `).all(),
    env.DB.prepare(`
      SELECT id, politician_id, representative, ticker, asset_name, transaction_type, owner,
             amount_range, transaction_date, report_date, source_url, chamber, confidence,
             ranking_score, ranking_reasons, why_it_matters
      FROM disclosures
      WHERE ranking_score > 0
      ORDER BY ranking_score DESC, report_date DESC LIMIT 250
    `).all(),
    env.DB.prepare(`
      SELECT id, author, body, source_url, published_at, retrieved_at, edited_at, deleted_at,
             policy_topics, mentioned_symbols, confidence, ranking_score, ranking_reasons,
             why_it_matters
      FROM social_posts WHERE deleted_at IS NULL
      ORDER BY ranking_score DESC, published_at DESC LIMIT 100
    `).all(),
    env.DB.prepare(`
      SELECT provider, display_name, status, last_attempt_at, last_success_at,
             records_seen, message, coverage_start, coverage_end
      FROM source_health ORDER BY provider
    `).all(),
    disclosureCoverage(env)
  ]);

  const disclosureData = disclosures.results.map(mapDisclosure);
  const intelligence = [
    ...disclosureData.map(disclosureIntelligenceItem),
    ...posts.results.map(mapSocialIntelligenceItem)
  ].sort((a, b) => b.rankingScore - a.rankingScore || b.publishedAt.localeCompare(a.publishedAt));

  return json({
    data: {
      instruments: instruments.results.map(mapInstrument),
      intelligence,
      disclosures: disclosureData,
      sourceHealth: mergeSourceHealth(healthRows.results),
      coverage
    },
    meta: {
      generatedAt: new Date().toISOString(),
      publisher: "Consigliere public-interest news and research",
      version: WORKER_VERSION
    }
  });
}

async function listIntelligence(url, env) {
  const response = await snapshot(env);
  const payload = await response.json();
  const limit = clamp(Number(url.searchParams.get("limit")) || 100, 1, 500);
  return json({ data: payload.data.intelligence.slice(0, limit), meta: payload.meta });
}

async function listDisclosures(url, env) {
  const politicianID = url.searchParams.get("politician_id");
  const ticker = url.searchParams.get("ticker")?.toUpperCase();
  const from = url.searchParams.get("from");
  const to = url.searchParams.get("to");
  const limit = clamp(Number(url.searchParams.get("limit")) || 1000, 1, 5000);
  const clauses = [];
  const values = [];
  if (politicianID) { clauses.push("politician_id = ?"); values.push(politicianID); }
  if (ticker) { clauses.push("ticker = ?"); values.push(ticker); }
  if (from) { clauses.push("transaction_date >= ?"); values.push(from); }
  if (to) { clauses.push("transaction_date <= ?"); values.push(to); }
  const where = clauses.length ? `WHERE ${clauses.join(" AND ")}` : "";
  const result = await env.DB.prepare(`
    SELECT id, politician_id, representative, ticker, asset_name, transaction_type, owner,
           amount_range, transaction_date, report_date, source_url, chamber, confidence,
           ranking_score, ranking_reasons, why_it_matters
    FROM disclosures ${where}
    ORDER BY report_date DESC, transaction_date DESC LIMIT ?
  `).bind(...values, limit).all();
  const data = result.results.map(mapDisclosure);
  return json({ data, meta: { count: data.length, generatedAt: new Date().toISOString() } });
}

async function listSourceFilings(url, env) {
  const limit = clamp(Number(url.searchParams.get("limit")) || 200, 1, 1000);
  const result = await env.DB.prepare(`
    SELECT id, provider, representative, chamber, disclosure_date, filing_url, doc_id, extraction_status
    FROM source_filings ORDER BY disclosure_date DESC LIMIT ?
  `).bind(limit).all();
  return json({ data: result.results, meta: { count: result.results.length } });
}

async function syncAll(env) {
  const market = await Promise.allSettled([syncMarkets(env)]);
  const remaining = await Promise.allSettled([
    syncOfficial(env),
    syncApify(env),
    syncTruth(env)
  ]);
  const settled = [...market, ...remaining];
  const degraded = settled.some((result) =>
    result.status === "rejected" || result.value.status !== "available"
  );
  return {
    status: degraded ? "degraded" : "succeeded",
    sources: settled.map((result) => result.status === "fulfilled"
      ? result.value
      : { status: "failed", error: String(result.reason?.message ?? result.reason) })
  };
}

async function syncOfficial(env, year = new Date().getUTCFullYear()) {
  return withHealth(env, "official-disclosures", "Official House disclosure index", async () => {
    const { filings, failures } = await collectOfficialFilings(env, year);
    const now = new Date().toISOString();
    await executeInChunks(
      env.DB,
      filings.map((filing) => sourceFilingStatement(
        env.DB, { ...filing, observedAt: now, updatedAt: now }
      ))
    );
    if (filings.length === 0 && failures.length) throw new Error(failures.map((item) => item.error).join("; "));
    return {
      recordsSeen: filings.length,
      recordsWritten: filings.length,
      coverageStart: minimumDate(filings.map((item) => item.disclosureDate)),
      coverageEnd: maximumDate(filings.map((item) => item.disclosureDate)),
      message: failures.length ? failures.map((item) => `${item.provider}: ${item.error}`).join("; ") : null
    };
  });
}

async function syncApify(env, input = {}) {
  return withHealth(env, "apify", "Structured House and Senate disclosures", async () => {
    if (!env.APIFY_API_TOKEN) return { recordsSeen: 0, message: "Not configured" };
    const { filings, disclosures } = await collectApifyDisclosures(env, input);
    const now = new Date().toISOString();
    const marketMoves = await marketMoveLookup(env.DB);
    const disclosureStatements = disclosures.map((record) => {
      const enriched = {
        ...record,
        marketMovePercent: marketMoves.get(record.ticker) ?? null
      };
      const ranking = rankDisclosure(enriched);
      return disclosureStatement(env.DB, {
        ...enriched,
        rankingScore: ranking.score,
        rankingReasons: ranking.reasons,
        whyItMatters: whyDisclosureMatters(enriched),
        observedAt: now,
        updatedAt: now
      });
    });
    const filingStatements = filings.map((filing) => sourceFilingStatement(
      env.DB, { ...filing, observedAt: now, updatedAt: now }
    ));
    await executeInChunks(env.DB, [...disclosureStatements, ...filingStatements]);
    return {
      recordsSeen: filings.length,
      recordsWritten: disclosures.length + filings.length,
      coverageStart: minimumDate(filings.map((item) => item.disclosureDate)),
      coverageEnd: maximumDate(filings.map((item) => item.disclosureDate)),
      message: filings.length ? null : "No filings returned by Apify"
    };
  });
}

async function syncTruth(env) {
  return withHealth(env, "truth-api", "Truth Social political monitoring", async () => {
    if (!env.TRUTH_API_URL || !env.TRUTH_API_TOKEN) return { recordsSeen: 0, message: "Not configured" };
    const rows = await collectTruthPosts(env);
    const now = new Date().toISOString();
    const marketMoves = await marketMoveLookup(env.DB);
    const statements = rows.map((row) => {
      const enriched = {
        ...row,
        marketMovePercent: row.mentionedSymbols.length
          ? marketMoves.get(row.mentionedSymbols[0]) ?? null
          : null
      };
      const ranking = rankSocialPost(enriched);
      return env.DB.prepare(`
        INSERT INTO social_posts(id, provider, author, body, source_url, published_at, retrieved_at,
          edited_at, deleted_at, policy_topics, mentioned_symbols, confidence, ranking_score,
          ranking_reasons, why_it_matters, raw_json, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET body=excluded.body, retrieved_at=excluded.retrieved_at,
          edited_at=excluded.edited_at, deleted_at=excluded.deleted_at,
          policy_topics=excluded.policy_topics, mentioned_symbols=excluded.mentioned_symbols,
          confidence=excluded.confidence, ranking_score=excluded.ranking_score,
          ranking_reasons=excluded.ranking_reasons, why_it_matters=excluded.why_it_matters,
          raw_json=excluded.raw_json, updated_at=excluded.updated_at
      `).bind(
        row.id, row.provider, row.author, row.body, row.sourceURL, row.publishedAt, row.retrievedAt,
        row.editedAt, row.deletedAt, JSON.stringify(row.policyTopics), JSON.stringify(row.mentionedSymbols),
        row.confidence, ranking.score, JSON.stringify(ranking.reasons),
        socialWhyItMatters(enriched), row.rawJSON, now
      );
    });
    await executeInChunks(env.DB, statements);
    return {
      recordsSeen: rows.length,
      recordsWritten: rows.length,
      coverageStart: minimumDate(rows.map((item) => item.publishedAt)),
      coverageEnd: maximumDate(rows.map((item) => item.publishedAt))
    };
  });
}

async function syncMarkets(env) {
  return withHealth(env, "twelve-data", "Licensed market data", async () => {
    if (!env.TWELVE_DATA_API_KEY) return { recordsSeen: 0, message: "Not configured" };
    const rows = await collectMarketData(env);
    const statements = rows.map((row) => env.DB.prepare(`
        INSERT INTO market_instruments(symbol, name, exchange_name, currency, region, instrument_kind,
          price, change_percent, updated_at, sector, provider, attribution, raw_json)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(symbol) DO UPDATE SET name=excluded.name, exchange_name=excluded.exchange_name,
          currency=excluded.currency, region=excluded.region, instrument_kind=excluded.instrument_kind,
          price=excluded.price, change_percent=excluded.change_percent, updated_at=excluded.updated_at,
          sector=excluded.sector, provider=excluded.provider, attribution=excluded.attribution,
          raw_json=excluded.raw_json
      `).bind(
        row.symbol, row.name, row.exchange, row.currency, row.region, row.kind, row.price,
        row.changePercent, row.updatedAt, row.sector, row.provider, row.attribution, row.rawJSON
      ));
    await executeInChunks(env.DB, statements);
    return {
      recordsSeen: rows.length,
      recordsWritten: rows.length,
      coverageStart: minimumDate(rows.map((item) => item.updatedAt)),
      coverageEnd: maximumDate(rows.map((item) => item.updatedAt))
    };
  });
}

async function withHealth(env, provider, displayName, operation) {
  const attemptedAt = new Date().toISOString();
  const lockToken = crypto.randomUUID();
  if (!await acquireSyncLock(env.DB, provider, lockToken, attemptedAt)) {
    return { provider, status: "skipped", recordsSeen: 0, message: "Sync already running" };
  }
  let runID = null;
  try {
    runID = await beginSyncRun(env.DB, provider, attemptedAt);
    const result = await operation();
    const status = result.message === "Not configured" ? "unconfigured" : (result.message ? "degraded" : "available");
    await updateHealth(env.DB, {
      provider, displayName, status, attemptedAt,
      succeededAt: status === "available" || status === "degraded" ? attemptedAt : null,
      recordsSeen: result.recordsSeen ?? 0,
      message: result.message ?? null,
      coverageStart: result.coverageStart ?? null,
      coverageEnd: result.coverageEnd ?? null
    });
    await finishSyncRun(env.DB, runID, {
      status,
      recordsSeen: result.recordsSeen ?? 0,
      recordsWritten: result.recordsWritten ?? 0,
      errorMessage: null
    });
    return { provider, status, ...result };
  } catch (error) {
    const message = String(error?.message ?? error).slice(0, 1000);
    await updateHealth(env.DB, {
      provider, displayName, status: "failed", attemptedAt, succeededAt: null, recordsSeen: 0, message
    });
    await finishSyncRun(env.DB, runID, {
      status: "failed", recordsSeen: 0, recordsWritten: 0, errorMessage: message
    });
    throw error;
  } finally {
    await releaseSyncLock(env.DB, provider, lockToken);
  }
}

async function disclosureCoverage(env) {
  const result = await env.DB.prepare(`
    SELECT chamber, MIN(report_date) AS earliest, MAX(report_date) AS latest, COUNT(*) AS records
    FROM disclosures GROUP BY chamber
  `).all();
  return result.results.map((row) => ({
    chamber: row.chamber,
    earliest: row.earliest,
    latest: row.latest,
    records: row.records,
    completeness: "available-records"
  }));
}

async function updateHealth(db, value) {
  return db.prepare(`
    INSERT INTO source_health(provider, display_name, status, last_attempt_at, last_success_at,
      records_seen, message, coverage_start, coverage_end)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(provider) DO UPDATE SET display_name=excluded.display_name, status=excluded.status,
      last_attempt_at=excluded.last_attempt_at,
      last_success_at=COALESCE(excluded.last_success_at, source_health.last_success_at),
      records_seen=excluded.records_seen, message=excluded.message,
      coverage_start=COALESCE(excluded.coverage_start, source_health.coverage_start),
      coverage_end=COALESCE(excluded.coverage_end, source_health.coverage_end)
  `).bind(
    value.provider, value.displayName, value.status, value.attemptedAt, value.succeededAt,
    value.recordsSeen, value.message, value.coverageStart ?? null, value.coverageEnd ?? null
  ).run();
}

async function acquireSyncLock(db, provider, token, acquiredAt) {
  const lockedUntil = new Date(new Date(acquiredAt).valueOf() + SYNC_LOCK_MS).toISOString();
  const result = await db.prepare(`
    INSERT INTO sync_locks(provider, token, acquired_at, locked_until)
    VALUES (?, ?, ?, ?)
    ON CONFLICT(provider) DO UPDATE SET token=excluded.token, acquired_at=excluded.acquired_at,
      locked_until=excluded.locked_until
    WHERE sync_locks.locked_until < excluded.acquired_at
  `).bind(provider, token, acquiredAt, lockedUntil).run();
  return Number(result.meta?.changes ?? 0) > 0;
}

async function releaseSyncLock(db, provider, token) {
  await db.prepare("DELETE FROM sync_locks WHERE provider = ? AND token = ?")
    .bind(provider, token).run();
}

async function beginSyncRun(db, provider, startedAt) {
  const result = await db.prepare(`
    INSERT INTO sync_runs(provider, started_at, status) VALUES (?, ?, 'running')
  `).bind(provider, startedAt).run();
  return result.meta?.last_row_id ?? null;
}

async function finishSyncRun(db, runID, result) {
  if (runID == null) return;
  await db.prepare(`
    UPDATE sync_runs SET finished_at = ?, status = ?, records_seen = ?,
      records_written = ?, error_message = ? WHERE id = ?
  `).bind(
    new Date().toISOString(), result.status, result.recordsSeen,
    result.recordsWritten, result.errorMessage, runID
  ).run();
}

function disclosureStatement(db, value) {
  return db.prepare(`
    INSERT INTO disclosures(id, provider, politician_id, representative, report_date, transaction_date,
      ticker, asset_name, transaction_type, owner, amount_range, chamber, party, source_url,
      raw_json, observed_at, updated_at, confidence, ranking_score, ranking_reasons, why_it_matters)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET politician_id=COALESCE(excluded.politician_id, disclosures.politician_id),
      asset_name=excluded.asset_name, transaction_type=excluded.transaction_type, owner=excluded.owner,
      amount_range=excluded.amount_range, chamber=excluded.chamber, party=excluded.party,
      source_url=excluded.source_url, raw_json=excluded.raw_json, updated_at=excluded.updated_at,
      confidence=excluded.confidence, ranking_score=excluded.ranking_score,
      ranking_reasons=excluded.ranking_reasons, why_it_matters=excluded.why_it_matters
  `).bind(
    value.id, value.provider, value.politicianID, value.representative, value.reportDate,
    value.transactionDate, value.ticker, value.assetName, value.transactionType, value.owner,
    value.amountRange, value.chamber, value.party, value.sourceURL, value.rawJSON,
    value.observedAt, value.updatedAt, value.confidence, value.rankingScore,
    JSON.stringify(value.rankingReasons), value.whyItMatters
  );
}

function sourceFilingStatement(db, value) {
  return db.prepare(`
    INSERT INTO source_filings(id, provider, representative, chamber, disclosure_date, filing_url,
      doc_id, extraction_status, raw_json, observed_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET extraction_status=excluded.extraction_status,
      raw_json=excluded.raw_json, updated_at=excluded.updated_at
  `).bind(
    value.id, value.provider, value.representative, value.chamber, value.disclosureDate,
    value.filingURL, value.docID, value.extractionStatus, value.rawJSON,
    value.observedAt, value.updatedAt
  );
}

function disclosureIntelligenceItem(record) {
  return {
    id: record.id,
    source: record.chamber === "senate" ? "senateDisclosure" : "houseDisclosure",
    title: `${record.representative} disclosed a ${record.type} in ${record.symbol}`,
    body: `${record.assetName} · ${record.amountRange}`,
    author: record.representative,
    publishedAt: `${record.filedDate}T12:00:00Z`,
    retrievedAt: `${record.filedDate}T12:00:00Z`,
    transactionDate: `${record.transactionDate}T12:00:00Z`,
    sourceURL: record.sourceURL,
    mentionedSymbols: [record.symbol],
    topics: ["Congressional disclosure"],
    impact: impactForScore(record.rankingScore),
    confidence: record.confidence,
    explanation: record.whyItMatters,
    freshness: "delayed",
    rankingScore: record.rankingScore,
    rankingReasons: record.rankingReasons
  };
}

function mapSocialIntelligenceItem(row) {
  return {
    id: row.id,
    source: "truthSocial",
    title: `${row.author} published a political statement`,
    body: row.body,
    author: row.author,
    publishedAt: row.published_at,
    retrievedAt: row.retrieved_at,
    transactionDate: null,
    sourceURL: row.source_url,
    mentionedSymbols: parseJSON(row.mentioned_symbols, []),
    topics: parseJSON(row.policy_topics, []),
    impact: impactForScore(row.ranking_score),
    confidence: row.confidence,
    explanation: row.why_it_matters,
    freshness: "live",
    rankingScore: row.ranking_score,
    rankingReasons: parseJSON(row.ranking_reasons, [])
  };
}

function mapDisclosure(row) {
  return {
    id: row.id,
    politicianID: row.politician_id,
    representative: row.representative,
    symbol: row.ticker,
    assetName: row.asset_name,
    type: row.transaction_type,
    owner: row.owner,
    amountRange: row.amount_range,
    transactionDate: row.transaction_date,
    filedDate: row.report_date,
    sourceURL: row.source_url,
    chamber: row.chamber,
    confidence: row.confidence,
    rankingScore: row.ranking_score,
    rankingReasons: parseJSON(row.ranking_reasons, []),
    whyItMatters: row.why_it_matters
  };
}

function mapInstrument(row) {
  return {
    id: stableUUID(`instrument|${row.provider}|${row.symbol}`),
    symbol: row.symbol,
    name: row.name,
    exchange: row.exchange_name,
    currency: row.currency,
    region: row.region,
    kind: row.instrument_kind,
    price: row.price,
    changePercent: row.change_percent,
    freshness: freshnessForDate(row.updated_at),
    updatedAt: row.updated_at,
    sector: row.sector,
    aliases: [],
    history: [],
    provider: row.provider,
    attribution: row.attribution
  };
}

function mapHealth(row) {
  return {
    provider: row.provider,
    displayName: row.display_name,
    status: row.status,
    lastAttemptAt: row.last_attempt_at,
    lastSuccessAt: row.last_success_at,
    recordsSeen: row.records_seen,
    message: row.message,
    coverageStart: row.coverage_start,
    coverageEnd: row.coverage_end
  };
}

function mergeSourceHealth(rows) {
  const existing = new Map(rows.map((row) => [row.provider, mapHealth(row)]));
  return EXPECTED_SOURCES.map(([provider, displayName]) => existing.get(provider) ?? {
    provider,
    displayName,
    status: "unconfigured",
    lastAttemptAt: null,
    lastSuccessAt: null,
    recordsSeen: 0,
    message: "No sync has completed",
    coverageStart: null,
    coverageEnd: null
  });
}

function socialWhyItMatters(row) {
  const topics = row.policyTopics.length ? ` It maps to ${row.policyTopics.join(", ")}.` : "";
  const market = row.marketMovePercent == null
    ? ""
    : ` The mapped instrument's latest observed move was ${row.marketMovePercent >= 0 ? "+" : ""}${Number(row.marketMovePercent).toFixed(2)}%.`;
  return `This is a newly published political statement.${topics}${market} Any nearby market movement is presented as observed context, not evidence of causation.`;
}

async function marketMoveLookup(db) {
  const result = await db.prepare("SELECT symbol, change_percent FROM market_instruments").all();
  return new Map(result.results.map((row) => [row.symbol, Number(row.change_percent)]));
}

function impactForScore(score) {
  return score >= 0.72 ? "elevated" : score >= 0.48 ? "moderate" : "low";
}

function freshnessForDate(value) {
  const age = Date.now() - new Date(value).valueOf();
  if (!Number.isFinite(age)) return "stale";
  return age <= 15 * 60_000 ? "live" : age <= 24 * 3_600_000 ? "delayed" : "stale";
}

function parseJSON(value, fallback) {
  try { return JSON.parse(value); } catch { return fallback; }
}

async function authorized(request, env) {
  if (!env.SYNC_TOKEN) return false;
  const supplied = request.headers.get("authorization");
  if (!supplied) return false;
  const [expectedHash, suppliedHash] = await Promise.all([
    crypto.subtle.digest("SHA-256", new TextEncoder().encode(`Bearer ${env.SYNC_TOKEN}`)),
    crypto.subtle.digest("SHA-256", new TextEncoder().encode(supplied))
  ]);
  const expected = new Uint8Array(expectedHash);
  const actual = new Uint8Array(suppliedHash);
  let difference = 0;
  for (let index = 0; index < expected.length; index += 1) difference |= expected[index] ^ actual[index];
  return difference === 0;
}

function clamp(value, minimum, maximum) {
  return Math.min(Math.max(value, minimum), maximum);
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
      "referrer-policy": "no-referrer"
    }
  });
}

function settledResponse(results) {
  const sources = results.map((result) => result.status === "fulfilled"
    ? result.value
    : { status: "failed", error: String(result.reason?.message ?? result.reason) });
  return {
    status: results.some((result) =>
      result.status === "rejected" || result.value.status !== "available"
    ) ? "degraded" : "succeeded",
    sources
  };
}

async function readSmallJSON(request) {
  const contentLength = Number(request.headers.get("content-length") ?? 0);
  if (Number.isFinite(contentLength) && contentLength > MAX_INTERNAL_BODY_BYTES) {
    return { error: "request_too_large", status: 413 };
  }
  const text = await request.text();
  if (new TextEncoder().encode(text).byteLength > MAX_INTERNAL_BODY_BYTES) {
    return { error: "request_too_large", status: 413 };
  }
  if (!text.trim()) return { value: {} };
  try {
    const value = JSON.parse(text);
    if (!value || Array.isArray(value) || typeof value !== "object") {
      return { error: "invalid_json_object", status: 400 };
    }
    return { value };
  } catch {
    return { error: "invalid_json", status: 400 };
  }
}

function minimumDate(values) {
  return normalizedDates(values).sort()[0] ?? null;
}

function maximumDate(values) {
  return normalizedDates(values).sort().at(-1) ?? null;
}

function normalizedDates(values) {
  return values
    .map((value) => {
      const date = new Date(value);
      return Number.isNaN(date.valueOf()) ? null : date.toISOString();
    })
    .filter(Boolean);
}

async function executeInChunks(db, statements, size = 50) {
  for (let index = 0; index < statements.length; index += size) {
    await db.batch(statements.slice(index, index + size));
  }
}
