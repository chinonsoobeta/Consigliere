import test from "node:test";
import assert from "node:assert/strict";
import { strToU8, zipSync } from "fflate";
import {
  apifyInput, apifyInputs, houseIndexFromArchive, isTrustedURL, normalizeApifyDataset, parseHouseIndex
} from "../src/providers.js";
import { dateOnly, normalizeOwner, normalizeTransaction } from "../src/normalization.js";
import { rankDisclosure, whyDisclosureMatters } from "../src/ranking.js";

test("parses official House PTR metadata and ignores non-PTR filings", () => {
  const text = [
    "Prefix\tLast\tFirst\tSuffix\tFilingType\tStateDistrict\tYear\tFilingDate\tDocID",
    "Hon.\tPelosi\tNancy\t\tP\tCA11\t2026\t07/14/2026\t20030001",
    "Hon.\tPelosi\tNancy\t\tA\tCA11\t2026\t07/14/2026\t20030002"
  ].join("\n");
  const rows = parseHouseIndex(text, 2026);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].chamber, "house");
  assert.match(rows[0].filingURL, /ptr-pdfs\/2026\/20030001\.pdf$/);
});

test("extracts the text index from the official House ZIP layout", () => {
  const index = [
    "Prefix\tLast\tFirst\tSuffix\tFilingType\tStateDistrict\tYear\tFilingDate\tDocID",
    "Hon.\tPelosi\tNancy\t\tP\tCA11\t2026\t07/14/2026\t20030001"
  ].join("\n");
  const archive = zipSync({
    "2026FD.txt": strToU8(index),
    "2026FD.xml": strToU8("<FinancialDisclosure />")
  });
  assert.equal(houseIndexFromArchive(archive, 2026), index);
});

test("rejects lookalike, credentialed, and non-HTTPS source URLs", () => {
  assert.equal(isTrustedURL("https://efdsearch.senate.gov/search/view/ptr/x", ["efdsearch.senate.gov"]), true);
  assert.equal(isTrustedURL("https://efdsearch.senate.gov.evil.example/x", ["efdsearch.senate.gov"]), false);
  assert.equal(isTrustedURL("https://user:pass@efdsearch.senate.gov/x", ["efdsearch.senate.gov"]), false);
  assert.equal(isTrustedURL("http://efdsearch.senate.gov/x", ["efdsearch.senate.gov"]), false);
});

test("ranking favors newly public, material, high-confidence records", () => {
  const record = {
    reportDate: "2026-07-15",
    transactionDate: "2026-06-30",
    amountRange: "$1,000,001 - $5,000,000",
    chamber: "house",
    ticker: "NVDA",
    assetName: "NVIDIA Corporation",
    transactionType: "purchase",
    confidence: 0.95,
    committeeRelevance: true,
    marketMovePercent: 2.4
  };
  const ranking = rankDisclosure(record, new Date("2026-07-16T12:00:00Z"));
  assert.ok(ranking.score > 0.75);
  assert.ok(ranking.reasons.includes("Newly public disclosure"));
  assert.match(whyDisclosureMatters(record), /not an event-window reaction or evidence of causation/);
});

test("invalid dates do not produce NaN in published explanations", () => {
  const explanation = whyDisclosureMatters({
    reportDate: "not-a-date",
    transactionDate: "also-invalid",
    amountRange: "$1,001 - $15,000",
    chamber: "house",
    ticker: "TEST",
    assetName: "Test asset",
    transactionType: "purchase"
  });
  assert.doesNotMatch(explanation, /NaN/);
  assert.match(explanation, /require review/);
});

test("normalization rejects impossible dates and unknown categorical values", () => {
  assert.equal(dateOnly("02/29/2024"), "2024-02-29");
  assert.equal(dateOnly("02/29/2023"), null);
  assert.equal(dateOnly("2026-13-01"), null);
  assert.equal(normalizeTransaction("gift"), null);
  assert.equal(normalizeOwner("mystery trust"), null);
});

test("normalizes the configured Apify actor's nested PTR schema", () => {
  const result = normalizeApifyDataset([{
    memberName: "Thomas H Tuberville",
    chamber: "Senate",
    filingYear: 2026,
    filingType: "P",
    documentUrl: "https://efdsearch.senate.gov/search/view/ptr/392ac3e5-07f6-4f8c-840f-84e9066ffb29/",
    dateSubmitted: "07/16/2026",
    transactions: [{
      owner: "Self",
      assetName: "Westinghouse Air Brake Technologies Corporation Common Stock",
      ticker: "WAB",
      transactionType: "Sale (Full)",
      transactionDate: "06/09/2026",
      amount: "$1,001 - $15,000"
    }, {
      owner: "Joint",
      assetName: "Tickerless asset",
      transactionType: "Purchase",
      transactionDate: "06/08/2026",
      amount: "$1,001 - $15,000"
    }]
  }]);

  assert.equal(result.filings.length, 1);
  assert.equal(result.filings[0].chamber, "senate");
  assert.equal(result.disclosures.length, 1);
  assert.equal(result.disclosures[0].ticker, "WAB");
  assert.equal(result.disclosures[0].transactionType, "sale");
  assert.equal(result.disclosures[0].owner, "member");
  assert.equal(result.disclosures[0].reportDate, "2026-07-16");
});

test("constrains Apify actor inputs to supported values", () => {
  assert.deepEqual(apifyInput({
    chamber: "invalid",
    filingYear: 1900,
    maxResults: 5_000,
    query: "x".repeat(200),
    state: "california"
  }), {
    chamber: "senate",
    fetchTransactions: true,
    filingType: "P",
    filingYear: 2008,
    maxResults: 500,
    query: "x".repeat(100),
    state: "CA"
  });
  assert.deepEqual(apifyInputs({ filingYear: 2026 }).map((input) => input.chamber), ["house", "senate"]);
  assert.equal(apifyInput({}).maxResults, 50);
});
