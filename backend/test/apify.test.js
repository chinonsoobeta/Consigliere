import test from "node:test";
import assert from "node:assert/strict";
import { normalizeApifyFiling, normalizeApifyTrade, normalizeName } from "../src/apify.js";

test("normalizes an Apify trade record", () => {
  const trade = normalizeApifyTrade({
    recordType: "trade",
    eventId: "house-2024-123-nvda",
    member: "Hon. Nancy Pelosi",
    chamber: "house",
    party: "Democrat",
    ticker: "nvda",
    assetDescription: "NVIDIA Corporation",
    transactionSide: "PARTIAL_SALE",
    transactionDate: "6/24/2024",
    disclosureDate: "7/2/2024",
    amount: "$1,000,001 - $5,000,000",
    owner: "Spouse",
    filingUrl: "https://example.com/filing.pdf"
  }, "2026-07-14T12:00:00.000Z");

  assert.equal(trade.representative, "Hon. Nancy Pelosi");
  assert.equal(trade.ticker, "NVDA");
  assert.equal(trade.transactionType, "sale");
  assert.equal(trade.owner, "spouse");
  assert.equal(trade.transactionDate, "2024-06-24");
  assert.equal(trade.reportDate, "2024-07-02");
  assert.match(trade.id, /^[0-9a-f-]{36}$/);
});

test("preserves filing-only records instead of fabricating trades", () => {
  const filing = normalizeApifyFiling({
    recordType: "filing",
    member: "Example Senator",
    chamber: "senate",
    disclosureDate: "2026-07-10",
    filingUrl: "https://efdsearch.senate.gov/example",
    extractionStatus: "metadata-only"
  });

  assert.equal(filing.extractionStatus, "metadata-only");
  assert.equal(normalizeApifyTrade({ recordType: "filing" }), null);
});

test("normalizes congressional honorifics for identity matching", () => {
  assert.equal(normalizeName("Hon. Nancy Pelosi"), "nancy pelosi");
  assert.equal(normalizeName("Sen. Tommy Tuberville"), "tommy tuberville");
});
