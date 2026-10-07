export function normalizeName(value = "") {
  return String(value)
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/\b(hon|honorable|senator|sen|representative|rep)\b\.?/gi, " ")
    .replace(/[^a-zA-Z0-9]+/g, " ")
    .trim()
    .toLowerCase();
}

export function dateOnly(value) {
  if (!value) return null;
  const text = String(value).trim();
  const isoMatch = text.match(/^\d{4}-\d{2}-\d{2}/);
  if (isoMatch) return validDateOnly(isoMatch[0]) ? isoMatch[0] : null;
  const usMatch = text.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/);
  if (usMatch) {
    const [, month, day, year] = usMatch;
    const candidate = `${year}-${month.padStart(2, "0")}-${day.padStart(2, "0")}`;
    return validDateOnly(candidate) ? candidate : null;
  }
  const parsed = new Date(value);
  return Number.isNaN(parsed.valueOf()) ? null : parsed.toISOString().slice(0, 10);
}

export function stableUUID(value) {
  const text = String(value);
  const chunks = [2166136261, 2246822519, 3266489917, 668265263].map((seed) => {
    let hash = seed >>> 0;
    for (let index = 0; index < text.length; index += 1) {
      hash ^= text.charCodeAt(index);
      hash = Math.imul(hash, 16777619) >>> 0;
    }
    return hash.toString(16).padStart(8, "0");
  });
  const hex = chunks.join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-4${hex.slice(13, 16)}-a${hex.slice(17, 20)}-${hex.slice(20, 32)}`;
}

export function normalizeTransaction(value = "") {
  const text = String(value).toLowerCase();
  if (text.includes("sale") || text === "s") return "sale";
  if (text.includes("exchange") || text === "e") return "exchange";
  if (text.includes("purchase") || text.includes("buy") || text === "p") return "purchase";
  return null;
}

export function normalizeOwner(value = "") {
  const text = String(value).toLowerCase();
  if (text.includes("spouse") || text === "sp") return "spouse";
  if (text.includes("dependent") || text.includes("child") || text === "dc") return "dependent";
  if (text.includes("joint") || text === "jt") return "joint";
  if (!text || text.includes("self") || text.includes("member")) return "member";
  return null;
}

export function amountBounds(value = "") {
  const numbers = String(value).match(/\d[\d,]*/g)?.map((item) => Number(item.replaceAll(",", ""))) ?? [];
  return { minimum: numbers[0] ?? 0, maximum: numbers[1] ?? numbers[0] ?? 0 };
}

function validDateOnly(value) {
  const [year, month, day] = value.split("-").map(Number);
  const date = new Date(Date.UTC(year, month - 1, day));
  return date.getUTCFullYear() === year
    && date.getUTCMonth() === month - 1
    && date.getUTCDate() === day;
}

// D1 counts statements, including each statement inside batch(), toward invocation limits.
// Import rows through json_each with one binding per bounded chunk instead of one query per row.
export function bulkInsertStatements(db, table, columns, rows, conflict = "") {
  const statements = [];
  let chunk = [], bytes = 0;
  const flush = () => {
    if (!chunk.length) return;
    const values = columns.map((_, index) => `json_extract(value, '$[${index}]')`).join(",");
    statements.push(db.prepare(`INSERT INTO ${table}(${columns.join(",")}) SELECT ${values} FROM json_each(?) WHERE 1 ${conflict}`).bind(JSON.stringify(chunk)));
    chunk = []; bytes = 0;
  };
  for (const row of rows) {
    const size = new TextEncoder().encode(JSON.stringify(row)).length;
    if (size > 900_000) throw new Error("Source record exceeded the import size limit");
    if (chunk.length >= 2000 || bytes + size > 900_000) flush();
    chunk.push(row); bytes += size;
  }
  flush();
  return statements;
}

// A trade cannot postdate the report that discloses it. Filers early in a year sometimes type the
// new year on a December trade ("12/26/2026" on a February 2026 report); when the prior year
// lands inside the 45-day filing window, that is the date used and the original stays in the raw
// record. Any other future date is unusable and the row is skipped.
export function reportedTransactionDate(transactionDate, reportDate) {
  if (!transactionDate || !reportDate || transactionDate <= reportDate) return transactionDate;
  const prior = `${Number(transactionDate.slice(0, 4)) - 1}${transactionDate.slice(4)}`;
  const lag = (Date.parse(reportDate) - Date.parse(prior)) / 86_400_000;
  return validDateOnly(prior) && lag >= 0 && lag <= 45 ? prior : null;
}
