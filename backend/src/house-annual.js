import { readHousePDFItems, groupLines, parseHouseAsset } from "./house-ptr.js";
import { fetchHouseReport, houseIndexFromArchive } from "./providers.js";
import { dateOnly, bulkInsertStatements } from "./normalization.js";
import { createResolver } from "./identity.js";
import roster from "./roster.js";

export const ANNUAL_PARSER_VERSION = 2;
const OWNERS = { SP: "spouse", JT: "joint", DC: "dependent" };

export async function readHouseAnnual(bytes) {
  const { pages, items } = await readHousePDFItems(bytes);
  return { pages, ...parseAnnualItems(items) };
}

export function parseAnnualItems(items) {
  const result = { filingID: null, year: null, filedDate: null, filingType: null, name: null, assets: [], warnings: [] };
  let columns, current, closed = false;
  const finish = () => {
    if (!current) return;
    const parsed = parseHouseAsset(current.asset.join(" "));
    const ownerCode = current.owner.trim();
    const owner = ownerCode ? OWNERS[ownerCode] : "member";
    const value = current.value.join(" ").replace(/\s*-\s*/g," - ").trim();
    if (!parsed.name || !owner || !value) result.warnings.push(`Incomplete annual asset ${result.assets.length+1}`);
    result.assets.push({ ...parsed, owner, amountRange: value, description: current.description.join(" ") || null });
    current = null;
  };
  for (const line of groupLines(items)) {
    const headerID = line.items.find(i => /^Filing ID #\d+$/.test(i.text));
    if (headerID) result.filingID ??= headerID.text.slice(11);
    const cells = line.items.filter(i => !/^Filing ID #/.test(i.text));
    if (!cells.length) continue;
    const first = cells[0].text, rest = cells.slice(1).map(i=>i.text).join(" ");
    if (first === "Name:") result.name ??= rest;
    if (first === "Filing Year:") result.year ??= Number(rest);
    if (first === "Filing Date:") result.filedDate ??= dateOnly(rest);
    if (first === "Filing Type:") result.filingType ??= rest;
    if (closed) continue;
    if (first.startsWith("* For the complete list of asset type")) { finish(); closed=true; continue; }
    const valueHeader = cells.find(i=>i.text === "Value of Asset");
    if (columns && !valueHeader && cells.some(i=>i.text==="Asset") && cells.some(i=>i.text==="Owner") && cells.some(i=>i.text==="Date")) { finish(); closed=true; continue; }
    if (valueHeader && cells.some(i=>i.text === "Asset") && cells.some(i=>i.text === "Owner")) {
      columns = [ ["asset",cells.find(i=>i.text==="Asset").x], ["owner",cells.find(i=>i.text==="Owner").x], ["value",valueHeader.x], ["income",cells.find(i=>i.text==="Income Type(s)")?.x] ].filter(([,x])=>Number.isFinite(x)).sort((a,b)=>a[1]-b[1]);
      continue;
    }
    if (!columns) continue;
    const row = {};
    for (const item of cells) {
      let key=columns[0][0]; for(const [name,x] of columns) if(item.x+4>=x)key=name;
      row[key]=(row[key]?row[key]+" ":"")+item.text;
    }
    if (row.value && row.asset && parseHouseAsset(row.asset).name && !current?.value.at(-1)?.endsWith("-") && !/^[DLC]:/.test(row.asset) && !/^\$|^Over \$/.test(row.asset)) {
      finish();current={asset:[],owner:row.owner??"",value:[],description:[],inDescription:false};
    }
    if (!current) { if(row.asset || row.value) result.warnings.push("Text before first annual asset"); continue; }
    if(row.owner && !current.owner)current.owner=row.owner;
    if(row.value)current.value.push(row.value);
    if(row.asset) {
      if(/^D:/.test(row.asset)){current.description.push(row.asset.slice(2).trim());current.inDescription=true;}
      else if(/^[LC]:/.test(row.asset))current.inDescription=false;
      else if(current.inDescription)current.description.push(row.asset);
      else current.asset.push(row.asset);
    }
  }
  if (!closed || !columns) result.warnings.push("Annual asset table did not reach its closing note");
  if (!result.filingType?.includes("Annual Report") || !result.year || !result.filedDate || !result.filingID) result.warnings.push("Not a validated annual report");
  return result;
}

export function annualIndex(text, year) {
  const resolve=createResolver(roster);
  return String(text).split(/\r?\n/).slice(1).map(line=>{
    const [,last,first,suffix,type,state,reportYear,filedDate,id]=line.split("\t");
    if(!["O","A"].includes(type) || !id || Number(reportYear)!==year)return null;
    const member=resolve({name:[first,last,suffix].filter(Boolean).join(" "),chamber:"house",state:state?.slice(0,2),district:Number(state?.slice(2))});
    const date=dateOnly(filedDate);if(!member || !date)return null;
    return {id,memberID:member.id,year,filedDate:date,sourceURL:`https://disclosures-clerk.house.gov/public_disc/financial-pdfs/${year}/${id}.pdf`};
  }).filter(Boolean);
}

export async function syncHouseAnnual(env, { refreshIndex = true } = {}) {
  if(refreshIndex) {
    const year=new Date().getUTCFullYear()-1;
    const response=await fetch(`https://disclosures-clerk.house.gov/public_disc/financial-pdfs/${year}FD.zip`,{headers:{"User-Agent":env.PUBLISHER_USER_AGENT},signal:AbortSignal.timeout(20_000)});
    if(!response.ok)throw new Error(`House annual index returned ${response.status}`);
    const bytes=new Uint8Array(await response.arrayBuffer());if(bytes.length>10*1024*1024)throw new Error("House annual archive exceeded size limit");
    const records=annualIndex(houseIndexFromArchive(bytes,year),year);
    const imports=bulkInsertStatements(env.DB,"house_annual_reports",["doc_id","member_id","reporting_year","filed_date","source_url"],records.map(r=>[r.id,r.memberID,r.year,r.filedDate,r.sourceURL]),"ON CONFLICT(doc_id) DO NOTHING");
    if(imports.length)await env.DB.batch(imports);
  }
  const pending=(await env.DB.prepare(`SELECT a.* FROM house_annual_reports a WHERE (a.status IN ('pending','failed') AND a.attempts<3) OR (a.parser_version<? AND a.status IN ('extracted','needs-review','failed'))
    ORDER BY (SELECT COUNT(*) FROM disclosures d WHERE d.politician_id=a.member_id) DESC,a.reporting_year DESC,a.filed_date DESC LIMIT 3`).bind(ANNUAL_PARSER_VERSION).all()).results;
  let extracted=0;
  for(const row of pending) {
    const now=new Date().toISOString();
    try {
      const parsed=await readHouseAnnual(await fetchHouseReport(env,row.source_url));
      if(parsed.filingID!==row.doc_id || parsed.year!==row.reporting_year)parsed.warnings.push("Annual index/report identity mismatch");
      const status=parsed.warnings.length?'needs-review':'extracted';
      await env.DB.prepare("UPDATE house_annual_reports SET status=?,assets=?,parser_version=?,attempts=CASE WHEN parser_version<? THEN 1 ELSE attempts+1 END,error=?,retrieved_at=? WHERE doc_id=?").bind(status,JSON.stringify(parsed.assets),ANNUAL_PARSER_VERSION,ANNUAL_PARSER_VERSION,parsed.warnings.length?parsed.warnings.slice(0,20).join('; ').slice(0,1000):null,now,row.doc_id).run();
      if(status==='extracted')extracted++;
    }catch(error){await env.DB.prepare("UPDATE house_annual_reports SET status='failed',parser_version=?,attempts=CASE WHEN parser_version<? THEN 1 ELSE attempts+1 END,error=?,retrieved_at=? WHERE doc_id=?").bind(ANNUAL_PARSER_VERSION,ANNUAL_PARSER_VERSION,String(error.message).slice(0,1000),now,row.doc_id).run();}
  }
  const failed=await env.DB.prepare("SELECT COUNT(*) AS count FROM house_annual_reports WHERE status='failed' AND attempts>=3").first();
  return {recordsSeen:pending.length,recordsWritten:extracted,message:failed.count?`${failed.count} annual reports failed after three attempts`:null};
}

export function annualAnchor(reports, memberID, frozenAt = null) {
  const report=reports.filter(r=>r.member_id===memberID && r.status==='extracted' && r.parser_version===ANNUAL_PARSER_VERSION && (!frozenAt || r.filed_date<=frozenAt && `${r.reporting_year}-12-31`<=frozenAt))
    .sort((a,b)=>b.reporting_year-a.reporting_year || b.filed_date.localeCompare(a.filed_date) || b.doc_id.localeCompare(a.doc_id))[0];
  return report ? {asOf:`${report.reporting_year}-12-31`,sourceURL:report.source_url,filedDate:report.filed_date,assets:JSON.parse(report.assets)} : null;
}
