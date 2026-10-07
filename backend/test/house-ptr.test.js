import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import {
  housePTRDisclosures, isElectronicHouseFiling, parseHouseAsset, parseHousePTRItems, readHousePTR
} from "../src/house-ptr.js";
import { whyDisclosureMatters } from "../src/ranking.js";

const fixture = async (docID) => readHousePTR(await readFile(new URL(`./fixtures/${docID}.pdf`, import.meta.url)));

test("reads a multi-page report whose rows and asset names continue across page breaks", async () => {
  const report = await fixture("20035326");
  assert.equal(report.filingID, "20035326");
  assert.equal(report.name, "Hon. Kevin Hern");
  assert.equal(report.stateDistrict, "OK01");
  assert.deepEqual(report.warnings, []);
  assert.equal(report.transactions.length, 29);

  const [adobe] = report.transactions;
  assert.equal(adobe.ticker, "ADBE");
  assert.equal(adobe.owner, "joint");
  assert.equal(adobe.transactionType, "sale");
  assert.equal(adobe.partial, true);
  assert.equal(adobe.transactionDate, "2026-08-14");
  assert.equal(adobe.amountRange, "$15,001 - $50,000");
  assert.equal(adobe.subholding, "Hern Family Foundation");

  // A three-line municipal bond with no ticker, at the top of page 2.
  const bond = report.transactions.find((row) => row.assetType === "GS");
  assert.equal(bond.assetName, "CANADIAN CNTY OKLA EDL FACS AUTH EDL 3.00000% 09/01/2029");
  assert.equal(bond.ticker, null);
  assert.equal(bond.amountRange, "$100,001 - $250,000");

  // A blank owner column is the member's own account.
  assert.equal(report.transactions.find((row) => row.ticker === "ALC").owner, "member");
});

test("keeps option trades distinct from stock and reads their descriptions", async () => {
  const report = await fixture("20035455");
  const options = report.transactions.filter((row) => row.assetType === "OP");
  assert.equal(options.length, 4);
  assert.ok(options.every((row) => row.ticker === "MSFT"));
  assert.equal(options[0].description, "Call options; Strike price $340; Expires 10/16/2026");
  assert.equal(options[1].amountRange, "$500,001 - $1,000,000");
});

test("reads amendments, row IDs, wrapped descriptions, and filer-typed asset codes", async () => {
  const report = await fixture("20035445");
  assert.equal(report.transactions.length, 1);
  const [row] = report.transactions;
  assert.equal(row.rowID, "2000140446");
  assert.equal(row.filingStatus, "Amended");
  assert.equal(row.assetName, "American Funds AMCAP Fund Class A M/F");
  assert.equal(row.assetType, "OT");
  // The fund named in the description is the one the original report got wrong, not this row's.
  assert.equal(row.ticker, null);
  assert.match(row.description, /misidentified .* \(SMCWX\) when it should have been identified as American Funds/);
});

test("a wrapped transaction type continues its row instead of starting a new one", () => {
  const header = [["ID", 25], ["Owner", 65], ["Asset", 104], ["Transaction", 261], ["Date", 325],
    ["Notification", 381], ["Amount", 446], ["Cap.", 525]].map(([text, x]) => ({ page: 1, x, y: 100, text }));
  const row = (y, cells) => cells.map(([x, text]) => ({ page: 1, x, y, text }));
  const report = parseHousePTRItems([
    { page: 1, x: 484, y: 80, text: "Filing ID #20039999" },
    ...header,
    ...row(130, [[65, "SP"], [104, "Example Corp (EXM)"], [261, "S"], [325, "08/01/2026"],
      [381, "08/02/2026"], [446, "$1,001 -"]]),
    ...row(140, [[104, "[ST]"], [261, "(partial)"], [446, "$15,000"]]),
    ...row(160, [[104, "F\u0000\u0000 S\u0000\u0000: New"]]),
    { page: 1, x: 25, y: 200, text: "* For the complete list of asset type abbreviations, please visit …" }
  ]);
  assert.deepEqual(report.warnings, []);
  assert.equal(report.transactions.length, 1);
  assert.equal(report.transactions[0].partial, true);
  assert.equal(report.transactions[0].owner, "spouse");
  assert.equal(report.transactions[0].amountRange, "$1,001 - $15,000");
  assert.equal(report.transactions[0].filingStatus, "New");
});

test("parses tickers from the end of asset names only", () => {
  assert.equal(parseHouseAsset("Berkshire Hathaway Inc. (BRK/B) [ST]").ticker, "BRK.B");
  assert.equal(parseHouseAsset("Colgate-Palmolive Company Common Stock (CL) [ST]").ticker, "CL");
  assert.equal(parseHouseAsset("AT&T Inc. Depositary Shares, Series A (T$A) [ST]").ticker, "T$A");
  assert.equal(parseHouseAsset("Cliffwater Corporate Lending Fund (Ticker: CCLFX) [OT]").ticker, "CCLFX");
  assert.equal(parseHouseAsset("Taiwan Semiconductor (ADR) [ST]").ticker, null);
  assert.equal(parseHouseAsset("US Treasury Note 4% DUE 5/31/30 (91282CNG2) [GS]").ticker, null);
  assert.equal(parseHouseAsset("SL PARTNERS VII (ICAPITAL), L.P. FUND [HN]").ticker, null);
});

test("only e-filed report IDs are read; paper scans have no text layer", () => {
  assert.equal(isElectronicHouseFiling("20035445"), true);
  assert.equal(isElectronicHouseFiling("9116342"), false);
  assert.equal(isElectronicHouseFiling("8221045"), false);
});

test("disclosure rows use the index's filer, keep repeated trades, and stay stable", async () => {
  const report = await fixture("20035326");
  const filing = {
    docID: "20035326", disclosureDate: "2026-08-27",
    filingURL: "https://disclosures-clerk.house.gov/public_disc/ptr-pdfs/2026/20035326.pdf",
    representative: "Hon. Kevin Hern",
    rawJSON: JSON.stringify({ prefix: "Hon.", first: "Kevin", last: "Hern", suffix: "", stateDistrict: "OK01" })
  };
  const rows = housePTRDisclosures(report, filing);
  assert.equal(rows.length, 29);
  assert.equal(new Set(rows.map((row) => row.id)).size, 29);
  assert.deepEqual(rows.map((row) => row.id), housePTRDisclosures(report, filing).map((row) => row.id));
  assert.ok(rows.every((row) => row.representative === "Kevin Hern" && row.provider === "house-ptr"));
  assert.equal(rows.find((row) => row.assetType === "GS").ticker, "");
});

test("explanations name options and skip an empty ticker", () => {
  const base = {
    reportDate: "2026-09-14", transactionDate: "2026-08-14", amountRange: "$250,001 - $500,000",
    chamber: "house", transactionType: "purchase"
  };
  assert.match(
    whyDisclosureMatters({ ...base, ticker: "MSFT", assetType: "OP", assetName: "Microsoft Corporation - Common Stock (MSFT)" }),
    /a purchase of options on Microsoft Corporation - Common Stock \(MSFT\) in/
  );
  const bond = whyDisclosureMatters({ ...base, ticker: "", assetType: "GS", assetName: "US Treasury Note 1/31/2029" });
  assert.match(bond, /a purchase of US Treasury Note 1\/31\/2029 in/);
  assert.doesNotMatch(bond, /\(\)/);
});


import { readHouseAnnual, parseAnnualItems, annualIndex } from '../src/house-annual.js';
test('annual Schedule A keeps year-end values, owners and wrapped asset names without importing Schedule B',async()=>{
 const report=await readHouseAnnual(await readFile(new URL('./fixtures/10075701-annual.pdf',import.meta.url)));
 assert.deepEqual(report.warnings,[]);assert.equal(report.year,2025);assert.equal(report.filedDate,'2026-05-15');assert.equal(report.assets.length,68);
 const apple=report.assets.find(a=>a.ticker==='AAPL'&&a.assetType==='ST');assert.equal(apple.owner,'spouse');assert.equal(apple.amountRange,'$5,000,001 - $25,000,000');
 const wrapped=report.assets.find(a=>a.name.startsWith('45 Belden'));assert.equal(wrapped.owner,'spouse');assert.equal(wrapped.amountRange,'$5,000,001 - $25,000,000');
 assert.match(report.assets.find(a=>a.ticker==='VST').description,/expiration date of 1\/16\/26/);
 assert.ok(report.assets.every(a=>!('transactionDate' in a)));
});
test('annual indexes resolve member originals and reject extensions and unknown candidates',()=>{
 const header='Prefix\tLast\tFirst\tSuffix\tFilingType\tStateDst\tYear\tFilingDate\tDocID';
 const rows=[header,'Hon.\tPelosi\tNancy\t\tO\tCA11\t2025\t5/15/2026\t10075701','Hon.\tPelosi\tNancy\t\tX\tCA11\t2025\t4/15/2026\t30001','\tUnknown\tCandidate\t\tO\tCA11\t2025\t5/15/2026\t10001'];
 const result=annualIndex(rows.join('\n'),2025);assert.equal(result.length,1);assert.equal(result[0].memberID,'us:P000197');assert.ok(result[0].sourceURL.includes('/2025/10075701.pdf'));
 assert.ok(parseAnnualItems([]).warnings.length>0);
});

test('annual parsing stops at Schedule B even when no closing footnote separates it',async()=>{
 const report=await readHouseAnnual(await readFile(new URL('./fixtures/10075834-annual.pdf',import.meta.url)));
 assert.deepEqual(report.warnings,[]);assert.equal(report.assets.length,335);assert.equal(report.name,'Hon. Kevin Hern');
 assert.ok(report.assets.every(asset=>asset.name && asset.owner && asset.amountRange));
 // A page's closing notes must not run into the last asset and hide its type code.
 assert.ok(report.assets.every(asset=>asset.assetType && !/Investment Vehicle details|asset type abbreviations/.test(asset.name)));
});
