import {
  dateOnly, normalizeOwner, normalizeTransaction, stableUUID
} from "./normalization.js";
import { strFromU8, unzipSync } from "fflate";

const HOUSE_BASE = "https://disclosures-clerk.house.gov";
const APIFY_BASE = "https://api.apify.com";
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

export async function collectApifyDisclosures(env, input = {}) {
  if (!env.APIFY_API_TOKEN) return { filings: [], disclosures: [] };
  const runID = input.runID ?? env.APIFY_RUN_ID;
  const payload = runID
    ? await fetchApifyRunDataset(env, runID, {
      offset: input.datasetOffset,
      limit: input.datasetLimit
    })
    : (await Promise.all(apifyInputs(input).map((actorInput) =>
      runApifyActor(env, actorInput)
    ))).flat();
  if (!Array.isArray(payload)) throw new Error("Apify returned an unexpected dataset payload");
  return { ...normalizeApifyDataset(payload), itemsSeen: payload.length };
}

export function normalizeApifyDataset(payload) {
  const filings = [];
  const records = [];
  for (const row of payload) {
    const representative = String(row.memberName ?? row.member ?? "").trim().slice(0, 300);
    const chamber = normalizeChamber(row.chamber);
    const reportDate = dateOnly(row.dateSubmitted ?? row.filingDate ?? row.disclosureDate);
    const state = normalizeState(row.state ?? row.memberState ?? row.stateCode);
    const district = normalizeDistrict(row.district ?? row.congressionalDistrict);
    const party = normalizeParty(row.party ?? row.partyRegistration);
    const sourceURL = String(row.documentUrl ?? row.filingUrl ?? "");
    const sourceHosts = chamber === "house"
      ? ["disclosures-clerk.house.gov"]
      : ["efdsearch.senate.gov"];
    if (!representative || !chamber || !reportDate || !isTrustedURL(sourceURL, sourceHosts)) continue;

    const filingID = stableUUID(`apify-filing|${sourceURL}`);
    filings.push({
      id: filingID,
      provider: "apify",
      representative,
      chamber,
      disclosureDate: reportDate,
      filingURL: sourceURL,
      docID: documentIdentifier(sourceURL),
      extractionStatus: Array.isArray(row.transactions) ? "transactions-extracted" : "official-metadata",
      rawJSON: JSON.stringify(row)
    });

    const transactions = Array.isArray(row.transactions) ? row.transactions : [];
    for (const transaction of transactions) {
      const ticker = String(transaction.ticker ?? "").trim().toUpperCase();
      const transactionDate = dateOnly(transaction.transactionDate);
      const transactionType = normalizeTransaction(transaction.transactionType);
      const owner = normalizeOwner(transaction.owner);
      if (
        !ticker || !transactionDate || !transactionType || !owner
        || !/^[A-Z0-9.^:-]{1,20}$/.test(ticker)
      ) continue;
      const amountRange = String(transaction.amount ?? "Not reported").slice(0, 100);
      const assetName = String(transaction.assetName ?? ticker).trim().slice(0, 500);
      const identity = [
        filingID, ticker, transactionDate, transactionType, amountRange, owner, assetName
      ].join("|");
      records.push({
        id: stableUUID(`apify-trade|${identity}`),
        provider: "apify",
        politicianID: null,
        representative,
        reportDate,
        transactionDate,
        ticker,
        assetName,
        transactionType,
        owner,
        amountRange,
        chamber,
        party,
        state,
        district,
        matchConfidence: null,
        sourceURL,
        confidence: 0.95,
        rawJSON: JSON.stringify({ filing: row, transaction })
      });
    }
  }
  return { filings, disclosures: records };
}

export async function collectTruthPosts(env) {
  if (env.TRUTH_APIFY_ACTOR_ID && env.APIFY_API_TOKEN) {
    const payload = await runApifyActorByID(env, env.TRUTH_APIFY_ACTOR_ID, {
      query: "realDonaldTrump",
      maxResults: clampInteger(env.TRUTH_MAX_RESULTS, 1, 500, 50),
      includeReplies: false,
      onlyNewSinceLastRun: true
    });
    return normalizeTruthRows(payload);
  }
  if (!env.TRUTH_API_URL || !env.TRUTH_API_TOKEN) return [];
  const response = await fetchWithTimeout(env.TRUTH_API_URL, {
    headers: { Authorization: `Bearer ${env.TRUTH_API_TOKEN}`, Accept: "application/json" }
  });
  if (!response.ok) throw new Error(`Truth API returned ${response.status}`);
  const payload = await response.json();
  const rows = Array.isArray(payload) ? payload : payload.data;
  if (!Array.isArray(rows)) throw new Error("Truth API returned an unexpected payload");
  return normalizeTruthRows(rows);
}

export function normalizeTruthRows(rows) {
  return rows.map((row) => {
    const sourceURL = String(row.url ?? row.sourceURL ?? row.sourceUrl ?? "");
    const publishedAt = safeISOString(row.publishedAt ?? row.createdAt ?? row.created_at);
    const body = String(row.contentText ?? row.text ?? row.content ?? row.body ?? "")
      .replace(/<[^>]+>/g, " ")
      .replace(/\s+/g, " ")
      .trim()
      .slice(0, 20_000);
    if (!publishedAt || !body || !isTrustedURL(sourceURL, [TRUTH_SOCIAL_HOST], true)) return null;
    const policyTopics = stringArray(row.policyTopics ?? row.hashtags, 30);
    const mentionedSymbols = stringArray(row.mentionedSymbols, 30)
      .map((symbol) => symbol.toUpperCase());
    return {
      id: stableUUID(`truth|${row.id ?? sourceURL}`),
      provider: "truth-api",
      author: String(
        row.author ?? row.authorDisplayName ?? row.authorUsername ?? row.account?.acct ?? "Donald J. Trump"
      ).slice(0, 300),
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

export function apifyInput(value = {}) {
  const currentYear = new Date().getUTCFullYear();
  return {
    chamber: ["house", "senate"].includes(value.chamber) ? value.chamber : "senate",
    fetchTransactions: true,
    filingType: "P",
    filingYear: clampInteger(value.filingYear, 2012, currentYear, currentYear),
    maxResults: clampInteger(value.maxResults, 1, 1_000, 1_000),
    query: typeof value.query === "string" ? value.query.trim().slice(0, 100) : "",
    state: typeof value.state === "string" ? value.state.trim().toUpperCase().slice(0, 2) : ""
  };
}

export function apifyInputs(value = {}) {
  if (value.chamber === "house" || value.chamber === "senate") {
    return [apifyInput(value)];
  }
  return [
    apifyInput({ ...value, chamber: "house" }),
    apifyInput({ ...value, chamber: "senate" })
  ];
}

async function runApifyActor(env, input) {
  const actorID = env.APIFY_ACTOR_ID || "4Y9oheOAZjMZ3gGqH";
  return runApifyActorByID(env, actorID, input);
}

async function runApifyActorByID(env, actorID, input) {
  const url = new URL(`/v2/acts/${encodeURIComponent(actorID)}/runs`, APIFY_BASE);
  url.searchParams.set("waitForFinish", "300");
  const response = await fetchWithTimeout(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.APIFY_API_TOKEN}`,
      Accept: "application/json",
      "Content-Type": "application/json"
    },
    body: JSON.stringify(input),
    signal: AbortSignal.timeout(310_000)
  });
  if (!response.ok) throw new Error(`Apify actor run returned ${response.status}`);
  const run = (await response.json()).data;
  if (run?.status !== "SUCCEEDED" || !run.defaultDatasetId) {
    throw new Error(`Apify actor run did not succeed: ${run?.status ?? "unknown"}`);
  }
  return fetchApifyDataset(env, run.defaultDatasetId);
}

async function fetchApifyRunDataset(env, runID, options = {}) {
  const runURL = new URL(`/v2/actor-runs/${encodeURIComponent(runID)}`, APIFY_BASE);
  const runResponse = await fetchWithTimeout(runURL, {
    headers: { Authorization: `Bearer ${env.APIFY_API_TOKEN}`, Accept: "application/json" }
  });
  if (!runResponse.ok) throw new Error(`Apify run returned ${runResponse.status}`);
  const run = (await runResponse.json()).data;
  if (run?.status !== "SUCCEEDED" || !run.defaultDatasetId) {
    throw new Error(`Apify run is not ready: ${run?.status ?? "unknown"}`);
  }
  return fetchApifyDataset(env, run.defaultDatasetId, options);
}

async function fetchApifyDataset(env, datasetID, options = {}) {
  const datasetURL = new URL(`/v2/datasets/${encodeURIComponent(datasetID)}/items`, APIFY_BASE);
  datasetURL.searchParams.set("clean", "true");
  if (Number.isInteger(options.offset) && options.offset >= 0) {
    datasetURL.searchParams.set("offset", String(options.offset));
  }
  if (Number.isInteger(options.limit) && options.limit >= 1 && options.limit <= 1_000) {
    datasetURL.searchParams.set("limit", String(options.limit));
  }
  const datasetResponse = await fetchWithTimeout(datasetURL, {
    headers: { Authorization: `Bearer ${env.APIFY_API_TOKEN}`, Accept: "application/json" }
  });
  if (!datasetResponse.ok) throw new Error(`Apify dataset returned ${datasetResponse.status}`);
  return datasetResponse.json();
}

function normalizeChamber(value) {
  const chamber = String(value ?? "").trim().toLowerCase();
  return chamber === "house" || chamber === "senate" ? chamber : null;
}

function normalizeState(value) {
  const state = String(value ?? "").trim().toUpperCase();
  return /^[A-Z]{2}$/.test(state) ? state : null;
}

function normalizeDistrict(value) {
  const district = Number(value);
  return Number.isInteger(district) && district >= 0 && district <= 99 ? district : null;
}

function normalizeParty(value) {
  const party = String(value ?? "").trim().slice(0, 100);
  return party || null;
}

function documentIdentifier(value) {
  try {
    return new URL(value).pathname.split("/").filter(Boolean).at(-1) ?? null;
  } catch {
    return null;
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

function clampInteger(value, minimum, maximum, fallback) {
  const number = Number(value);
  if (!Number.isInteger(number)) return fallback;
  return Math.min(Math.max(number, minimum), maximum);
}
