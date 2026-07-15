import { normalizeApifyFiling, normalizeApifyTrade } from "./apify.js";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/health") {
      return json({ status: "ok", provider: "apify", providerConfigured: Boolean(env.APIFY_API_TOKEN) });
    }
    if (request.method === "GET" && url.pathname === "/v1/disclosures") {
      return listDisclosures(url, env);
    }
    if (request.method === "GET" && url.pathname === "/v1/source-filings") {
      return listSourceFilings(url, env);
    }
    if (request.method === "POST" && url.pathname === "/internal/sync") {
      if (!authorized(request, env)) return json({ error: "unauthorized" }, 401);
      return json(await syncApify(env, scheduledInput()));
    }
    if (request.method === "POST" && url.pathname === "/internal/backfill") {
      if (!authorized(request, env)) return json({ error: "unauthorized" }, 401);
      const requested = await request.json().catch(() => ({}));
      return json(await syncApify(env, backfillInput(requested)));
    }
    return json({ error: "not_found" }, 404);
  },

  async scheduled(_controller, env, ctx) {
    ctx.waitUntil(syncApify(env, scheduledInput()));
  }
};

function scheduledInput() {
  return {
    chamber: "both",
    transactionType: "both",
    daysBack: 3,
    dateBasis: "disclosureDate",
    maxResults: 200,
    outputProfile: "full",
    includeAggregates: false,
    includeTrends: false,
    includeEvents: false,
    includeStories: false,
    watchlistName: "consigliere-production",
    newOnly: true,
    saveSourcePdfs: false,
    saveRawText: false,
    proxyConfiguration: { useApifyProxy: true, apifyProxyGroups: ["RESIDENTIAL"] }
  };
}

function backfillInput(value) {
  const daysBack = clamp(Number(value.daysBack) || 730, 1, 730);
  return {
    chamber: ["house", "senate", "both"].includes(value.chamber) ? value.chamber : "both",
    transactionType: "both",
    daysBack,
    fromDate: dateOnly(value.fromDate),
    toDate: dateOnly(value.toDate),
    dateBasis: value.dateBasis === "transactionDate" ? "transactionDate" : "disclosureDate",
    maxResults: clamp(Number(value.maxResults) || 1000, 1, 1000),
    outputProfile: "full",
    includeAggregates: false,
    includeTrends: false,
    includeEvents: false,
    includeStories: false,
    newOnly: false,
    saveSourcePdfs: false,
    saveRawText: false,
    proxyConfiguration: { useApifyProxy: true, apifyProxyGroups: ["RESIDENTIAL"] }
  };
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
           amount_range, transaction_date, report_date, source_url
    FROM disclosures ${where}
    ORDER BY transaction_date DESC, report_date DESC LIMIT ?
  `).bind(...values, limit).all();
  const data = result.results.map((row) => ({
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
    sourceURL: row.source_url
  }));
  return json({ data, meta: { provider: "apify", count: data.length, generatedAt: new Date().toISOString() } });
}

async function listSourceFilings(url, env) {
  const limit = clamp(Number(url.searchParams.get("limit")) || 200, 1, 1000);
  const result = await env.DB.prepare(`
    SELECT id, representative, chamber, disclosure_date, filing_url, doc_id, extraction_status
    FROM source_filings ORDER BY disclosure_date DESC LIMIT ?
  `).bind(limit).all();
  return json({ data: result.results, meta: { provider: "apify", count: result.results.length } });
}

async function syncApify(env, input) {
  if (!env.APIFY_API_TOKEN) throw new Error("APIFY_API_TOKEN is not configured");
  const startedAt = new Date().toISOString();
  const run = await env.DB.prepare(
    "INSERT INTO sync_runs(provider, started_at, status) VALUES ('apify', ?, 'running') RETURNING id"
  ).bind(startedAt).first();
  try {
    const records = await runActor(env, input);
    const observedAt = new Date().toISOString();
    const trades = records.map((row) => normalizeApifyTrade(row, observedAt)).filter(Boolean);
    const filings = records.map((row) => normalizeApifyFiling(row, observedAt)).filter(Boolean);
    for (const trade of trades) await upsertDisclosure(env.DB, trade);
    for (const filing of filings) await upsertSourceFiling(env.DB, filing);

    await env.DB.prepare(
      "UPDATE sync_runs SET finished_at = ?, status = 'succeeded', records_seen = ?, records_written = ? WHERE id = ?"
    ).bind(new Date().toISOString(), records.length, trades.length + filings.length, run.id).run();
    return { status: "succeeded", recordsSeen: records.length, tradesWritten: trades.length, filingsWritten: filings.length };
  } catch (error) {
    await env.DB.prepare(
      "UPDATE sync_runs SET finished_at = ?, status = 'failed', error_message = ? WHERE id = ?"
    ).bind(new Date().toISOString(), String(error?.message ?? error).slice(0, 1000), run.id).run();
    throw error;
  }
}

async function runActor(env, input) {
  const actorID = env.APIFY_ACTOR_ID || "ryanclinton~congress-stock-tracker";
  const baseURL = env.APIFY_BASE_URL || "https://api.apify.com";
  const url = new URL(`/v2/acts/${actorID}/run-sync-get-dataset-items`, baseURL);
  url.searchParams.set("clean", "true");
  url.searchParams.set("format", "json");
  url.searchParams.set("timeout", "300");
  const response = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.APIFY_API_TOKEN}`,
      Accept: "application/json",
      "Content-Type": "application/json"
    },
    body: JSON.stringify(input)
  });
  if (!response.ok) throw new Error(`Apify Actor returned ${response.status}`);
  const payload = await response.json();
  if (!Array.isArray(payload)) throw new Error("Apify Actor returned an unexpected dataset shape");
  const reportedError = payload.find((row) => row?.recordType === "error");
  if (reportedError) throw new Error(`Apify Actor error: ${reportedError.failureType ?? "unknown"}`);
  return payload;
}

async function upsertDisclosure(db, value) {
  return db.prepare(`
    INSERT INTO disclosures(id, provider, politician_id, representative, report_date, transaction_date,
      ticker, asset_name, transaction_type, owner, amount_range, chamber, party, source_url,
      raw_json, observed_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET politician_id=excluded.politician_id, asset_name=excluded.asset_name,
      transaction_type=excluded.transaction_type, owner=excluded.owner, amount_range=excluded.amount_range,
      chamber=excluded.chamber, party=excluded.party, source_url=excluded.source_url,
      raw_json=excluded.raw_json, updated_at=excluded.updated_at
  `).bind(value.id, value.provider, value.politicianID, value.representative, value.reportDate,
    value.transactionDate, value.ticker, value.assetName, value.transactionType, value.owner,
    value.amountRange, value.chamber, value.party, value.sourceURL, value.rawJSON,
    value.observedAt, value.updatedAt).run();
}

async function upsertSourceFiling(db, value) {
  return db.prepare(`
    INSERT INTO source_filings(id, provider, representative, chamber, disclosure_date, filing_url,
      doc_id, extraction_status, raw_json, observed_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET extraction_status=excluded.extraction_status,
      raw_json=excluded.raw_json, updated_at=excluded.updated_at
  `).bind(value.id, value.provider, value.representative, value.chamber, value.disclosureDate,
    value.filingURL, value.docID, value.extractionStatus, value.rawJSON,
    value.observedAt, value.updatedAt).run();
}

function authorized(request, env) {
  return Boolean(env.SYNC_TOKEN) && request.headers.get("authorization") === `Bearer ${env.SYNC_TOKEN}`;
}

function dateOnly(value) {
  return typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value) ? value : undefined;
}

function clamp(value, minimum, maximum) {
  return Math.min(Math.max(value, minimum), maximum);
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" }
  });
}
