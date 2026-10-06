// Reads House Periodic Transaction Reports straight from the Clerk's PDFs. Electronically filed
// reports carry a text layer laid out as a fixed table; scanned paper reports do not and are left
// for later. The table's column positions shift between reports, so they are read from each page's
// header row rather than hard-coded.
import { getDocumentProxy } from "unpdf";
import { dateOnly, stableUUID } from "./normalization.js";

export const HOUSE_PTR_PARSER_VERSION = 1;

// E-filed reports have eight-digit IDs beginning 20; paper scans have seven digits.
export function isElectronicHouseFiling(docID) {
  return /^20\d{6}$/.test(String(docID ?? ""));
}

const LINE_TOLERANCE = 1.5;
const COLUMN_SLACK = 4;
const HEADER_FOLLOW_ON = new Set(["Type", "Date", "Gains >", "$200?", "Gains", "> $200?"]);
const TABLE_END = /^\* For the complete list of asset type abbreviations/;
const SECTION_AFTER_TABLE = /^(?:I V D|I P O|C S|Digitally Signed:)$/;
const SUBFIELD = /^([A-Z](?: [A-Z]){0,2}) ?: ?(.*)$/;
const SUBFIELD_NAMES = { "F S": "filingStatus", "S O": "subholding", D: "description", L: "location", C: "comment" };
const DATE = /^\d{1,2}\/\d{1,2}\/\d{4}$/;
const TRANSACTION_TYPES = { P: "purchase", S: "sale", E: "exchange" };
const OWNERS = { SP: "spouse", JT: "joint", DC: "dependent" };
// Parenthesised words that describe a share class or wrapper rather than name a symbol.
const NOT_TICKERS = new Set(["ADR", "ETF", "REIT", "LLC", "INC"]);

export async function readHousePTR(bytes) {
  // pdf.js rejects Node Buffers and may detach what it is given, so it always gets its own copy.
  const pdf = await getDocumentProxy(new Uint8Array(bytes));
  try {
    const items = [];
    for (let page = 1; page <= pdf.numPages; page += 1) {
      const handle = await pdf.getPage(page);
      const height = handle.getViewport({ scale: 1 }).height;
      const content = await handle.getTextContent();
      for (const item of content.items) {
        if (typeof item.str !== "string") continue;
        items.push({ page, x: item.transform[4], y: height - item.transform[5], text: item.str });
      }
    }
    return { pages: pdf.numPages, ...parseHousePTRItems(items) };
  } finally {
    await pdf.cleanup?.();
  }
}

// Small caps in the subfield labels come through as runs of NULs; line breaks leak into some strings.
export function cleanText(value) {
  return String(value).replaceAll("\u0000", "").replace(/\s+/g, " ").trim();
}

export function parseHousePTRItems(rawItems) {
  const lines = groupLines(rawItems);
  const result = {
    filingID: null, name: null, status: null, stateDistrict: null, signed: null,
    transactions: [], warnings: []
  };
  let columns = null;
  let headerPage = 0;
  let headerY = 0;
  let inTable = false;
  let finished = false;
  let current = null;

  const finish = () => {
    if (!current) return;
    const transaction = finalizeTransaction(current);
    if (transaction.problem) result.warnings.push(`row ${result.transactions.length + 1}: ${transaction.problem}`);
    result.transactions.push(transaction);
    current = null;
  };

  for (const line of lines) {
    const filingIDItem = line.items.find((item) => /^Filing ID #\d+$/.test(item.text));
    if (filingIDItem) {
      result.filingID ??= filingIDItem.text.slice("Filing ID #".length);
      line.items = line.items.filter((item) => item !== filingIDItem);
      if (!line.items.length) continue;
    }
    const first = line.items[0].text;
    const rest = line.items.slice(1).map((item) => item.text).join(" ");

    if (!inTable) {
      if (first === "Name:") result.name ??= rest;
      else if (first === "Status:") result.status ??= rest;
      else if (first === "State/District:") result.stateDistrict ??= rest;
      else if (first === "Digitally Signed:") result.signed ??= rest;
      if (!finished && isHeaderLine(line)) {
        columns = headerColumns(line);
        headerPage = line.page;
        headerY = line.y;
        inTable = true;
      }
      continue;
    }

    if (isHeaderLine(line)) {
      columns = headerColumns(line);
      headerPage = line.page;
      headerY = line.y;
      continue;
    }
    if (line.page === headerPage && line.y - headerY < 30
      && line.items.every((item) => HEADER_FOLLOW_ON.has(item.text))) continue;
    if (TABLE_END.test(first) || SECTION_AFTER_TABLE.test(first)) {
      finish();
      inTable = false;
      finished = true;
      if (first === "Digitally Signed:") result.signed ??= rest;
      continue;
    }

    const cells = {};
    for (const item of line.items) {
      const column = columnFor(columns, item.x);
      cells[column] = cells[column] ? `${cells[column]} ${item.text}` : item.text;
    }
    // A wrapped type ("S" then "(partial)") does not start a row; only a type code or a date does.
    const startsRow = DATE.test(cells.date ?? "") || /^[PSE](?: |$)/.test(cells.type ?? "");
    if (startsRow) {
      finish();
      current = {
        rowID: cells.id ?? null, owner: cells.owner ?? "", assetLines: [], type: cells.type ?? "",
        date: cells.date ?? "", notification: cells.notification ?? "", amount: [], fields: {}, lastField: null
      };
    } else if (!current) {
      result.warnings.push(`text before the first row: ${line.items.map((item) => item.text).join(" ")}`);
      continue;
    } else {
      if (cells.type) current.type = `${current.type} ${cells.type}`.trim();
      if (cells.id) current.rowID ??= cells.id;
      if (cells.owner) current.owner = `${current.owner} ${cells.owner}`.trim();
    }
    if (cells.amount) current.amount.push(cells.amount);
    if (cells.asset) {
      const field = cells.asset.match(SUBFIELD);
      const name = field && SUBFIELD_NAMES[field[1]];
      if (name) {
        current.fields[name] = field[2];
        current.lastField = name;
      } else if (current.lastField) {
        current.fields[current.lastField] = `${current.fields[current.lastField]} ${cells.asset}`;
      } else {
        current.assetLines.push(cells.asset);
      }
    }
  }
  finish();
  if (inTable) result.warnings.push("table did not reach its closing note");
  if (!columns) result.warnings.push("no transaction table found");
  return result;
}

function groupLines(rawItems) {
  const items = rawItems
    .map((item) => ({ page: item.page, x: item.x, y: item.y, text: cleanText(item.text ?? item.str ?? "") }))
    .filter((item) => item.text)
    .sort((a, b) => a.page - b.page || a.y - b.y || a.x - b.x);
  const lines = [];
  for (const item of items) {
    const line = lines.at(-1);
    if (line && line.page === item.page && Math.abs(item.y - line.y) <= LINE_TOLERANCE) {
      line.items.push(item);
    } else {
      lines.push({ page: item.page, y: item.y, items: [item] });
    }
  }
  for (const line of lines) line.items.sort((a, b) => a.x - b.x);
  return lines;
}

function isHeaderLine(line) {
  const labels = new Set(line.items.map((item) => item.text));
  return labels.has("Owner") && labels.has("Asset") && labels.has("Amount");
}

function headerColumns(line) {
  const at = (label) => line.items.find((item) => item.text === label)?.x;
  const dates = line.items.filter((item) => item.text === "Date").map((item) => item.x);
  const transaction = at("Transaction");
  const notification = at("Notification");
  const columns = [
    ["id", at("ID") ?? 0],
    ["owner", at("Owner")],
    ["asset", at("Asset")],
    ["type", transaction],
    ["date", dates.find((x) => x > (transaction ?? 0) && x < (notification ?? Infinity))],
    ["notification", notification],
    ["amount", at("Amount")],
    ["gains", at("Cap.")]
  ].filter(([, x]) => Number.isFinite(x));
  return columns.sort((a, b) => a[1] - b[1]);
}

function columnFor(columns, x) {
  let match = columns[0][0];
  for (const [name, start] of columns) {
    if (x + COLUMN_SLACK >= start) match = name;
  }
  return match;
}

// A report's asset cell ends with a system-added type code such as "[ST]"; filers sometimes type
// another code before it ("[MF} [OT]"). A ticker, when the filer gave one, is the parenthesised
// symbol just before the codes.
export function parseHouseAsset(text) {
  const asset = cleanText(text);
  const codes = asset.match(/(?:\s*\[[A-Z]{2}[\]}])+\s*$/);
  const assetType = codes ? codes[0].match(/\[([A-Z]{2})[\]}]\s*$/)[1] : null;
  const name = codes ? asset.slice(0, codes.index).trim() : asset;
  // Share classes ("BRK/B") are written with a dot; preferred series keep the filer's "$" ("T$A").
  const tickerMatch = name.match(/\(([A-Z][A-Z0-9]{0,5}(?:[./-][A-Z0-9]{1,3}|\$[A-Z])?)\)$/)
    ?? name.match(/\(Ticker: ?([A-Z][A-Z0-9]{0,5})\)/i);
  const symbol = tickerMatch?.[1].toUpperCase().replace(/[/-]/, ".");
  const ticker = symbol && !NOT_TICKERS.has(symbol) ? symbol : null;
  return { name, ticker, assetType };
}

function finalizeTransaction(row) {
  const asset = parseHouseAsset(row.assetLines.join(" "));
  const typeCode = row.type.replace(/\s*\(partial\)\s*$/i, "").trim();
  const transactionType = TRANSACTION_TYPES[typeCode] ?? null;
  const ownerCode = row.owner.trim();
  const owner = ownerCode ? OWNERS[ownerCode] ?? null : "member";
  const amountRange = row.amount.join(" ").replace(/\s*-\s*/, " - ").trim();
  const transactionDate = dateOnly(row.date);
  const notificationDate = dateOnly(row.notification);
  const problems = [
    !asset.name && "no asset",
    !transactionType && `unknown type "${row.type}"`,
    !owner && `unknown owner "${row.owner}"`,
    !transactionDate && `bad date "${row.date}"`,
    !amountRange && "no amount"
  ].filter(Boolean);
  return {
    rowID: row.rowID && /^\d+$/.test(row.rowID) ? row.rowID : null,
    owner,
    assetName: asset.name,
    ticker: asset.ticker,
    assetType: asset.assetType,
    transactionType,
    partial: /\(partial\)/i.test(row.type),
    transactionDate,
    notificationDate,
    amountRange,
    filingStatus: row.fields.filingStatus ?? null,
    subholding: row.fields.subholding ?? null,
    description: row.fields.description ?? null,
    location: row.fields.location ?? null,
    comment: row.fields.comment ?? null,
    problem: problems.length ? problems.join("; ") : null
  };
}

// Turns one parsed report into disclosure rows. The House index supplies the filer's identity;
// the report itself is only checked against it.
export function housePTRDisclosures(parsed, filing) {
  const raw = typeof filing.rawJSON === "string" ? JSON.parse(filing.rawJSON) : (filing.raw ?? {});
  const representative = [raw.first, raw.last, raw.suffix].map((part) => String(part ?? "").trim())
    .filter(Boolean).join(" ") || filing.representative;
  // Rows keep their position in the report so two identical lines stay two records.
  return parsed.transactions
    .map((transaction, index) => ({ transaction, index }))
    .filter(({ transaction }) => !transaction.problem)
    .map(({ transaction, index }) => ({
      id: stableUUID(`house-ptr|${filing.docID}|${transaction.rowID ?? index}`),
      provider: "house-ptr",
      politicianID: null,
      representative,
      reportDate: filing.disclosureDate,
      transactionDate: transaction.transactionDate,
      ticker: transaction.ticker ?? "",
      assetName: transaction.assetName.slice(0, 500),
      assetType: transaction.assetType,
      description: transaction.description?.slice(0, 1000) ?? null,
      transactionType: transaction.transactionType,
      owner: transaction.owner,
      amountRange: transaction.amountRange.slice(0, 100),
      chamber: "house",
      party: null,
      sourceURL: filing.filingURL,
      confidence: 0.98,
      rawJSON: JSON.stringify({ parser: HOUSE_PTR_PARSER_VERSION, docID: filing.docID, ...transaction })
    }));
}
