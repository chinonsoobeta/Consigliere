// Compares the House PDF extractor with the House rows the production API currently serves.
//   node scripts/validate-house-ptr.mjs [--year 2026] [--api https://…workers.dev] [--cache dir] [--limit n]
// PDFs are cached so reruns do not fetch them from the Clerk again.
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { houseIndexFromArchive, parseHouseIndex } from "../src/providers.js";
import { isElectronicHouseFiling, readHousePTR } from "../src/house-ptr.js";

const args = Object.fromEntries(process.argv.slice(2).reduce((pairs, value, index, all) =>
  value.startsWith("--") ? [...pairs, [value.slice(2), all[index + 1]]] : pairs, []));
const year = Number(args.year ?? new Date().getUTCFullYear());
const api = args.api ?? "https://consigliere-ingestion.chinonsoobeta.workers.dev";
const cache = args.cache ?? join(tmpdir(), "consigliere-house-ptr");
const limit = Number(args.limit ?? Infinity);
const headers = { "User-Agent": "Consigliere/1.0 public-interest political-market research" };
const OWNER_CODES = { SP: "spouse", JT: "joint", DC: "dependent" };

await mkdir(cache, { recursive: true });

async function cached(name, url) {
  const path = join(cache, name);
  try { return await readFile(path); } catch {}
  const response = await fetch(url, { headers });
  if (!response.ok) throw new Error(`${url} returned ${response.status}`);
  const bytes = Buffer.from(await response.arrayBuffer());
  await writeFile(path, bytes);
  await new Promise((resolve) => setTimeout(resolve, 250));
  return bytes;
}

async function productionRows() {
  const rows = [];
  let cursor = null;
  do {
    const url = new URL("/v1/disclosures", api);
    Object.entries({ chamber: "house", date_basis: "filed", from: `${year}-01-01`, to: `${year}-12-31`, limit: 500 })
      .forEach(([key, value]) => url.searchParams.set(key, value));
    if (cursor) { url.searchParams.set("cursor_date", cursor.date); url.searchParams.set("cursor_id", cursor.id); }
    const payload = await (await fetch(url)).json();
    rows.push(...payload.data);
    cursor = payload.meta.nextCursor;
  } while (cursor);
  return rows;
}

// Apify drops the owner code it leaves in the asset name ("2000134527 SP U.S. Bancorp"); the app
// recovers it, so the comparison does too.
function apifyOwner(row) {
  const code = row.assetName.match(/^\d{6,}\s+(SP|JT|DC)\s+/)?.[1];
  return code ? OWNER_CODES[code] : row.owner;
}

const key = (row) => [row.ticker, row.transactionDate, row.transactionType, row.amountRange].join("|");

const index = parseHouseIndex(houseIndexFromArchive(
  await cached(`${year}FD.zip`, `https://disclosures-clerk.house.gov/public_disc/financial-pdfs/${year}FD.zip`), year
), year);
const electronic = index.filter((filing) => isElectronicHouseFiling(filing.docID));
const apify = new Map();
for (const row of await productionRows()) {
  const docID = row.sourceURL.match(/(\d+)\.pdf$/)?.[1];
  if (!docID) continue;
  if (!apify.has(docID)) apify.set(docID, []);
  apify.get(docID).push({
    ticker: row.symbol, transactionDate: row.transactionDate, transactionType: row.type,
    amountRange: row.amountRange, owner: apifyOwner(row), assetName: row.assetName
  });
}

const totals = {
  filings: 0, electronic: electronic.length, paper: index.length - electronic.length,
  withApifyRows: 0, parsed: 0, rows: 0, rowsWithTicker: 0, rowsWithoutTicker: 0, rowProblems: 0,
  warnings: 0, idMismatch: 0, apifyRows: 0, matched: 0, ownerDisagrees: 0, onlyApify: 0, onlyOurs: 0,
  docsExact: 0, cpuMs: 0
};
const differences = [];
for (const filing of electronic.slice(0, limit)) {
  totals.filings += 1;
  const bytes = await cached(`${filing.docID}.pdf`, filing.filingURL);
  const started = process.cpuUsage();
  const parsed = await readHousePTR(bytes);
  const cpu = process.cpuUsage(started);
  totals.cpuMs += (cpu.user + cpu.system) / 1000;
  totals.parsed += 1;
  if (parsed.filingID !== filing.docID) totals.idMismatch += 1;
  totals.warnings += parsed.warnings.length;
  const ours = parsed.transactions.filter((row) => !row.problem);
  totals.rowProblems += parsed.transactions.length - ours.length;
  totals.rows += ours.length;
  totals.rowsWithTicker += ours.filter((row) => row.ticker).length;
  totals.rowsWithoutTicker += ours.filter((row) => !row.ticker).length;
  if (parsed.warnings.length) differences.push({ docID: filing.docID, warnings: parsed.warnings });

  const theirs = apify.get(filing.docID);
  if (!theirs) continue;
  totals.withApifyRows += 1;
  totals.apifyRows += theirs.length;
  // Apify keeps only rows with a ticker, so only those are compared.
  // Rows that agree on the owner are paired first, so a trade made by both the member and their
  // spouse is not matched crosswise.
  const remaining = ours.filter((row) => row.ticker);
  const unmatched = [];
  for (const row of theirs) {
    const at = remaining.findIndex((candidate) => key(candidate) === key(row) && candidate.owner === row.owner);
    if (at === -1) unmatched.push(row);
    else { remaining.splice(at, 1); totals.matched += 1; }
  }
  const onlyApify = [];
  for (const row of unmatched) {
    const at = remaining.findIndex((candidate) => key(candidate) === key(row));
    if (at === -1) { onlyApify.push(row); continue; }
    const [match] = remaining.splice(at, 1);
    totals.matched += 1;
    totals.ownerDisagrees += 1;
    differences.push({ docID: filing.docID, owner: { ours: match.owner, apify: row.owner, key: key(row), asset: row.assetName } });
  }
  totals.onlyApify += onlyApify.length;
  totals.onlyOurs += remaining.length;
  if (!onlyApify.length && !remaining.length) totals.docsExact += 1;
  else differences.push({
    docID: filing.docID,
    onlyApify: onlyApify.map((row) => `${key(row)} | ${row.assetName}`),
    onlyOurs: remaining.map((row) => `${key(row)} | ${row.assetName}`)
  });
}

console.log(JSON.stringify(totals, null, 2));
await writeFile(join(cache, `differences-${year}.json`), JSON.stringify(differences, null, 2));
console.log(`Differences: ${join(cache, `differences-${year}.json`)}`);
