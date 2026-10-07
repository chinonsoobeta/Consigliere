import { annualAnchor } from "./house-annual.js";
import { stableUUID, bulkInsertStatements } from "./normalization.js";

export const PORTFOLIO_METHOD_VERSION = 2;

export function amountBand(text) {
  const numbers = String(text).match(/[\d][\d,]*(?:\.\d+)?/g)?.map((n) => Number(n.replaceAll(",", ""))) ?? [];
  if (!numbers.length) return null;
  const low = numbers[0] % 1000 === 1 ? numbers[0] - 1 : numbers[0];
  const high = numbers[1] ?? null;
  return { low, high, midpoint: high == null ? low : (low + high) / 2 };
}

export function assetGroup(row) {
  if (row.asset_type === "OP") return "options";
  if (["GS", "CS", "CB", "MB"].includes(row.asset_type)) return "bonds";
  if (["MF", "ET"].includes(row.asset_type)) return "funds";
  if (!row.ticker) return "unmatched";
  return "stocks";
}

export function saleKind(row) {
  let raw;
  try { raw = JSON.parse(row.raw_json); } catch { return "unknown"; }
  if (raw.partial === true || /partial/i.test(raw.transaction?.transactionType ?? "")) return "partial";
  if (raw.partial === false || /full|all/i.test(raw.transaction?.transactionType ?? "")) return "full";
  return "unknown";
}

export function buildMemberPortfolio(rows, { memberID, frozenAt = null, ownOnly = false, anchor = null } = {}) {
  const positions = new Map();
  const changes = [];
  if (anchor) {
    for (const asset of anchor.assets.filter(a => !ownOnly || a.owner === "member")) {
      const band = amountBand(asset.amountRange);
      if (!band || band.midpoint <= 0) continue;
      const row = { ticker: asset.ticker ?? "", asset_name: asset.name, asset_type: asset.assetType, owner: asset.owner, description: asset.description };
      const group = assetGroup(row);
      const key = [group, row.ticker || row.asset_name, row.owner, group === "options" ? row.description ?? row.asset_name : ""].join("|");
      const prior = positions.get(key);
      positions.set(key, { key, ticker: row.ticker, assetName: row.asset_name, group, owner: row.owner,
        estimate: (prior?.estimate ?? 0) + band.midpoint, low: (prior?.low ?? 0) + band.low,
        high: band.high == null || prior?.high === null ? null : (prior?.high ?? 0) + band.high,
        membersHolding: 1, firstAdded: anchor.asOf, lastActivity: anchor.filedDate, status: "estimated-held", sector: null });
    }
  }
  const eligible = rows.filter((row) => (!ownOnly || row.owner === "member") && (!anchor || row.transaction_date > anchor.asOf) && (!frozenAt || row.report_date <= frozenAt))
    .sort((a, b) => a.transaction_date.localeCompare(b.transaction_date) || a.report_date.localeCompare(b.report_date) || a.id.localeCompare(b.id));
  for (const row of eligible) {
    const group = assetGroup(row);
    // Separate contracts and accounts; an option disposal cannot close a stock position.
    const key = [group, row.ticker || row.asset_name, row.owner, group === "options" ? row.description ?? row.asset_name : ""].join("|");
    let position = positions.get(key);
    const action = row.transaction_type;
    const band = amountBand(row.amount_range);
    if (action === "exchange") {
      changes.push(change(row, "exchange", "Exchange logged; estimates unchanged."));
      continue;
    }
    if (!band) { changes.push(change(row, "unestimated", "Amount band unavailable; no estimate assigned.")); continue; }
    if (!position) {
      position = { key, ticker: row.ticker, assetName: row.asset_name, group, owner: row.owner,
        estimate: 0, low: 0, high: 0, membersHolding: 0, firstAdded: null, lastActivity: row.report_date, status: "exited", sector: row.sector ?? null };
      positions.set(key, position);
    }
    const previous = position.estimate;
    let note = null;
    let kind;
    if (action === "purchase") {
      position.status = "estimated-held";
      position.estimate += band.midpoint;
      position.low += band.low;
      position.high = position.high == null || band.high == null ? null : position.high + band.high;
      position.firstAdded ??= row.transaction_date;
      kind = previous > 0 ? "increased" : "added";
    } else if (action === "sale") {
      if (!position.firstAdded) {
        note = "Held before our records; sale closes an unobserved position.";
        position.status = "held-before-records";
        kind = "exited";
      } else if (saleKind(row) === "full") {
        position.estimate = position.low = position.high = 0;
        kind = "exited";
      } else {
        position.estimate = Math.max(0, previous - band.midpoint);
        // Subtract interval bounds in opposite directions to preserve uncertainty.
        position.low = band.high == null ? 0 : Math.max(0, position.low - band.high);
        position.high = position.high == null ? null : Math.max(0, position.high - band.low);
        kind = position.estimate > 0 ? "trimmed" : "exited";
        if (saleKind(row) === "unknown") note = "Sale extent unspecified; subtracts disclosed band rather than assuming full disposal.";
      }
    } else continue;
    position.lastActivity = [position.lastActivity,row.report_date].sort().at(-1);
    if (position.status !== "held-before-records") position.status = position.estimate > 0 ? "estimated-held" : "exited";
    position.membersHolding = position.estimate > 0 ? 1 : 0;
    changes.push(change(row, kind, note));
  }
  return { id: `member/${memberID}`, kind: "member", members: [memberID], methodVersion: PORTFOLIO_METHOD_VERSION,
    historyStart: anchor?.asOf ?? eligible[0]?.transaction_date ?? null, frozenAt, anchorAsOf: anchor?.asOf ?? null, anchorFiledDate: anchor?.filedDate ?? null, anchorSourceURL: anchor?.sourceURL ?? null, positions: [...positions.values()], changes };
}

function change(row, action, note) {
  return { id: row.id, ticker: row.ticker, assetName: row.asset_name, action, filedDate: row.report_date, disclosureID: row.id, sourceURL: row.source_url, note };
}

export function aggregatePortfolios(portfolios, id = "congress") {
  const positions = new Map();
  for (const portfolio of portfolios) {
    const heldByMember = new Set();
    for (const p of portfolio.positions.filter((p) => p.estimate > 0)) {
      const key = `${p.group}|${p.ticker || p.assetName}`;
      const total = positions.get(key) ?? { ...p, key, owner: "all", estimate: 0, low: 0, high: 0, membersHolding: 0 };
      total.estimate += p.estimate;
      total.low += p.low;
      total.high = total.high == null || p.high == null ? null : total.high + p.high;
      if (!heldByMember.has(key)) { total.membersHolding += 1; heldByMember.add(key); }
      total.lastActivity = [total.lastActivity, p.lastActivity].sort().at(-1);
      total.firstAdded = [total.firstAdded, p.firstAdded].filter(Boolean).sort()[0] ?? null;
      positions.set(key, total);
    }
  }
  return { id, kind: id === "congress" ? "congress" : "committee", members: portfolios.flatMap((p) => p.members), methodVersion: PORTFOLIO_METHOD_VERSION,
    historyStart: portfolios.map((p) => p.historyStart).filter(Boolean).sort()[0] ?? null,
    frozenAt: null, positions: [...positions.values()].sort((a,b) => b.membersHolding - a.membersHolding || a.ticker.localeCompare(b.ticker)), changes: portfolios.flatMap((p) => p.changes) };
}

export async function rebuildPortfolios(db) {
  // Read all served records, including historical pages; never reconstruct from the snapshot.
  const [disclosures, members, assignments, annuals, securities] = await Promise.all([
    db.prepare("SELECT d.*, s.sector FROM disclosures d LEFT JOIN securities s ON s.ticker = d.ticker WHERE d.suppressed_by IS NULL AND d.politician_id IS NOT NULL").all(),
    db.prepare("SELECT bioguide_id, service_end FROM politicians WHERE country = 'us'").all(),
    db.prepare("SELECT * FROM committee_assignments WHERE end_date IS NULL").all(),
    db.prepare("SELECT * FROM house_annual_reports WHERE status='extracted'").all(),
    db.prepare("SELECT ticker,sector FROM securities WHERE sector IS NOT NULL").all()
  ]);
  const grouped = Map.groupBy(disclosures.results, (r) => r.politician_id);
  const portfolios = members.results.map((m) => buildMemberPortfolio(grouped.get(m.bioguide_id) ?? [], { memberID: m.bioguide_id, frozenAt: m.service_end, anchor: annualAnchor(annuals.results,m.bioguide_id,m.service_end) }));
  const sectors = new Map(securities.results.map(s=>[s.ticker,s.sector]));
  for (const portfolio of portfolios) for (const position of portfolio.positions) position.sector ??= sectors.get(position.ticker) ?? null;
  const groups = Map.groupBy(assignments.results, (r) => r.committee_id);
  const all = [...portfolios, aggregatePortfolios(portfolios), ...[...groups].map(([id, records]) => aggregatePortfolios(portfolios.filter((p) => records.some((r) => r.member_id === p.members[0])), `committee/${id}`))];
  const now = new Date().toISOString();
  // One atomic replacement of derived estimates. Bulk JSON keeps the entire Congress
  // rebuild within D1's per-invocation query limit even with hundreds of members.
  const statements = [
    ...bulkInsertStatements(db, "reference_portfolios", ["id","kind","members","method_version","built_at","history_start","frozen_at","anchor_as_of","anchor_filed_date","anchor_source_url"], all.map(p => [p.id,p.kind,JSON.stringify(p.members),p.methodVersion,now,p.historyStart,p.frozenAt,p.anchorAsOf??null,p.anchorFiledDate??null,p.anchorSourceURL??null]),
      "ON CONFLICT(id) DO UPDATE SET members=excluded.members, method_version=excluded.method_version, built_at=excluded.built_at, history_start=excluded.history_start, frozen_at=excluded.frozen_at, anchor_as_of=excluded.anchor_as_of, anchor_filed_date=excluded.anchor_filed_date, anchor_source_url=excluded.anchor_source_url"),
    db.prepare("DELETE FROM reference_positions"), db.prepare("DELETE FROM reference_changes"),
    ...bulkInsertStatements(db,"reference_positions", ["portfolio_id","position_key","ticker","asset_name","asset_group","owner","estimate","low","high","members_holding","first_added","last_activity","status","sector"],
      all.flatMap(portfolio => portfolio.positions.map(p => [portfolio.id,p.key,p.ticker,p.assetName,p.group,p.owner,p.estimate,p.low,p.high,p.membersHolding,p.firstAdded,p.lastActivity,p.status,p.sector]))),
    ...bulkInsertStatements(db,"reference_changes", ["id","portfolio_id","ticker","asset_name","action","filed_date","disclosure_id","source_url","note"],
      all.flatMap(portfolio => portfolio.changes.map(c => [stableUUID(`${portfolio.id}|${c.id}`),portfolio.id,c.ticker,c.assetName,c.action,c.filedDate,c.disclosureID,c.sourceURL,c.note])))
  ];
  await db.batch(statements);
  return { portfolios: all.length, methodVersion: PORTFOLIO_METHOD_VERSION };
}

export async function readPortfolio(db, id, ownOnly = false) {
  if (ownOnly && id.startsWith("member/")) {
    const rows = await db.prepare("SELECT * FROM disclosures WHERE politician_id = ? AND suppressed_by IS NULL").bind(id.slice(7)).all();
    const member = await db.prepare("SELECT service_end FROM politicians WHERE bioguide_id = ?").bind(id.slice(7)).first();
    const annuals=await db.prepare("SELECT * FROM house_annual_reports WHERE member_id=?").bind(id.slice(7)).all();
    return buildMemberPortfolio(rows.results, { memberID: id.slice(7), frozenAt: member?.service_end, ownOnly, anchor: annualAnchor(annuals.results,id.slice(7),member?.service_end) });
  }
  const portfolio = await db.prepare("SELECT * FROM reference_portfolios WHERE id = ?").bind(id).first();
  if (!portfolio) return null;
  const positions = await db.prepare("SELECT * FROM reference_positions WHERE portfolio_id = ? ORDER BY members_holding DESC, estimate DESC").bind(id).all();
  return { id, kind: portfolio.kind, methodVersion: portfolio.method_version, builtAt: portfolio.built_at,
    historyStart: portfolio.history_start, frozenAt: portfolio.frozen_at, anchorAsOf: portfolio.anchor_as_of, anchorFiledDate: portfolio.anchor_filed_date, anchorSourceURL: portfolio.anchor_source_url, members: JSON.parse(portfolio.members),
    positions: positions.results.map((p) => ({ key: p.position_key, ticker: p.ticker, assetName: p.asset_name, group: p.asset_group, owner: p.owner, estimate: p.estimate, low: p.low, high: p.high,
      membersHolding: p.members_holding, firstAdded: p.first_added, lastActivity: p.last_activity, status: p.status, sector: p.sector })) };
}
