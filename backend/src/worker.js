import { syncHouseAnnual } from "./house-annual.js";
import { syncUK, interestRoute, matchUnresolvedInterests } from "./interests.js";
import { researchRoute, rebuildPortfolios, syncStatements, syncSecurityMetadata, syncCommittees, syncServiceDates } from "./research.js";
import {
  collectApifyDisclosures, collectMarketData, collectOfficialFilings, collectTruthPosts, fetchHouseReport
} from "./providers.js";
import {
  HOUSE_PTR_PARSER_VERSION, housePTRDisclosures, isElectronicHouseFiling, readHousePTR
} from "./house-ptr.js";
import {
  rankDisclosure, rankSocialPost, rescoreDisclosure, whyDisclosureMatters
} from "./ranking.js";
import { stableUUID, bulkInsertStatements } from "./normalization.js";
import { createResolver, houseStateDistrict, normalizePersonName, stateCode } from "./identity.js";
import roster from "./roster.js";

const EXPECTED_SOURCES = [
  ["official-disclosures", "Official House disclosure index"],
  ["house-ptr", "House reports read from the Clerk's PDFs"],
  ["house-annual", "House annual asset reports"],
  ["apify", "Structured House and Senate disclosures"],
  ["truth-api", "Truth Social political monitoring"],
  ["twelve-data", "Licensed market data"],
  ["presidential-actions", "White House and Federal Register"],
  ["securities", "SEC company and sector metadata"],
  ["committees", "Congressional committee assignments"],
  ["congress-terms", "Congressional service dates"],
  ["uk-interests", "UK Parliament declared interests"]
];
const MAX_INTERNAL_BODY_BYTES = 4096;
const SYNC_LOCK_MS = 15 * 60_000;
const BACKFILL_LEASE_MS = 2 * 3_600_000;
const BACKFILL_CRON = "15 * * * *";
const HOUSE_PTR_CRON = "45 * * * *";
const HOUSE_PTR_BATCH = 30;
const HOUSE_PTR_BUDGET_MS = 90_000;
const HOUSE_PTR_LEASE_MS = 3_600_000;
const HOUSE_PTR_MAX_ATTEMPTS = 3;
const DAY_MS = 86_400_000;
const SNAPSHOT_RECENT_DAYS = 30;
const RERANK_RECENT_DAYS = 60;
const PENDING_FILING_DAYS = 45;
const ISO_DAY = /^\d{4}-\d{2}-\d{2}$/;
const WORKER_VERSION = "2026-10-06-research-v1";
const DISCLOSURE_COLUMNS = `
  id, politician_id, representative, ticker, asset_name, transaction_type, owner,
  amount_range, transaction_date, report_date, source_url, chamber, confidence,
  ranking_score, ranking_reasons, why_it_matters, party, state, district,
  match_confidence, observed_at, asset_type, description
`;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const interest = await interestRoute(request, env);
    if (interest) return interest;
    const research = await researchRoute(request, env, mapDisclosure);
    if (research) return research;
    if (request.method === "GET" && url.pathname === "/health") return health(env);
    if (request.method === "GET" && url.pathname === "/v1/snapshot") return snapshot(env);
    if (request.method === "GET" && url.pathname === "/v1/disclosures") return listDisclosures(url, env);
    if (request.method === "GET" && url.pathname === "/v1/intelligence") return listIntelligence(url, env);
    if (request.method === "GET" && url.pathname === "/v1/source-filings") return listSourceFilings(url, env);
    if (request.method === "POST" && url.pathname === "/internal/sync") {
      if (!await authorized(request, env)) return json({ error: "unauthorized" }, 401);
      return json(await runScheduled(env));
    }
    if (request.method === "GET" && url.pathname === "/internal/review") {
      if (!await authorized(request, env)) return json({ error: "unauthorized" },401);
      const [interests, corrections] = await Promise.all([
        env.DB.prepare("SELECT id,organisation,candidate_matches,source_url FROM interest_records WHERE review_status='needs-review'").all(),
        env.DB.prepare("SELECT * FROM statement_corrections WHERE status='pending'").all()
      ]);
      return json({ interests: interests.results, corrections: corrections.results });
    }
    if (request.method === "POST" && url.pathname === "/internal/rematch") {
      if (!await authorized(request, env)) return json({ error: "unauthorized" }, 401);
      const bodyResult = await readSmallJSON(request);
      if (bodyResult.error) return json({ error: bodyResult.error }, bodyResult.status);
      return json(await rematchDisclosures(env, {
        retryUnmatched: bodyResult.value.retryUnmatched === true,
        afterID: typeof bodyResult.value.afterID === "string" ? bodyResult.value.afterID : "",
        limit: clamp(Number(bodyResult.value.limit) || 1000, 1, 2000)
      }));
    }
    if (request.method === "POST" && url.pathname === "/internal/rerank") {
      if (!await authorized(request, env)) return json({ error: "unauthorized" }, 401);
      const bodyResult = await readSmallJSON(request);
      if (bodyResult.error) return json({ error: bodyResult.error }, bodyResult.status);
      return json(await rerankDisclosures(env, {
        since: bodyResult.value.all === true ? null : daysAgo(RERANK_RECENT_DAYS),
        afterID: typeof bodyResult.value.afterID === "string" ? bodyResult.value.afterID : "",
        limit: clamp(Number(bodyResult.value.limit) || 1000, 1, 2000)
      }));
    }
    if (request.method === "POST" && url.pathname === "/internal/backfill") {
      if (!await authorized(request, env)) return json({ error: "unauthorized" }, 401);
      const bodyResult = await readSmallJSON(request);
      if (bodyResult.error) return json({ error: bodyResult.error }, bodyResult.status);
      const body = bodyResult.value;
      const currentYear = new Date().getUTCFullYear();
      const startYear = Number(body.startYear ?? body.year ?? 2012);
      const endYear = Number(body.endYear ?? body.year ?? currentYear);
      if (
        !Number.isInteger(startYear) || !Number.isInteger(endYear)
        || startYear < 2012 || endYear > currentYear || startYear > endYear
      ) {
        return json({ error: "invalid_year_range", minimum: 2012, maximum: currentYear }, 400);
      }
      return json(await enqueueBackfill(env, startYear, endYear, body.chamber));
    }
    if (request.method === "POST" && url.pathname === "/internal/backfill/run-next") {
      if (!await authorized(request, env)) return json({ error: "unauthorized" }, 401);
      return json(await processNextBackfillJob(env));
    }
    if (request.method === "POST" && url.pathname === "/internal/backfill/reconcile") {
      if (!await authorized(request, env)) return json({ error: "unauthorized" }, 401);
      const bodyResult = await readSmallJSON(request);
      if (bodyResult.error) return json({ error: bodyResult.error }, bodyResult.status);
      const runID = String(bodyResult.value.runID ?? "").trim();
      if (!/^[A-Za-z0-9]{10,40}$/.test(runID)) return json({ error: "invalid_run_id" }, 400);
      // The run must be tied to an explicit job; guessing one would file another year's records under it.
      const year = Number(bodyResult.value.year);
      const chamber = bodyResult.value.chamber;
      if (!Number.isInteger(year) || (chamber !== "house" && chamber !== "senate")) {
        return json({ error: "year_and_chamber_required" }, 400);
      }
      const offset = clamp(Number(bodyResult.value.offset) || 0, 0, 1_000_000);
      const limit = clamp(Number(bodyResult.value.limit) || 25, 1, 100);
      return json(await reconcileBackfillJob(env, { runID, year, chamber, offset, limit }));
    }
    return json({ error: "not_found" }, 404);
  },

  async scheduled(controller, env, ctx) {
    const run = controller.cron === BACKFILL_CRON ? runBackfillSchedule
      : controller.cron === HOUSE_PTR_CRON ? runHouseSchedule
      : runScheduled;
    ctx.waitUntil(run(env));
  }
};

async function runHouseSchedule(env) {
  const transactions = await extractHouseReports(env);
  const annuals = await withHealth(env,"house-annual","House annual asset reports",()=>syncHouseAnnual(env,{refreshIndex:false}));
  if (annuals.recordsWritten) await rebuildPortfolios(env.DB);
  return { transactions, annuals };
}

async function runScheduled(env) {
  await syncRoster(env);
  const live = await syncAll(env);
  const rerank = await rerankRecentDisclosures(env);
  const rematch = await rematchDisclosures(env);
  const securityMatching = await withHealth(env, "security-matching", "Listed-security matching", () => matchUnresolvedInterests(env));
  const portfolios = await rebuildPortfolios(env.DB);
  return { ...live, rerank, rematch, securityMatching, portfolios };
}

// Hourly: drains queued historical years (idle when the queue is empty) and matches new filers.
async function runBackfillSchedule(env) {
  const backfill = await processNextBackfillJob(env);
  const rematch = await rematchDisclosures(env);
  const securityMatching = await withHealth(env, "security-matching", "Listed-security matching", () => matchUnresolvedInterests(env));
  return { backfill, rematch, securityMatching };
}

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
  const now = new Date();
  const postColumns = `
    id, author, body, source_url, published_at, retrieved_at, edited_at, deleted_at,
    policy_topics, mentioned_symbols, confidence, ranking_score, ranking_reasons, why_it_matters
  `;
  // Stored scores were computed at ingestion. Candidates are every recent record plus the
  // stored leaders, and all of them are re-scored against the current time below.
  const [
    instruments, recentDisclosures, leadingDisclosures, recentPosts, leadingPosts,
    healthRows, coverage, summaries, unmatched, pending
  ] = await Promise.all([
    env.DB.prepare(`
      SELECT symbol, name, exchange_name, currency, region, instrument_kind, price,
             change_percent, updated_at, sector, provider, attribution
      FROM market_instruments ORDER BY symbol
    `).all(),
    env.DB.prepare(`
      SELECT ${DISCLOSURE_COLUMNS} FROM disclosures
      WHERE report_date >= ? AND suppressed_by IS NULL ORDER BY report_date DESC LIMIT 2000
    `).bind(daysAgo(SNAPSHOT_RECENT_DAYS, now)).all(),
    env.DB.prepare(`
      SELECT ${DISCLOSURE_COLUMNS} FROM disclosures
      WHERE ranking_score > 0 AND suppressed_by IS NULL
      ORDER BY ranking_score DESC, report_date DESC LIMIT 250
    `).all(),
    env.DB.prepare(`
      SELECT ${postColumns} FROM social_posts
      WHERE deleted_at IS NULL AND published_at >= ? ORDER BY published_at DESC LIMIT 500
    `).bind(new Date(now.valueOf() - 7 * DAY_MS).toISOString()).all(),
    env.DB.prepare(`
      SELECT ${postColumns} FROM social_posts WHERE deleted_at IS NULL
      ORDER BY ranking_score DESC, published_at DESC LIMIT 100
    `).all(),
    env.DB.prepare(`
      SELECT provider, display_name, status, last_attempt_at, last_success_at,
             records_seen, message, coverage_start, coverage_end
      FROM source_health ORDER BY provider
    `).all(),
    disclosureCoverage(env),
    env.DB.prepare(`
      SELECT politician_id, COUNT(*) AS records, MIN(report_date) AS earliest,
             MAX(report_date) AS latest
      FROM disclosures WHERE politician_id IS NOT NULL AND suppressed_by IS NULL GROUP BY politician_id
    `).all(),
    env.DB.prepare(`
      SELECT representative, chamber, COUNT(*) AS records, MAX(report_date) AS latest
      FROM disclosures WHERE politician_id IS NULL AND suppressed_by IS NULL
      GROUP BY representative, chamber ORDER BY records DESC LIMIT 100
    `).all(),
    env.DB.prepare(`
      SELECT sf.id, sf.representative, sf.chamber, sf.disclosure_date, sf.filing_url, sf.doc_id, sf.raw_json
      FROM source_filings sf
      WHERE sf.provider = 'house' AND sf.disclosure_date >= ?
        AND NOT EXISTS (
          SELECT 1 FROM source_filings extracted
          WHERE extracted.provider = 'apify' AND extracted.doc_id = sf.doc_id || '.pdf'
        )
        ${housePTRMode(env) === "live" ? `AND NOT EXISTS (
          SELECT 1 FROM house_ptr_extractions x
          WHERE x.doc_id = sf.doc_id AND x.status IN ('extracted', 'empty')
        )` : ""}
      ORDER BY sf.disclosure_date DESC LIMIT 100
    `).bind(daysAgo(PENDING_FILING_DAYS, now)).all()
  ]);

  const moves = marketMoves(instruments.results);
  const disclosureData = topByScore(
    uniqueByID([...recentDisclosures.results, ...leadingDisclosures.results])
      .map((row) => rescoredDisclosure(mapDisclosure(row), moves, now)),
    250
  );
  const postData = topByScore(
    uniqueByID([...recentPosts.results, ...leadingPosts.results])
      .map((row) => rescoredSocialItem(mapSocialIntelligenceItem(row), moves, now)),
    100
  );
  const intelligence = [
    ...disclosureData.map(disclosureIntelligenceItem),
    ...postData
  ].sort((a, b) => b.rankingScore - a.rankingScore || b.publishedAt.localeCompare(a.publishedAt));

  return json({
    data: {
      instruments: instruments.results.map(mapInstrument),
      intelligence,
      disclosures: disclosureData,
      sourceHealth: mergeSourceHealth(healthRows.results),
      coverage,
      politicianSummaries: summaries.results.map((row) => ({
        politicianID: row.politician_id,
        records: row.records,
        earliest: row.earliest,
        latest: row.latest
      })),
      unmatchedFilers: unmatched.results.map((row) => ({
        representative: row.representative,
        chamber: row.chamber,
        records: row.records,
        latest: row.latest
      })),
      pendingFilings: pendingFilingItems(pending.results)
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
  const suppliedID = url.searchParams.get("politician_id");
  const politicianID = suppliedID && !suppliedID.includes(":") ? `us:${suppliedID}` : suppliedID;
  const ticker = url.searchParams.get("ticker")?.toUpperCase();
  const from = url.searchParams.get("from");
  const to = url.searchParams.get("to");
  const representative = url.searchParams.get("representative")?.trim();
  const chamber = url.searchParams.get("chamber")?.toLowerCase();
  const dateBasis = url.searchParams.get("date_basis") === "filed" ? "report_date" : "transaction_date";
  const cursorDate = url.searchParams.get("cursor_date");
  const cursorID = url.searchParams.get("cursor_id");
  const limit = clamp(Number(url.searchParams.get("limit")) || 100, 1, 500);
  for (const value of [from, to, cursorDate]) {
    if (value && !ISO_DAY.test(value)) return json({ error: "invalid_date", expected: "YYYY-MM-DD" }, 400);
  }
  if (Boolean(cursorDate) !== Boolean(cursorID)) return json({ error: "invalid_cursor" }, 400);
  const clauses = ["suppressed_by IS NULL"];
  const values = [];
  if (politicianID) { clauses.push("politician_id = ?"); values.push(politicianID); }
  if (ticker) { clauses.push("ticker = ?"); values.push(ticker); }
  if (representative) {
    clauses.push("LOWER(representative) LIKE ? ESCAPE '\\'");
    values.push(`%${representative.toLowerCase().replaceAll("\\", "\\\\").replaceAll("%", "\\%").replaceAll("_", "\\_")}%`);
  }
  if (chamber === "house" || chamber === "senate") {
    clauses.push("chamber = ?");
    values.push(chamber);
  }
  if (from) { clauses.push(`${dateBasis} >= ?`); values.push(from); }
  if (to) { clauses.push(`${dateBasis} <= ?`); values.push(to); }
  if (cursorDate && cursorID) {
    clauses.push(`(${dateBasis} < ? OR (${dateBasis} = ? AND id < ?))`);
    values.push(cursorDate, cursorDate, cursorID);
  }
  const where = `WHERE ${clauses.join(" AND ")}`;
  const [result, instruments] = await Promise.all([
    env.DB.prepare(`
      SELECT ${DISCLOSURE_COLUMNS}
      FROM disclosures ${where}
      ORDER BY ${dateBasis} DESC, id DESC LIMIT ?
    `).bind(...values, limit).all(),
    env.DB.prepare("SELECT symbol, change_percent FROM market_instruments").all()
  ]);
  const now = new Date();
  const moves = marketMoves(instruments.results);
  const data = result.results.map((row) => rescoredDisclosure(mapDisclosure(row), moves, now));
  const last = result.results.at(-1);
  return json({
    data,
    meta: {
      count: data.length,
      generatedAt: new Date().toISOString(),
      nextCursor: data.length === limit && last
        ? { date: last[dateBasis], id: last.id }
        : null
    }
  });
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
  const initial = await Promise.allSettled([syncMarkets(env), syncOfficial(env)]);
  const remaining = await Promise.allSettled([
    syncRoutineApify(env),
    syncTruth(env),
    withHealth(env, "securities", "SEC company and sector metadata", () => syncSecurityMetadata(env)),
    withHealth(env, "uk-interests", "UK Parliament declared interests", () => syncUK(env)),
    withHealth(env, "committees", "Congressional committee assignments", () => syncCommittees(env)),
    withHealth(env, "congress-terms", "Congressional service dates", () => syncServiceDates(env)),
    withHealth(env, "house-annual", "House annual asset reports", () => syncHouseAnnual(env))
  ]);
  const statements = await Promise.allSettled([withHealth(env, "presidential-actions", "White House and Federal Register", () => syncStatements(env))]);
  const settled = [...initial, ...remaining, ...statements];
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

async function enqueueBackfill(env, startYear, endYear, requestedChamber) {
  const chambers = requestedChamber === "house" || requestedChamber === "senate"
    ? [requestedChamber]
    : ["house", "senate"];
  const now = new Date().toISOString();
  const statements = [];
  for (let year = startYear; year <= endYear; year += 1) {
    for (const chamber of chambers) {
      statements.push(env.DB.prepare(`
        INSERT INTO disclosure_backfill_jobs(filing_year, chamber, status, created_at)
        VALUES (?, ?, 'pending', ?)
        ON CONFLICT(filing_year, chamber) DO UPDATE SET
          status=CASE
            WHEN disclosure_backfill_jobs.status IN ('completed', 'running') THEN disclosure_backfill_jobs.status
            ELSE 'pending'
          END,
          attempts=CASE
            WHEN disclosure_backfill_jobs.status IN ('completed', 'running') THEN disclosure_backfill_jobs.attempts
            ELSE 0
          END,
          last_error=NULL
      `).bind(year, chamber, now));
    }
  }
  await executeInChunks(env.DB, statements);
  return { status: "queued", startYear, endYear, chambers, jobs: statements.length };
}

async function processNextBackfillJob(env) {
  const claimedAt = new Date().toISOString();
  // A job left "running" past its lease was interrupted (Worker timeout or crash) and is reclaimable.
  const leaseExpiredBefore = new Date(Date.now() - BACKFILL_LEASE_MS).toISOString();
  const candidate = await env.DB.prepare(`
    SELECT id, filing_year, chamber FROM disclosure_backfill_jobs
    WHERE (status IN ('pending', 'failed') AND attempts < 3)
       OR (status = 'running' AND started_at < ?)
    ORDER BY filing_year DESC, chamber LIMIT 1
  `).bind(leaseExpiredBefore).first();
  if (!candidate) return { status: "idle" };
  const claim = await env.DB.prepare(`
    UPDATE disclosure_backfill_jobs
    SET status='running', attempts=attempts+1, started_at=?, last_error=NULL
    WHERE id=? AND (status IN ('pending', 'failed') OR (status = 'running' AND started_at < ?))
  `).bind(claimedAt, candidate.id, leaseExpiredBefore).run();
  if (Number(claim.meta?.changes ?? 0) === 0) return { status: "skipped" };
  try {
    const result = await syncApify(env, {
      filingYear: candidate.filing_year,
      chamber: candidate.chamber,
      maxResults: 1_000
    }, backfillProvider(candidate));
    const deferral = backfillDeferral(result);
    if (deferral) {
      // Nothing was attempted, so the job keeps its place and does not spend an attempt.
      await env.DB.prepare(`
        UPDATE disclosure_backfill_jobs
        SET status='pending', attempts=MAX(attempts-1, 0), started_at=NULL, last_error=? WHERE id=?
      `).bind(deferral, candidate.id).run();
      return { status: "deferred", year: candidate.filing_year, chamber: candidate.chamber, message: deferral };
    }
    await env.DB.prepare(`
      UPDATE disclosure_backfill_jobs SET status='completed', finished_at=?,
        records_seen=?, records_written=? WHERE id=?
    `).bind(
      new Date().toISOString(), result.recordsSeen ?? 0, result.recordsWritten ?? 0, candidate.id
    ).run();
    return { status: "completed", year: candidate.filing_year, chamber: candidate.chamber, result };
  } catch (error) {
    const message = String(error?.message ?? error).slice(0, 1000);
    await env.DB.prepare(`
      UPDATE disclosure_backfill_jobs SET status='failed', finished_at=?, last_error=? WHERE id=?
    `).bind(new Date().toISOString(), message, candidate.id).run();
    return { status: "failed", year: candidate.filing_year, chamber: candidate.chamber, error: message };
  }
}

export function backfillDeferral(result) {
  if (result?.status === "skipped") return result.message ?? "Sync already running";
  if (result?.status === "unconfigured") return result.message ?? "Not configured";
  return null;
}

function backfillProvider(job) {
  return `apify-backfill-${job.filing_year}-${job.chamber}`;
}

async function reconcileBackfillJob(env, { runID, year, chamber, offset, limit }) {
  const candidate = await env.DB.prepare(`
    SELECT id, filing_year, chamber, status FROM disclosure_backfill_jobs
    WHERE filing_year = ? AND chamber = ?
  `).bind(year, chamber).first();
  if (!candidate) return { status: "not_found", message: "Enqueue this year and chamber first" };
  if (candidate.status === "completed") return { status: "completed", message: "Job already completed" };
  try {
    const result = await syncApify(env, {
      runID,
      filingYear: candidate.filing_year,
      chamber: candidate.chamber,
      datasetOffset: offset,
      datasetLimit: limit
    }, backfillProvider(candidate));
    const deferral = backfillDeferral(result);
    if (deferral) {
      return { status: "deferred", year: candidate.filing_year, chamber: candidate.chamber, message: deferral };
    }
    const completed = (result.itemsSeen ?? 0) < limit;
    // Each page renews the lease so the hourly runner does not reclaim a job mid-reconciliation.
    await env.DB.prepare(`
      UPDATE disclosure_backfill_jobs SET status=?, started_at=?, finished_at=?,
        records_seen=records_seen+?, records_written=records_written+?, last_error=NULL WHERE id=?
    `).bind(
      completed ? "completed" : "running",
      new Date().toISOString(),
      completed ? new Date().toISOString() : null,
      result.recordsSeen ?? 0,
      result.recordsWritten ?? 0,
      candidate.id
    ).run();
    return {
      status: completed ? "completed" : "page-completed",
      year: candidate.filing_year,
      chamber: candidate.chamber,
      offset,
      nextOffset: completed ? null : offset + limit,
      result
    };
  } catch (error) {
    const message = String(error?.message ?? error).slice(0, 1000);
    await env.DB.prepare(`
      UPDATE disclosure_backfill_jobs SET status='failed', finished_at=?, last_error=? WHERE id=?
    `).bind(new Date().toISOString(), message, candidate.id).run();
    return { status: "failed", year: candidate.filing_year, chamber: candidate.chamber, error: message };
  }
}

async function syncRoster(env) {
  const version = stableUUID(JSON.stringify(roster));
  const current = await env.DB.prepare("SELECT value FROM app_metadata WHERE key = 'roster_version'").first();
  if (current?.value === version) return { status: "unchanged", members: roster.length };
  const now = new Date().toISOString();
  const statements=bulkInsertStatements(env.DB,"politicians",["bioguide_id","name","normalized_name","party","chamber","state","state_code","district","image_url","service_start","updated_at","source_id","legislature","photo_source"],roster.map(p=>[p.id,p.name,normalizePersonName(p.name),p.party,p.chamber,p.state,stateCode(p.state),p.district??null,p.imageURL??null,p.serviceStart??null,now,p.sourceID,"Congress","Congress.gov"]),
    "ON CONFLICT(bioguide_id) DO UPDATE SET name=excluded.name,normalized_name=excluded.normalized_name,party=excluded.party,chamber=excluded.chamber,state=excluded.state,state_code=excluded.state_code,district=excluded.district,image_url=excluded.image_url,service_start=excluded.service_start,updated_at=excluded.updated_at,source_id=excluded.source_id");
  statements.push(env.DB.prepare(`
    INSERT INTO app_metadata(key, value, updated_at) VALUES ('roster_version', ?, ?)
    ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at
  `).bind(version, now));
  await executeInChunks(env.DB, statements);
  return { status: "updated", members: roster.length };
}

// Assigns bioguide IDs to stored disclosures. Unmatched rows are marked with confidence 0 so
// routine runs skip them; retryUnmatched revisits them after a roster refresh.
async function rematchDisclosures(env, { retryUnmatched = false, afterID = "", limit = 1000 } = {}) {
  await syncRoster(env);
  const result = await env.DB.prepare(`
    SELECT id, representative, chamber, state, district, party FROM disclosures
    WHERE politician_id IS NULL AND ${retryUnmatched ? "match_confidence = 0" : "match_confidence IS NULL"}
      AND id > ?
    ORDER BY id LIMIT ?
  `).bind(afterID, limit).all();
  const resolve = createResolver(roster);
  let matched = 0;
  const updates = result.results.map((row) => {
    const match = resolve({
      name: row.representative, chamber: row.chamber, state: row.state,
      district: row.district, party: row.party
    });
    if (match) matched += 1;
    return [row.id, match?.id ?? null, match?.confidence ?? 0];
  });
  if (updates.length) await env.DB.prepare(`
    WITH updates AS (SELECT json_extract(value,'$[0]') AS id,
      json_extract(value,'$[1]') AS politician_id, json_extract(value,'$[2]') AS confidence FROM json_each(?))
    UPDATE disclosures SET (politician_id,match_confidence) =
      (SELECT politician_id,confidence FROM updates WHERE updates.id=disclosures.id)
    WHERE id IN (SELECT id FROM updates)
  `).bind(JSON.stringify(updates)).run();
  const last = result.results.at(-1);
  return {
    status: "completed",
    examined: result.results.length,
    matched,
    nextAfterID: result.results.length === limit && last ? last.id : null
  };
}

async function rerankDisclosures(env, { since = null, afterID = "", limit = 1000 } = {}) {
  const [result, moves] = await Promise.all([
    env.DB.prepare(`
      SELECT ${DISCLOSURE_COLUMNS} FROM disclosures
      WHERE id > ? ${since ? "AND report_date >= ?" : ""}
      ORDER BY id LIMIT ?
    `).bind(...(since ? [afterID, since, limit] : [afterID, limit])).all(),
    marketMoveLookup(env.DB)
  ]);
  const now = new Date();
  const updates = result.results.map((row) => {
    const record = rescoredDisclosure(mapDisclosure(row), moves, now);
    return [row.id, record.rankingScore, JSON.stringify(record.rankingReasons), record.whyItMatters];
  });
  if (updates.length) await env.DB.prepare(`
    WITH updates AS (SELECT json_extract(value,'$[0]') AS id,
      json_extract(value,'$[1]') AS score, json_extract(value,'$[2]') AS reasons,
      json_extract(value,'$[3]') AS explanation FROM json_each(?))
    UPDATE disclosures SET (ranking_score,ranking_reasons,why_it_matters) =
      (SELECT score,reasons,explanation FROM updates WHERE updates.id=disclosures.id)
    WHERE id IN (SELECT id FROM updates)
  `).bind(JSON.stringify(updates)).run();
  const last = result.results.at(-1);
  return {
    status: "completed",
    updated: updates.length,
    nextAfterID: result.results.length === limit && last ? last.id : null
  };
}

async function rerankRecentDisclosures(env) {
  const since = daysAgo(RERANK_RECENT_DAYS);
  let afterID = "";
  let updated = 0;
  for (let page = 0; page < 5; page += 1) {
    const result = await rerankDisclosures(env, { since, afterID, limit: 1000 });
    updated += result.updated;
    if (!result.nextAfterID) break;
    afterID = result.nextAfterID;
  }
  return { status: "completed", updated };
}

async function syncOfficial(env, year = new Date().getUTCFullYear()) {
  return withHealth(env, "official-disclosures", "Official House disclosure index", async () => {
    const { filings, failures } = await collectOfficialFilings(env, year);
    const now = new Date().toISOString();
    const statements=bulkInsertStatements(env.DB,"source_filings",["id","provider","representative","chamber","disclosure_date","filing_url","doc_id","extraction_status","raw_json","observed_at","updated_at"],filings.map(f=>[f.id,f.provider,f.representative,f.chamber,f.disclosureDate,f.filingURL,f.docID,f.extractionStatus,f.rawJSON,now,now]),
      "ON CONFLICT(id) DO UPDATE SET extraction_status=excluded.extraction_status,raw_json=excluded.raw_json,updated_at=excluded.updated_at");
    if(statements.length)await env.DB.batch(statements);
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

async function syncRoutineApify(env) {
  if (housePTRMode(env) !== "live") return syncApify(env);
  const index = await env.DB.prepare("SELECT status, last_success_at FROM source_health WHERE provider='official-disclosures'").first();
  if (index?.status !== "available" || !index.last_success_at) return syncApify(env);
  const pending = await env.DB.prepare(`
    SELECT COUNT(*) AS count FROM source_filings sf
    LEFT JOIN house_ptr_extractions x ON sf.doc_id = x.doc_id
    WHERE sf.provider = 'house' AND sf.filing_url LIKE ?
      AND (x.doc_id IS NULL OR x.status NOT IN ('extracted','empty','paper')
        OR x.parser_version < ?)
  `).bind(`%/${new Date().getUTCFullYear()}/%`, HOUSE_PTR_PARSER_VERSION).first();
  return syncApify(env, Number(pending?.count ?? 0) === 0 ? { chamber: "senate" } : {});
}

async function syncApify(env, input = {}, provider = "apify") {
  const options = { recordHealth: provider === "apify" };
  return withHealth(env, provider, "Structured House and Senate disclosures", async () => {
    if (!env.APIFY_API_TOKEN) return { recordsSeen: 0, message: "Not configured" };
    const { filings, disclosures, itemsSeen } = await collectApifyDisclosures(env, input);
    const now = new Date().toISOString();
    // Politician IDs reference the politicians table, so the roster must exist before writes.
    await syncRoster(env);
    const resolve = createResolver(roster);
    const marketMoves = await marketMoveLookup(env.DB);
    const disclosureStatements = disclosures.map((record) => {
      const match = resolve({
        name: record.representative, chamber: record.chamber, state: record.state,
        district: record.district, party: record.party
      });
      const enriched = {
        ...record,
        politicianID: match?.id ?? null,
        matchConfidence: match?.confidence ?? 0,
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
    await applyHousePTRMode(env);
    return {
      recordsSeen: filings.length,
      recordsWritten: disclosures.length + filings.length,
      itemsSeen: itemsSeen ?? filings.length,
      coverageStart: minimumDate(filings.map((item) => item.disclosureDate)),
      coverageEnd: maximumDate(filings.map((item) => item.disclosureDate)),
      message: filings.length ? null : "No filings returned by Apify"
    };
  }, options);
}

// Hourly: reads House reports straight from the Clerk's PDFs. In "shadow" mode the rows are stored
// but held back for comparison with Apify's; in "live" mode they replace Apify's rows report by
// report. Scanned paper reports have no text layer and are only recorded.
async function extractHouseReports(env) {
  const mode = housePTRMode(env);
  if (mode === "off") return { status: "disabled" };
  return withHealth(env, "house-ptr", "House reports read from the Clerk's PDFs", async () => {
    const started = Date.now();
    const leaseExpiredBefore = new Date(started - HOUSE_PTR_LEASE_MS).toISOString();
    const candidates = await env.DB.prepare(`
      SELECT sf.doc_id, sf.filing_url, sf.disclosure_date, sf.representative, sf.raw_json, COALESCE(x.attempts, 0) AS attempts
      FROM source_filings sf
      LEFT JOIN house_ptr_extractions x ON x.doc_id = sf.doc_id
      WHERE sf.provider = 'house' AND (
        x.doc_id IS NULL
        OR (x.status IN ('extracted', 'empty', 'needs-review') AND x.parser_version < ?)
        OR (x.status = 'failed' AND x.attempts < ?)
        OR (x.status = 'running' AND x.claimed_at < ? AND x.attempts < ?)
      )
      ORDER BY sf.disclosure_date DESC, sf.doc_id DESC LIMIT ?
    `).bind(
      HOUSE_PTR_PARSER_VERSION, HOUSE_PTR_MAX_ATTEMPTS, leaseExpiredBefore, HOUSE_PTR_MAX_ATTEMPTS,
      clamp(Number(env.HOUSE_PTR_BATCH) || HOUSE_PTR_BATCH, 1, 100)
    ).all();
    // Politician IDs reference the politicians table, so the roster must exist before writes.
    await syncRoster(env);
    const context = { resolve: createResolver(roster), moves: await marketMoveLookup(env.DB), mode };
    const counts = { extracted: 0, empty: 0, "needs-review": 0, failed: 0, paper: 0 };
    let rowsWritten = 0;
    let examined = 0;
    for (const filing of candidates.results) {
      if (Date.now() - started > HOUSE_PTR_BUDGET_MS) break;
      examined += 1;
      if (!isElectronicHouseFiling(filing.doc_id)) {
        await recordHouseExtraction(env.DB, filing, { status: "paper" });
        counts.paper += 1;
        continue;
      }
      await claimHouseExtraction(env.DB, filing);
      try {
        const parsed = await readHousePTR(await fetchHouseReport(env, filing.filing_url));
        const warnings = [...parsed.warnings];
        if (parsed.filingID !== filing.doc_id) warnings.unshift(`report is filing ${parsed.filingID ?? "unknown"}`);
        // A report that did not read cleanly keeps its Apify rows rather than serving a partial copy.
        const status = warnings.length ? "needs-review" : parsed.transactions.length ? "extracted" : "empty";
        const rows = status === "extracted" ? housePTRDisclosures(parsed, {
          docID: filing.doc_id, disclosureDate: filing.disclosure_date, filingURL: filing.filing_url,
          representative: filing.representative, rawJSON: filing.raw_json
        }) : [];
        await writeHouseReport(env, filing, rows, {
          status, transactions: rows.length, warnings: warnings.length ? JSON.stringify(warnings.slice(0, 20)) : null
        }, context);
        counts[status] += 1;
        rowsWritten += rows.length;
      } catch (error) {
        const message = String(error?.message ?? error).slice(0, 500);
        await recordHouseExtraction(env.DB, filing, { status: "failed", error: message });
        counts.failed += 1;
      }
    }
    await applyHousePTRMode(env, mode);
    const exhausted = await env.DB.prepare("SELECT doc_id, error FROM house_ptr_extractions WHERE status = 'failed' AND attempts >= ? AND parser_version = ?").bind(HOUSE_PTR_MAX_ATTEMPTS, HOUSE_PTR_PARSER_VERSION).all();
    const dates = candidates.results.slice(0, examined).map((filing) => filing.disclosure_date);
    return {
      recordsSeen: examined,
      recordsWritten: rowsWritten,
      mode,
      ...counts,
      coverageStart: minimumDate(dates),
      coverageEnd: maximumDate(dates),
      message: exhausted.results.length ? `${exhausted.results.length} report(s) failed after three attempts: ${exhausted.results.slice(0, 3).map((row) => `${row.doc_id}: ${row.error}`).join("; ")}` : null
    };
  });
}

function housePTRMode(env) {
  const mode = String(env.HOUSE_PTR_MODE ?? "shadow").trim().toLowerCase();
  return ["off", "shadow", "live"].includes(mode) ? mode : "shadow";
}

// Brings every stored row in line with the current mode, so switching modes takes effect on the
// next run without a migration. Apify writes run this too, so re-fetched rows stay replaced.
// In live mode Apify's rows for a report are held back exactly when extractor rows exist for it.
async function applyHousePTRMode(env, mode = housePTRMode(env)) {
  const live = mode === "live";
  const replaced = "SELECT source_url FROM disclosures WHERE provider = 'house-ptr' AND source_url IS NOT NULL";
  await env.DB.batch([
    env.DB.prepare(`
      UPDATE disclosures SET suppressed_by = ? WHERE provider = 'house-ptr' AND suppressed_by IS ?
    `).bind(live ? null : "shadow", live ? "shadow" : null),
    env.DB.prepare(`
      UPDATE disclosures SET suppressed_by = NULL WHERE provider = 'apify' AND suppressed_by = 'house-ptr'
      ${live ? `AND source_url NOT IN (${replaced})` : ""}
    `),
    ...(live ? [env.DB.prepare(`
      UPDATE disclosures SET suppressed_by = 'house-ptr'
      WHERE provider = 'apify' AND suppressed_by IS NULL AND source_url IN (${replaced})
    `)] : [])
  ]);
}

async function claimHouseExtraction(db, filing) {
  await db.prepare(`
    INSERT INTO house_ptr_extractions(doc_id, filing_url, disclosure_date, status, parser_version, attempts, claimed_at)
    VALUES (?, ?, ?, 'running', ?, 1, ?)
    ON CONFLICT(doc_id) DO UPDATE SET status='running', claimed_at=excluded.claimed_at,
      attempts=CASE WHEN house_ptr_extractions.parser_version < excluded.parser_version THEN 1
        ELSE house_ptr_extractions.attempts + 1 END,
      parser_version=excluded.parser_version
  `).bind(
    filing.doc_id, filing.filing_url, filing.disclosure_date, HOUSE_PTR_PARSER_VERSION, new Date().toISOString()
  ).run();
}

function houseExtractionStatement(db, filing, { status, transactions = 0, warnings = null, error = null }) {
  return db.prepare(`
    INSERT INTO house_ptr_extractions(doc_id, filing_url, disclosure_date, status, parser_version,
      transactions, warnings, error, extracted_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(doc_id) DO UPDATE SET status=excluded.status, parser_version=excluded.parser_version,
      transactions=excluded.transactions, warnings=excluded.warnings, error=excluded.error,
      extracted_at=excluded.extracted_at
  `).bind(
    filing.doc_id, filing.filing_url, filing.disclosure_date, status, HOUSE_PTR_PARSER_VERSION,
    transactions, warnings, error, new Date().toISOString()
  );
}

async function recordHouseExtraction(db, filing, result) {
  await houseExtractionStatement(db, filing, result).run();
}

// Replaces the report's earlier extractor rows; a report that no longer reads cleanly keeps none,
// so its Apify rows are served again. Rows keep the first time any provider stored the report, so
// switching providers does not make old filings look new in the app.
async function writeHouseReport(env, filing, rows, result, { resolve, moves, mode }) {
  const now = new Date().toISOString();
  const firstSeen = rows.length ? await env.DB.prepare(
    "SELECT MIN(observed_at) AS observed_at FROM disclosures WHERE source_url = ?"
  ).bind(filing.filing_url).first() : null;
  const statements = [
    houseExtractionStatement(env.DB, filing, result),
    env.DB.prepare("DELETE FROM disclosures WHERE provider = 'house-ptr' AND source_url = ?").bind(filing.filing_url)
  ];
  if (rows.length) {
    const { state, district } = houseStateDistrict(parseJSON(filing.raw_json, {}).stateDistrict);
    for (const row of rows) {
      const match = resolve({ name: row.representative, chamber: "house", state, district });
      const enriched = {
        ...row,
        state,
        district,
        politicianID: match?.id ?? null,
        matchConfidence: match?.confidence ?? 0,
        marketMovePercent: row.ticker ? moves.get(row.ticker) ?? null : null
      };
      const ranking = rankDisclosure(enriched);
      statements.push(disclosureStatement(env.DB, {
        ...enriched,
        rankingScore: ranking.score,
        rankingReasons: ranking.reasons,
        whyItMatters: whyDisclosureMatters(enriched),
        observedAt: firstSeen?.observed_at ?? now,
        updatedAt: now,
        suppressedBy: mode === "live" ? null : "shadow"
      }));
    }
  }
  await executeInChunks(env.DB, statements, 100);
}

async function syncTruth(env) {
  return withHealth(env, "truth-api", "Truth Social political monitoring", async () => {
    const hasLicensedAPI = env.TRUTH_API_URL && env.TRUTH_API_TOKEN;
    const hasApifyActor = env.TRUTH_APIFY_ACTOR_ID && env.APIFY_API_TOKEN;
    if (!hasLicensedAPI && !hasApifyActor) return { recordsSeen: 0, message: "Not configured" };
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

async function withHealth(env, provider, displayName, operation, { recordHealth = true } = {}) {
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
    if (recordHealth) await updateHealth(env.DB, {
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
    if (recordHealth) {
      await updateHealth(env.DB, {
        provider, displayName, status: "failed", attemptedAt, succeededAt: null, recordsSeen: 0, message
      });
    }
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
    FROM disclosures WHERE suppressed_by IS NULL GROUP BY chamber
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
      raw_json, observed_at, updated_at, confidence, ranking_score, ranking_reasons, why_it_matters,
      state, district, match_confidence, asset_type, description, suppressed_by)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET politician_id=COALESCE(excluded.politician_id, disclosures.politician_id),
      asset_name=excluded.asset_name, transaction_type=excluded.transaction_type, owner=excluded.owner,
      amount_range=excluded.amount_range, chamber=excluded.chamber, party=excluded.party,
      source_url=excluded.source_url, raw_json=excluded.raw_json, updated_at=excluded.updated_at,
      confidence=excluded.confidence, ranking_score=excluded.ranking_score,
      ranking_reasons=excluded.ranking_reasons, why_it_matters=excluded.why_it_matters,
      state=COALESCE(excluded.state, disclosures.state),
      district=COALESCE(excluded.district, disclosures.district),
      match_confidence=COALESCE(excluded.match_confidence, disclosures.match_confidence),
      asset_type=COALESCE(excluded.asset_type, disclosures.asset_type),
      description=COALESCE(excluded.description, disclosures.description)
  `).bind(
    value.id, value.provider, value.politicianID, value.representative, value.reportDate,
    value.transactionDate, value.ticker, value.assetName, value.transactionType, value.owner,
    value.amountRange, value.chamber, value.party, value.sourceURL, value.rawJSON,
    value.observedAt, value.updatedAt, value.confidence, value.rankingScore,
    JSON.stringify(value.rankingReasons), value.whyItMatters,
    value.state ?? null, value.district ?? null, value.matchConfidence ?? null,
    value.assetType ?? null, value.description ?? null, value.suppressedBy ?? null
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
    title: `${record.representative} disclosed a ${record.type} in ${record.symbol || record.assetName}`,
    body: `${record.assetName} · ${record.amountRange}`,
    author: record.representative,
    politicianID: record.politicianID,
    // Filings carry calendar dates only; the app must not render a time of day for them.
    timePrecision: "date",
    publishedAt: `${record.filedDate}T12:00:00Z`,
    retrievedAt: record.observedAt ?? `${record.filedDate}T12:00:00Z`,
    transactionDate: `${record.transactionDate}T12:00:00Z`,
    sourceURL: record.sourceURL,
    mentionedSymbols: record.symbol ? [record.symbol] : [],
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
    politicianID: null,
    timePrecision: "datetime",
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
    party: row.party,
    state: row.state,
    district: row.district,
    matchConfidence: row.match_confidence,
    observedAt: row.observed_at ?? null,
    assetType: row.asset_type ?? null,
    description: row.description ?? null,
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
  return marketMoves(result.results);
}

// A missing quote is unknown context, not a 0% move.
function marketMoves(rows) {
  return new Map(rows
    .filter((row) => row.change_percent != null && Number.isFinite(Number(row.change_percent)))
    .map((row) => [row.symbol, Number(row.change_percent)]));
}

function rescoredDisclosure(record, moves, now) {
  const rescored = rescoreDisclosure({
    reportDate: record.filedDate,
    transactionDate: record.transactionDate,
    amountRange: record.amountRange,
    chamber: record.chamber,
    confidence: record.confidence,
    ticker: record.symbol,
    assetName: record.assetName,
    assetType: record.assetType,
    transactionType: record.type
  }, record.symbol ? moves.get(record.symbol) ?? null : null, now);
  return {
    ...record,
    rankingScore: rescored.rankingScore,
    rankingReasons: rescored.rankingReasons,
    whyItMatters: rescored.whyItMatters
  };
}

function rescoredSocialItem(item, moves, now) {
  const marketMovePercent = item.mentionedSymbols.length ? moves.get(item.mentionedSymbols[0]) ?? null : null;
  const record = {
    publishedAt: item.publishedAt,
    policyTopics: item.topics,
    confidence: item.confidence,
    marketMovePercent
  };
  const ranking = rankSocialPost(record, now);
  return {
    ...item,
    impact: impactForScore(ranking.score),
    rankingScore: ranking.score,
    rankingReasons: ranking.reasons,
    explanation: socialWhyItMatters(record)
  };
}

function topByScore(items, limit) {
  return items
    .filter((item) => item.rankingScore > 0)
    .sort((a, b) => b.rankingScore - a.rankingScore
      || String(b.filedDate ?? b.publishedAt).localeCompare(String(a.filedDate ?? a.publishedAt)))
    .slice(0, limit);
}

function uniqueByID(rows) {
  return [...new Map(rows.map((row) => [row.id, row])).values()];
}

function pendingFilingItems(rows) {
  const resolve = createResolver(roster);
  return rows.map((row) => {
    const raw = parseJSON(row.raw_json, {});
    const { state, district } = houseStateDistrict(raw.stateDistrict);
    const match = resolve({ name: row.representative, chamber: row.chamber, state, district });
    return {
      id: row.id,
      representative: row.representative,
      politicianID: match?.id ?? null,
      chamber: row.chamber,
      filedDate: row.disclosure_date,
      sourceURL: row.filing_url,
      documentID: row.doc_id,
      status: "pending-extraction"
    };
  });
}

function daysAgo(days, now = new Date()) {
  return new Date(now.valueOf() - days * DAY_MS).toISOString().slice(0, 10);
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
