import { amountBounds } from "./normalization.js";

const DAY = 86_400_000;

export function rankDisclosure(record, now = new Date()) {
  const filedAt = parseDate(record.reportDate);
  const ageDays = filedAt ? Math.max(0, (now.valueOf() - filedAt.valueOf()) / DAY) : 365;
  const recency = clamp(1 - ageDays / 14);
  const bounds = amountBounds(record.amountRange);
  const materiality = clamp(Math.log10(Math.max(bounds.maximum, 1)) / 7);
  const political = record.committeeRelevance ? 1 : record.chamber ? 0.6 : 0.35;
  const market = clamp(Math.abs(Number(record.marketMovePercent ?? 0)) / 5);
  const confidence = clamp(Number(record.confidence ?? 0.9));
  const penalty = (record.isSuperseded ? 0.35 : 0) + (record.tickerAmbiguous ? 0.25 : 0);
  const score = clamp(
    recency * 0.30 + materiality * 0.25 + political * 0.20 + market * 0.15 + confidence * 0.10 - penalty
  );

  const reasons = [];
  if (recency >= 0.7) reasons.push("Newly public disclosure");
  if (materiality >= 0.65) reasons.push("Large reported value range");
  if (record.committeeRelevance) reasons.push("Relevant committee or policy connection");
  if (market >= 0.4) reasons.push("Notable current market volatility");
  if (confidence < 0.75) reasons.push("Extraction requires review");

  return { score: Number(score.toFixed(4)), reasons };
}

export function whyDisclosureMatters(record) {
  const reportDate = parseDate(record.reportDate);
  const transactionDate = parseDate(record.transactionDate);
  const lag = reportDate && transactionDate
    ? Math.max(0, Math.round((reportDate.valueOf() - transactionDate.valueOf()) / DAY))
    : null;
  const action = record.transactionType === "purchase" ? "purchase" : record.transactionType;
  const context = record.marketMovePercent == null
    ? "Market context has not yet been attached."
    : `${record.ticker}'s latest licensed quote showed a ${signed(record.marketMovePercent)} session move. This is current context, not an event-window reaction or evidence of causation.`;
  const timing = lag == null
    ? "The source dates require review."
    : `The transaction preceded public disclosure by ${lag} days.`;
  const chamber = record.chamber === "senate" ? "Senate" : record.chamber === "house" ? "House" : "congressional";
  // Bonds, funds, and private holdings often have no ticker.
  const named = !record.ticker || String(record.assetName ?? "").includes(`(${record.ticker})`)
    ? record.assetName
    : `${record.assetName} (${record.ticker})`;
  const asset = record.assetType === "OP" ? `options on ${named}` : named;
  return `A ${chamber} filing reported a ${action} of ${asset} in the ${record.amountRange} range. ${timing} ${context}`;
}

// Scores depend on the current time, so stored scores go stale as filings age.
// Re-derive them whenever records are served or periodically re-persisted.
export function rescoreDisclosure(record, marketMovePercent = null, now = new Date()) {
  const enriched = { ...record, marketMovePercent };
  const ranking = rankDisclosure(enriched, now);
  return {
    ...record,
    rankingScore: ranking.score,
    rankingReasons: ranking.reasons,
    whyItMatters: whyDisclosureMatters(enriched)
  };
}

export function rankSocialPost(record, now = new Date()) {
  const publishedAt = parseDate(record.publishedAt);
  const ageHours = publishedAt ? Math.max(0, (now.valueOf() - publishedAt.valueOf()) / 3_600_000) : 168;
  const recency = clamp(1 - ageHours / 24);
  const market = clamp(Math.abs(Number(record.marketMovePercent ?? 0)) / 5);
  const political = record.policyTopics?.length ? 0.9 : 0.5;
  const confidence = clamp(Number(record.confidence ?? 0.8));
  const score = clamp(recency * 0.30 + 0.35 * 0.25 + political * 0.20 + market * 0.15 + confidence * 0.10);
  const reasons = ["New political statement"];
  if (record.policyTopics?.length) reasons.push("Mapped to policy-sensitive sectors");
  if (market >= 0.4) reasons.push("Notable current market volatility");
  return { score: Number(score.toFixed(4)), reasons };
}

function signed(value) {
  const number = Number(value);
  return `${number >= 0 ? "+" : ""}${number.toFixed(2)}%`;
}

function parseDate(value) {
  if (!value) return null;
  const text = String(value);
  const date = new Date(/^\d{4}-\d{2}-\d{2}$/.test(text) ? `${text}T12:00:00Z` : text);
  return Number.isNaN(date.valueOf()) ? null : date;
}

function clamp(value, minimum = 0, maximum = 1) {
  return Math.min(Math.max(Number(value) || 0, minimum), maximum);
}
