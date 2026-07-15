const FALLBACK_SOURCE_URL = "https://apify.com/ryanclinton/congress-stock-tracker";

export function normalizeName(value = "") {
  return value
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/\b(hon|honorable|senator|sen|representative|rep)\b\.?/gi, " ")
    .replace(/[^a-zA-Z0-9]+/g, " ")
    .trim()
    .toLowerCase();
}

export function normalizeApifyTrade(record, observedAt = new Date().toISOString()) {
  if (record?.recordType !== "trade") return null;
  const representative = String(record.member ?? "").trim();
  const transactionDate = dateOnly(record.transactionDate);
  const reportDate = dateOnly(record.disclosureDate);
  const ticker = String(record.ticker ?? "").trim().toUpperCase();
  if (!representative || !transactionDate || !reportDate || !ticker) return null;

  const transactionType = normalizeTransaction(record.transactionSide);
  const owner = normalizeOwner(record.owner);
  const amountRange = String(record.amount ?? "Not reported");
  const identity = String(record.eventId ?? [
    representative, ticker, transactionDate, reportDate, transactionType, amountRange, owner, record.docId
  ].join("|"));

  return {
    id: stableUUID(identity),
    provider: "apify",
    politicianID: null,
    representative,
    reportDate,
    transactionDate,
    ticker,
    assetName: String(record.assetDescription ?? ticker),
    transactionType,
    owner,
    amountRange,
    chamber: nullable(record.chamber),
    party: nullable(record.party),
    sourceURL: String(record.filingUrl ?? FALLBACK_SOURCE_URL),
    rawJSON: JSON.stringify(record),
    observedAt,
    updatedAt: observedAt
  };
}

export function normalizeApifyFiling(record, observedAt = new Date().toISOString()) {
  if (record?.recordType !== "filing") return null;
  const representative = String(record.member ?? "").trim();
  const disclosureDate = dateOnly(record.disclosureDate);
  const filingURL = String(record.filingUrl ?? "");
  if (!representative || !disclosureDate || !filingURL) return null;
  const identity = String(record.eventId ?? [representative, disclosureDate, filingURL, record.docId].join("|"));
  return {
    id: stableUUID(identity),
    provider: "apify",
    representative,
    chamber: nullable(record.chamber),
    disclosureDate,
    filingURL,
    docID: nullable(record.docId),
    extractionStatus: nullable(record.extractionStatus),
    rawJSON: JSON.stringify(record),
    observedAt,
    updatedAt: observedAt
  };
}

function nullable(value) {
  return value === null || value === undefined || value === "" ? null : String(value);
}

function dateOnly(value) {
  if (!value) return null;
  const text = String(value).trim();
  const isoMatch = text.match(/^\d{4}-\d{2}-\d{2}/);
  if (isoMatch) return isoMatch[0];
  const usMatch = text.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/);
  if (usMatch) {
    const [, month, day, year] = usMatch;
    return `${year}-${month.padStart(2, "0")}-${day.padStart(2, "0")}`;
  }
  const date = new Date(value);
  return Number.isNaN(date.valueOf()) ? null : date.toISOString().slice(0, 10);
}

function normalizeTransaction(value = "") {
  const text = String(value).toLowerCase();
  if (text.includes("sale")) return "sale";
  if (text.includes("exchange")) return "exchange";
  return "purchase";
}

function normalizeOwner(value = "") {
  const text = String(value).toLowerCase();
  if (text.includes("spouse") || text === "sp") return "spouse";
  if (text.includes("dependent") || text.includes("child") || text === "dc") return "dependent";
  if (text.includes("joint") || text === "jt") return "joint";
  return "member";
}

function stableUUID(value) {
  const chunks = [2166136261, 2246822519, 3266489917, 668265263].map((seed) => {
    let hash = seed >>> 0;
    for (let index = 0; index < value.length; index += 1) {
      hash ^= value.charCodeAt(index);
      hash = Math.imul(hash, 16777619) >>> 0;
    }
    return hash.toString(16).padStart(8, "0");
  });
  const hex = chunks.join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-4${hex.slice(13, 16)}-a${hex.slice(17, 20)}-${hex.slice(20, 32)}`;
}
