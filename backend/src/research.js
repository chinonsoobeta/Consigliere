import { rebuildPortfolios, readPortfolio, servedDisclosures } from "./reference-portfolios.js";
import { collectStatements, tagStatement, relevance, TAG_PROMPT_VERSION, TAG_MODEL } from "./statements.js";
import { stableUUID, bulkInsertStatements } from "./normalization.js";

export async function syncStatements(env) {
  const { rows, failures } = await collectStatements(env);
  const securities = (await env.DB.prepare("SELECT ticker, name FROM securities").all()).results;
  const recent = (await env.DB.prepare("SELECT id,published_at,tags FROM statements WHERE published_at >= ?").bind(new Date(Date.now() - 30 * 86_400_000).toISOString()).all()).results;
  const now = new Date().toISOString();
  const tagVersion = stableUUID(JSON.stringify([TAG_PROMPT_VERSION, env.ANTHROPIC_API_KEY ? TAG_MODEL : "rules", securities]));
  for (const row of rows.sort((a,b) => a.publishedAt.localeCompare(b.publishedAt))) {
    const existing = await env.DB.prepare("SELECT body, tags, raw_json FROM statements WHERE id = ?").bind(row.id).first();
    const tags = existing?.body === row.body && JSON.parse(existing.raw_json)?.tagVersion === tagVersion ? JSON.parse(existing.tags) : await tagStatement(row.body, securities, env);
    const earlier = recent.filter(r => r.id !== row.id && r.published_at < row.publishedAt && Date.parse(r.published_at) >= Date.parse(row.publishedAt) - 30 * 86_400_000).flatMap(r => JSON.parse(r.tags));
    const { tier, priority } = relevance(tags, earlier);
    await env.DB.prepare(`INSERT INTO statements VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET body=excluded.body, title=excluded.title, tags=excluded.tags,
      tier=excluded.tier, priority=excluded.priority, signed_at=excluded.signed_at,
      document_number=excluded.document_number, raw_json=excluded.raw_json, retrieved_at=excluded.retrieved_at`)
      .bind(row.id, row.provider, row.kind, row.title, row.body, row.sourceURL, row.publishedAt, row.signedAt, row.documentNumber, JSON.stringify(tags), tier, priority, JSON.stringify({ source: row.raw, tagVersion }), now).run();
    if (row.provider === "white-house" && row.documentNumber) {
      await env.DB.prepare("UPDATE statements SET raw_json=json_set(raw_json,'$.confirmedBy',?) WHERE provider='federal-register' AND document_number=?").bind(row.id,row.documentNumber).run();
    }
    recent.push({ id: row.id, published_at: row.publishedAt, tags: JSON.stringify(tags) });
  }
  return { recordsSeen: rows.length, recordsWritten: rows.length, message: failures.length ? failures.join("; ") : null };
}

export async function syncSecurityMetadata(env) {
  if (!env.SEC_USER_AGENT) return { recordsSeen: 0, message: "Not configured" };
  // SEC requires a declared organization/contact user agent. No attempt with a made-up contact.
  const headers = { "User-Agent": env.SEC_USER_AGENT, Accept: "application/json" };
  const response = await fetch("https://www.sec.gov/files/company_tickers.json", { headers, signal: AbortSignal.timeout(20_000) });
  if (!response.ok) throw new Error(`SEC ticker dictionary returned ${response.status}`);
  const dictionary = Object.values(await response.json());
  const now = new Date().toISOString();
  const imports=bulkInsertStatements(env.DB,"securities",["ticker","name","cik","source_url","updated_at"],dictionary.map(r=>[r.ticker,r.title,String(r.cik_str),"https://www.sec.gov/files/company_tickers.json",now]),"ON CONFLICT(ticker) DO UPDATE SET name=excluded.name,cik=excluded.cik,updated_at=excluded.updated_at");
  if(imports.length)await env.DB.batch(imports);
  const needs = (await env.DB.prepare(`SELECT s.ticker, s.cik FROM securities s WHERE s.cik IS NOT NULL AND s.sic IS NULL AND (s.ticker IN (SELECT ticker FROM disclosures) OR s.ticker IN (SELECT ticker FROM reference_positions) OR s.ticker IN (SELECT ticker FROM interest_records)) LIMIT 30`).all()).results;
  // Six requests at a time, below the SEC's ten-per-second ceiling.
  for (let offset = 0; offset < needs.length; offset += 6) {
    if (offset) await new Promise((resolve) => setTimeout(resolve, 1000));
    await Promise.all(needs.slice(offset, offset + 6).map(async ({ ticker, cik }) => {
      const sourceURL = `https://data.sec.gov/submissions/CIK${String(cik).padStart(10,"0")}.json`;
      const response = await fetch(sourceURL, { headers, signal: AbortSignal.timeout(20_000) });
      if (!response.ok) throw new Error(`SEC submissions returned ${response.status}`);
      const company = await response.json();
      await env.DB.prepare("UPDATE securities SET sic=?, sector=?, updated_at=? WHERE ticker=?").bind(String(company.sic ?? ""), sectorForSIC(company.sic), now, ticker).run();
    }));
  }
  return { recordsSeen: dictionary.length, recordsWritten: dictionary.length };
}

export function sectorForSIC(sic) {
  const n = Number(sic);
  if (!n) return null;
  if (n >= 1300 && n < 1400 || n >= 2900 && n < 3000) return "Energy";
  if (n >= 6000 && n < 6800) return n >= 6500 && n < 6600 ? "Real estate" : "Financials";
  if (n >= 4800 && n < 4900) return "Communications";
  if (n >= 4900 && n < 5000) return "Utilities";
  if (n >= 8000 && n < 8100 || n >= 2830 && n < 2840 || n >= 3840 && n < 3860) return "Healthcare";
  if (n >= 3570 && n < 3580 || n >= 3670 && n < 3680 || n >= 7370 && n < 7380) return "Technology";
  if (n < 1000 || n >= 2000 && n < 2200 || n >= 5400 && n < 5500) return "Consumer staples";
  if (n >= 1000 && n < 1500 || n >= 2800 && n < 2900) return "Materials";
  if (n >= 5000 && n < 6000 || n >= 7000 && n < 7300) return "Consumer discretionary";
  return "Industrials";
}

export async function syncCommittees(env) {
  const sourceURL = "https://unitedstates.github.io/congress-legislators/committee-membership-current.json";
  const response = await fetch(sourceURL, { signal: AbortSignal.timeout(20_000) });
  if (!response.ok) throw new Error(`Committee roster returned ${response.status}`);
  const memberships = await response.json();
  const namesResponse = await fetch("https://unitedstates.github.io/congress-legislators/committees-current.json", { signal: AbortSignal.timeout(20_000) });
  if (!namesResponse.ok) throw new Error(`Committee names returned ${namesResponse.status}`);
  const names = await namesResponse.json();
  const now = new Date().toISOString().slice(0,10);
  const existingMembers = new Set((await env.DB.prepare("SELECT bioguide_id FROM politicians WHERE country='us'").all()).results.map((r) => r.bioguide_id));
  const current = Object.entries(memberships).flatMap(([committee, members]) => members.filter((m) => existingMembers.has(`us:${m.bioguide}`)).map((m) => ({ committee, member: `us:${m.bioguide}` })));
  const known = (await env.DB.prepare("SELECT * FROM committee_assignments WHERE end_date IS NULL").all()).results;
  const namesByID=new Map(names.flatMap(r=>[[r.thomas_id,r.name],...(r.subcommittees??[]).map(sub=>[r.thomas_id+sub.thomas_id,`${r.name}: ${sub.name}`])]));
  const updates=known.filter(r=>!current.some(c=>c.committee===r.committee_id && c.member===r.member_id)).map(r=>env.DB.prepare("UPDATE committee_assignments SET end_date=? WHERE committee_id=? AND member_id=? AND start_date=?").bind(now,r.committee_id,r.member_id,r.start_date));
  updates.push(...bulkInsertStatements(env.DB,"committee_assignments",["committee_id","member_id","start_date","end_date","source_url","name"],current.filter(r=>!known.some(k=>k.committee_id===r.committee && k.member_id===r.member)).map(r=>[r.committee,r.member,now,null,sourceURL,namesByID.get(r.committee)??null]),"ON CONFLICT(committee_id,member_id,start_date) DO NOTHING"));
  // Names can change without an assignment changing; refresh them independently.
  const labels=JSON.stringify([...namesByID]);
  updates.push(env.DB.prepare("UPDATE committee_assignments SET name=(SELECT json_extract(value,'$[1]') FROM json_each(?) WHERE json_extract(value,'$[0]')=committee_id) WHERE committee_id IN (SELECT json_extract(value,'$[0]') FROM json_each(?))").bind(labels,labels));
  if(updates.length)await env.DB.batch(updates);
  return { recordsSeen: current.length, recordsWritten: updates.length };
}

function mapStatement(row) {
  return { id: row.id, provider: row.provider, kind: row.kind, title: row.title, body: row.body, sourceURL: row.source_url, publishedAt: row.published_at, signedAt: row.signed_at, confirmationURL: JSON.parse(row.raw_json)?.source?.confirmation?.sourceURL ?? null, documentNumber: row.document_number, tags: JSON.parse(row.tags), tier: row.tier, priority: row.priority };
}

export async function researchRoute(request, env, mapDisclosure) {
  const url = new URL(request.url);
  const path = url.pathname;
  if (request.method === "GET" && path === "/v1/portfolios") {
    const result = await env.DB.prepare("SELECT p.id,p.kind,p.members,p.built_at,MAX(c.name) AS title FROM reference_portfolios p LEFT JOIN committee_assignments c ON p.id='committee/' || c.committee_id WHERE p.kind <> 'member' GROUP BY p.id ORDER BY p.kind,p.id").all();
    return response({ data: result.results });
  }
  if (request.method === "GET" && path.startsWith("/v1/portfolios/")) {
    let id = decodeURIComponent(path.slice(15));
    const changes = id.endsWith("/changes");
    if (changes) id = id.slice(0, -8);
    if (changes) {
      if (url.searchParams.get("own_only") === "true" && id.startsWith("member/")) {
        const portfolio = await readPortfolio(env.DB, id, true, { env });
        return response({ data: portfolio.changes.slice().reverse().slice(0,500) });
      }
      const result = await env.DB.prepare("SELECT * FROM reference_changes WHERE portfolio_id=? ORDER BY filed_date DESC, id DESC LIMIT 500").bind(id).all();
      return response({ data: result.results.map((r) => ({ id: r.id, ticker: r.ticker, assetName: r.asset_name, action: r.action, filedDate: r.filed_date, disclosureID: r.disclosure_id, sourceURL: r.source_url, note: r.note })) });
    }
    const limit = Number.parseInt(url.searchParams.get("limit") ?? "", 10);
    const portfolio = await readPortfolio(env.DB, id, url.searchParams.get("own_only") === "true", {
      ticker: url.searchParams.get("ticker")?.toUpperCase() || null,
      limit: Number.isFinite(limit) && limit > 0 ? Math.min(limit, 1000) : null, env
    });
    return response(portfolio ? { data: portfolio } : { error: "portfolio_not_built" }, portfolio ? 200 : 404);
  }
  if (request.method === "GET" && path === "/v1/statements") {
    const recent = new Date(Date.now() - 30 * 86_400_000).toISOString();
    const ticker = url.searchParams.get("ticker")?.toUpperCase();
    const clauses = ["published_at >= ?", "json_extract(raw_json,'$.confirmedBy') IS NULL"];
    const args = [ticker ? `${new Date().getUTCFullYear()}-01-01` : recent];
    if (ticker) { clauses.push("EXISTS (SELECT 1 FROM json_each(tags) WHERE json_extract(value,'$.kind')='company' AND json_extract(value,'$.value')=?)"); args.push(ticker); }
    const rows = await env.DB.prepare(`SELECT * FROM statements WHERE ${clauses.join(" AND ")} ORDER BY CASE tier WHEN 'Names a company' THEN 0 WHEN 'Affects a sector' THEN 1 ELSE 2 END, priority DESC, published_at DESC LIMIT 100`).bind(...args).all();
    return response({ data: rows.results.map(mapStatement) });
  }
  if (request.method === "GET" && path.startsWith("/v1/statements/")) {
    const row = await env.DB.prepare("SELECT * FROM statements WHERE id=?").bind(path.slice(15)).first();
    if (!row) return response({ error: "not_found" }, 404);
    const statement = mapStatement(row);
    const tickers = [...new Set(statement.tags.filter((t) => t.kind === "company").map((t) => t.value))];
    let holdings = [], trades = [];
    if (tickers.length) {
      const args = tickers.map(() => "?").join(",");
      const date = new Date(statement.publishedAt).valueOf();
      [holdings, trades] = await Promise.all([
        env.DB.prepare(`SELECT ticker, members_holding FROM reference_positions WHERE portfolio_id='congress' AND asset_group='stocks' AND ticker IN (${args})`).bind(...tickers).all().then((r) => r.results.map((h) => ({ ticker: h.ticker, membersHolding: h.members_holding }))),
        env.DB.prepare(`SELECT * FROM disclosures WHERE ${servedDisclosures(env)} AND ticker IN (${args}) AND transaction_date BETWEEN ? AND ? ORDER BY transaction_date DESC`).bind(...tickers, new Date(date-30*86_400_000).toISOString().slice(0,10), new Date(date+30*86_400_000).toISOString().slice(0,10)).all().then((r) => r.results.map(mapDisclosure))
      ]);
    }
    return response({ data: { ...statement, relatedHoldings: holdings, relatedTrades: trades } });
  }
  if (request.method === "POST" && path === "/v1/statement-corrections") {
    const body = await request.text();
    if (body.length > 4096) return response({ error: "request_too_large" }, 413);
    let input; try { input = JSON.parse(body); } catch { return response({ error: "invalid_json" },400); }
    if (typeof input.reason !== "string" || input.reason.trim().length < 5 || input.reason.length > 1000) return response({ error: "reason_required" },400);
    const row = await env.DB.prepare("SELECT tags FROM statements WHERE id=?").bind(String(input.statementID ?? "")).first();
    if (!row || !JSON.parse(row.tags).some((t) => t.id === input.tagID)) return response({ error: "unknown_tag" },400);
    // Anyone can report a tag, so a statement's review queue is capped rather than left open-ended.
    const pending = await env.DB.prepare("SELECT COUNT(*) AS count FROM statement_corrections WHERE statement_id=? AND status='pending'").bind(String(input.statementID)).first();
    if (Number(pending?.count ?? 0) >= 25) return response({ error: "review_queue_full" }, 429);
    const id = stableUUID(`${input.statementID}|${input.tagID}|${input.reason.trim()}`);
    await env.DB.prepare("INSERT OR IGNORE INTO statement_corrections(id,statement_id,tag_id,reason,created_at) VALUES(?,?,?,?,?)").bind(id,input.statementID,input.tagID,input.reason.trim(),new Date().toISOString()).run();
    return response({ data: { id, status: "pending" } },202);
  }
  return null;
}

function response(body, status = 200) { return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store", "x-content-type-options": "nosniff" } }); }
export { rebuildPortfolios, servedDisclosures };

// A removed member stays in D1. The public roster's last term end supplies the
// cutoff for that member's estimate; current members never freeze at a future date.
export async function syncServiceDates(env) {
  const base = "https://unitedstates.github.io/congress-legislators/";
  const datasets = await Promise.all(["legislators-current.json", "legislators-historical.json"].map(async file => {
    const response = await fetch(base + file, { signal: AbortSignal.timeout(20_000) });
    if (!response.ok) throw new Error(`Congress term dates returned ${response.status}`);
    return response.json();
  }));
  const current = new Set(datasets[0].map(r => `us:${r.id.bioguide}`));
  const records = new Map(datasets.flat().map(r => [`us:${r.id.bioguide}`, r]));
  const today = new Date().toISOString().slice(0,10);
  const members = (await env.DB.prepare("SELECT bioguide_id FROM politicians WHERE country='us'").all()).results;
  const dates = members.filter(m => records.has(m.bioguide_id)).map(m => {
    const person = records.get(m.bioguide_id);
    const end = person.terms?.at(-1)?.end;
    return [m.bioguide_id, !current.has(m.bioguide_id) && end && end <= today ? end : null];
  });
  if (dates.length) await env.DB.prepare(`UPDATE politicians SET service_end=(SELECT json_extract(value,'$[1]') FROM json_each(?) WHERE json_extract(value,'$[0]')=bioguide_id)
    WHERE bioguide_id IN (SELECT json_extract(value,'$[0]') FROM json_each(?))`).bind(JSON.stringify(dates),JSON.stringify(dates)).run();
  return { recordsSeen: dates.length, recordsWritten: dates.length };
}
