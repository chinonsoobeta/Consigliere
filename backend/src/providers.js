import {
  dateOnly, normalizeOwner, normalizeTransaction, stableUUID
} from "./normalization.js";
import { strFromU8, unzipSync } from "fflate";

const HOUSE_BASE = "https://disclosures-clerk.house.gov";
const TRUTH_SOCIAL_HOST = "truthsocial.com";
const REQUEST_TIMEOUT_MS = 20_000;
const MAX_HOUSE_ARCHIVE_BYTES = 10 * 1024 * 1024;

export async function collectOfficialFilings(env, year = new Date().getUTCFullYear()) {
  const filings = [];
  const failures = [];
  try {
    filings.push(...await collectHouseIndex(env, year));
  } catch (error) {
    failures.push({ provider: "house", error: String(error?.message ?? error) });
  }
  try {
    filings.push(...await collectSenateFeed(env));
  } catch (error) {
    failures.push({ provider: "senate", error: String(error?.message ?? error) });
  }
  return { filings, failures };
}

async function collectHouseIndex(env, year) {
  const configured = env.HOUSE_INDEX_URL;
  const url = configured || `${HOUSE_BASE}/public_disc/financial-pdfs/${year}FD.zip`;
  const response = await fetchWithTimeout(url, { headers: publisherHeaders(env) });
  if (!response.ok) throw new Error(`House index returned ${response.status}`);
  const declaredLength = Number(response.headers.get("content-length") ?? 0);
  if (declaredLength > MAX_HOUSE_ARCHIVE_BYTES) throw new Error("House index exceeded the size limit");
  const bytes = new Uint8Array(await response.arrayBuffer());
  if (bytes.byteLength > MAX_HOUSE_ARCHIVE_BYTES) throw new Error("House index exceeded the size limit");
  const isArchive = /\.zip(?:$|\?)/i.test(url) || (bytes[0] === 0x50 && bytes[1] === 0x4b);
  const text = isArchive ? houseIndexFromArchive(bytes, year) : new TextDecoder().decode(bytes);
  return parseHouseIndex(text, year);
}

export function houseIndexFromArchive(bytes, year) {
  const archive = unzipSync(bytes);
  const expectedName = `${year}FD.txt`;
  const entry = archive[expectedName]
    ?? Object.entries(archive).find(([name]) => name.toLowerCase().endsWith("fd.txt"))?.[1];
  if (!entry) throw new Error("House archive did not contain a disclosure index");
  return strFromU8(entry);
}

export function parseHouseIndex(text, year) {
  const lines = String(text).replaceAll("\u0000", "").split(/\r?\n/).filter(Boolean);
  return lines.slice(1).map((line) => {
    const fields = line.split("\t");
    if (fields.length < 8) return null;
    const [prefix, last, first, suffix, filingType, stateDistrict, yearFiled, filingDate, docID] = fields;
    if (!(String(filingType).trim().toUpperCase() === "P" || /periodic transaction/i.test(filingType ?? ""))) {
      return null;
    }
    const representative = [prefix, first, last, suffix].filter(Boolean).join(" ").trim();
    const disclosureDate = dateOnly(filingDate);
    if (!representative || !disclosureDate || !docID) return null;
    const filingURL = `${HOUSE_BASE}/public_disc/ptr-pdfs/${year}/${docID}.pdf`;
    return {
      id: stableUUID(`house|${docID}`),
      provider: "house",
      representative,
      chamber: "house",
      disclosureDate,
      filingURL,
      docID,
      extractionStatus: "official-metadata",
      rawJSON: JSON.stringify({ prefix, last, first, suffix, filingType, stateDistrict, yearFiled, filingDate, docID })
    };
  }).filter(Boolean);
}

async function collectSenateFeed(env) {
  if (!env.SENATE_EFD_FEED_URL) {
    throw new Error("SENATE_EFD_FEED_URL is not configured; Senate eFD requires a compliant collector endpoint");
  }
  const response = await fetchWithTimeout(env.SENATE_EFD_FEED_URL, { headers: publisherHeaders(env) });
  if (!response.ok) throw new Error(`Senate collector returned ${response.status}`);
  const payload = await response.json();
  if (!Array.isArray(payload)) throw new Error("Senate collector returned an unexpected payload");
  return payload.map((row) => {
    const representative = String(row.representative ?? row.member ?? "").trim();
    const disclosureDate = dateOnly(row.disclosureDate ?? row.filedDate);
    const filingURL = String(row.filingURL ?? row.sourceURL ?? "");
    if (!representative || !disclosureDate || !isTrustedURL(filingURL, ["efdsearch.senate.gov"])) return null;
    return {
      id: stableUUID(`senate|${row.docID ?? filingURL}`),
      provider: "senate",
      representative,
      chamber: "senate",
      disclosureDate,
      filingURL,
      docID: row.docID ? String(row.docID) : null,
      extractionStatus: String(row.extractionStatus ?? "official-metadata"),
      rawJSON: JSON.stringify(row)
    };
  }).filter(Boolean);
}

export async function collectFMPDisclosures(env) {
  if (!env.FMP_API_KEY) return [];
  const endpoints = [
    ["house", "house-latest"],
    ["senate", "senate-latest"]
  ];
  const records = [];
  for (const [chamber, endpoint] of endpoints) {
    const url = new URL(`/stable/${endpoint}`, env.FMP_BASE_URL || "https://financialmodelingprep.com");
    url.searchParams.set("page", "0");
    url.searchParams.set("limit", "250");
    url.searchParams.set("apikey", env.FMP_API_KEY);
    const response = await fetchWithTimeout(url);
    if (!response.ok) throw new Error(`FMP ${chamber} endpoint returned ${response.status}`);
    const payload = await response.json();
    if (!Array.isArray(payload)) throw new Error(`FMP ${chamber} endpoint returned an unexpected payload`);
    for (const row of payload) {
      const representative = [row.firstName, row.lastName].filter(Boolean).join(" ").trim() || String(row.office ?? "");
      const ticker = String(row.symbol ?? "").trim().toUpperCase();
      const transactionDate = dateOnly(row.transactionDate);
      const reportDate = dateOnly(row.disclosureDate);
      const sourceURL = String(row.link ?? "");
      const sourceHosts = chamber === "house"
        ? ["disclosures-clerk.house.gov"]
        : ["efdsearch.senate.gov"];
      if (
        !representative || !ticker || !transactionDate || !reportDate
        || !isTrustedURL(sourceURL, sourceHosts)
      ) continue;
      const transactionType = normalizeTransaction(row.type);
      const owner = normalizeOwner(row.owner);
      if (!transactionType || !owner || !/^[A-Z0-9.^:-]{1,20}$/.test(ticker)) continue;
      const amountRange = String(row.amount ?? "Not reported");
      const identity = [chamber, representative, ticker, transactionDate, reportDate, transactionType, amountRange, owner].join("|");
      records.push({
        id: stableUUID(identity),
        provider: "fmp-reconciliation",
        politicianID: null,
        representative: representative.slice(0, 300),
        reportDate,
        transactionDate,
        ticker,
        assetName: String(row.assetDescription ?? ticker).slice(0, 500),
        transactionType,
        owner,
        amountRange,
        chamber,
        party: null,
        sourceURL,
        confidence: 0.9,
        rawJSON: JSON.stringify(row)
      });
    }
  }
  return records;
}

export async function collectTruthPosts(env) {
  if (!env.TRUTH_API_URL || !env.TRUTH_API_TOKEN) return [];
  const response = await fetchWithTimeout(env.TRUTH_API_URL, {
    headers: { Authorization: `Bearer ${env.TRUTH_API_TOKEN}`, Accept: "application/json" }
  });
  if (!response.ok) throw new Error(`Truth API returned ${response.status}`);
  const payload = await response.json();
  const rows = Array.isArray(payload) ? payload : payload.data;
  if (!Array.isArray(rows)) throw new Error("Truth API returned an unexpected payload");
  return rows.map((row) => {
    const sourceURL = String(row.url ?? row.sourceURL ?? "");
    const publishedAt = safeISOString(row.publishedAt ?? row.created_at);
    const body = String(row.contentText ?? row.text ?? row.content ?? "")
      .replace(/<[^>]+>/g, " ")
      .replace(/\s+/g, " ")
      .trim()
      .slice(0, 20_000);
    if (!publishedAt || !body || !isTrustedURL(sourceURL, [TRUTH_SOCIAL_HOST], true)) return null;
    const policyTopics = stringArray(row.policyTopics, 30);
    const mentionedSymbols = stringArray(row.mentionedSymbols, 30)
      .map((symbol) => symbol.toUpperCase());
    return {
      id: stableUUID(`truth|${row.id ?? sourceURL}`),
      provider: "truth-api",
      author: String(row.author ?? row.account?.acct ?? "Truth Social").slice(0, 300),
      body,
      sourceURL,
      publishedAt,
      retrievedAt: new Date().toISOString(),
      editedAt: safeISOString(row.editedAt ?? row.edited_at),
      deletedAt: safeISOString(row.deletedAt),
      policyTopics,
      mentionedSymbols,
      confidence: 0.8,
      rawJSON: JSON.stringify(row)
    };
  }).filter(Boolean);
}

export async function collectMarketData(env) {
  if (!env.TWELVE_DATA_API_KEY) return [];
  const symbols = String(env.MARKET_SYMBOLS || "SPY,QQQ,DIA,IXIC,TSX:TSX")
    .split(",").map((value) => value.trim()).filter(Boolean);
  const records = [];
  for (const symbol of symbols) {
    const url = new URL("/quote", env.TWELVE_DATA_BASE_URL || "https://api.twelvedata.com");
    url.searchParams.set("symbol", symbol);
    url.searchParams.set("apikey", env.TWELVE_DATA_API_KEY);
    const response = await fetchWithTimeout(url);
    if (!response.ok) throw new Error(`Twelve Data quote returned ${response.status}`);
    const row = await response.json();
    if (row.status === "error") throw new Error(row.message || "Twelve Data error");
    records.push({
      symbol: String(row.symbol ?? symbol),
      name: String(row.name ?? row.symbol ?? symbol),
      exchange: String(row.exchange ?? "Unknown"),
      currency: String(row.currency ?? "USD"),
      region: inferRegion(row.country),
      kind: inferKind(row.type),
      price: Number(row.close ?? row.price),
      changePercent: Number(row.percent_change ?? 0),
      updatedAt: safeISOString(row.datetime) ?? new Date().toISOString(),
      sector: row.sector ?? null,
      provider: "twelve-data",
      attribution: "Data provided by Twelve Data",
      rawJSON: JSON.stringify(row)
    });
  }
  return records.filter((row) => Number.isFinite(row.price));
}

function publisherHeaders(env) {
  return {
    Accept: "text/plain,text/html,application/json",
    "User-Agent": env.PUBLISHER_USER_AGENT || "Consigliere/1.0 public-interest research publisher"
  };
}

export function isTrustedURL(value, allowedHosts, allowSubdomains = false) {
  try {
    const url = new URL(value);
    if (url.protocol !== "https:" || url.username || url.password) return false;
    const hostname = url.hostname.toLowerCase();
    return allowedHosts.some((allowedHost) => {
      const allowed = allowedHost.toLowerCase();
      return hostname === allowed || (allowSubdomains && hostname.endsWith(`.${allowed}`));
    });
  } catch {
    return false;
  }
}

function safeISOString(value) {
  if (!value) return null;
  const date = new Date(value);
  return Number.isNaN(date.valueOf()) ? null : date.toISOString();
}

function stringArray(value, maximumItems) {
  if (!Array.isArray(value)) return [];
  return value
    .filter((item) => typeof item === "string")
    .map((item) => item.trim().slice(0, 200))
    .filter(Boolean)
    .slice(0, maximumItems);
}

async function fetchWithTimeout(input, init = {}) {
  return fetch(input, {
    ...init,
    signal: init.signal ?? AbortSignal.timeout(REQUEST_TIMEOUT_MS)
  });
}

function inferRegion(country = "") {
  return /canada|united states/i.test(country) ? "northAmerica" : "global";
}

function inferKind(type = "") {
  const value = String(type).toLowerCase();
  if (value.includes("etf")) return "etf";
  if (value.includes("index")) return "index";
  if (value.includes("currency") || value.includes("forex")) return "currency";
  return "equity";
}
