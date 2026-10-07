import { bulkInsertStatements } from "./normalization.js";
import { plainText } from "./statements.js";

export const INTEREST_PARSER_VERSION = 1;

export function ukMember(value) {
  const membership = value.latestHouseMembership;
  if (!value.id || !membership) return null;
  return { id: `uk:${value.id}`, sourceID: String(value.id), country: "uk", legislature: "Parliament", name: value.nameDisplayAs,
    party: value.latestParty?.name ?? "Unknown", partyColor: value.latestParty?.backgroundColour ?? null,
    partyAbbreviation: value.latestParty?.abbreviation ?? null, chamber: membership.house === 1 ? "commons" : "lords",
    state: membership.membershipFrom ?? "", district: null, regionLabel: membership.house === 1 ? "Constituency" : "Peerage",
    imageURL: value.thumbnailUrl ?? null, photoSource: "UK Parliament", wikidataID: null,
    serviceStart: Number(membership.membershipStartDate?.slice(0,4) ?? 0), serviceEnd: membership.membershipEndDate?.slice(0,10) ?? null };
}

export function commonsInterest(record) {
  if (record.category?.number !== "7" || !/shareholdings/i.test(record.category?.name)) return null;
  const fields = Object.fromEntries((record.fields ?? []).map((f) => [f.name, f.value]));
  const organisation = fields.OrganisationName || record.summary;
  if (!organisation || !record.member?.id) return null;
  const ended = fields.EndDate ?? null;
  return { id: `uk:commons:${record.id}`, memberID: `uk:${record.member.id}`, country: "uk", category: record.category.name, organisation: plainText(organisation),
    thresholdText: fields.ShareholdingThreshold ?? null, action: ended ? "removed" : "declared", owner: fields.HeldOnBehalfOf ? "family" : "self",
    registeredAt: record.registrationDate ?? null, effectiveAt: fields.RegistrableDate ?? null, publishedAt: record.publishedDate ?? null, endedAt: ended,
    sourceURL: `https://interests.parliament.uk/Member/Index/${record.member.id}`, raw: record, confidence: 1 };
}

export function lordsInterests(memberRecord) {
  const member = memberRecord.member;
  return (memberRecord.interestCategories ?? []).filter((c) => /^Category 2:/i.test(c.name) && /shareholdings/i.test(c.name)).flatMap((category) => (category.interests ?? []).map((interest) => {
    const text = plainText(interest.interest);
    const ceased = text.match(/interest ceased\s+(\d{1,2}\s+[A-Za-z]+\s+\d{4})/i)?.[1];
    const endedAt = ceased && Number.isFinite(Date.parse(ceased)) ? new Date(ceased + " 12:00:00 GMT").toISOString().slice(0,10) : interest.deletedWhen?.slice(0,10) ?? null;
    return { id: `uk:lords:${interest.id}`, memberID: `uk:${member.id}`, country: "uk", category: category.name, organisation: text,
      thresholdText: null, action: endedAt ? "removed" : "declared", owner: "self", registeredAt: interest.createdWhen?.slice(0,10) ?? null,
      effectiveAt: null, publishedAt: null, endedAt, sourceURL: `https://members.parliament.uk/member/${member.id}/registeredinterests`, raw: interest, confidence: 1 };
  }));
}

export function matchSecurity(name, securities) {
  const normalize = (value) => plainText(value).replace(/\([^)]*\)/g, "").toLowerCase().normalize("NFKD").replace(/\b(inc|incorporated|corp|corporation|plc|limited|ltd|common stock|shares)\b\.?/g, "").replace(/[^a-z0-9]/g, "");
  const key = normalize(name);
  const exact = securities.filter((s) => normalize(s.name) === key);
  if (exact.length === 1) return { ticker: exact[0].ticker, exchange: exact[0].exchange, figi: exact[0].figi, confidence: 1, reviewStatus: "matched" };
  return { ticker: null, exchange: null, figi: null, confidence: 0, reviewStatus: exact.length > 1 ? "needs-review" : "unmatched" };
}

async function officialJSON(url, env) {
  const response = await fetch(url, { headers: { "User-Agent": env.PUBLISHER_USER_AGENT, Accept: "application/json" }, signal: AbortSignal.timeout(20_000) });
  if (!response.ok) throw new Error(`UK Parliament returned ${response.status}`);
  return response.json();
}

async function pages(firstURL, env, mode = "skip") {
  const first = await officialJSON(firstURL, env);
  const take = first.take ?? 20;
  const count = first.totalResults ?? first.total ?? first.items?.length ?? 0;
  if (!Number.isFinite(count) || count > 20_000) throw new Error("Unexpected UK pagination count");
  const records = [...(first.items ?? [])];
  const urls = [];
  if (mode === "page") {
    // Lords SearchResult advertises totalResults and fixed 20-row pages.
    for (let page=1; page<Math.ceil(count/20); page++) { const url = new URL(firstURL); url.searchParams.set("page",String(page)); urls.push(url); }
  } else for (let skip=take; skip<count; skip+=take) { const url = new URL(firstURL); url.searchParams.set(mode === "commons" ? "Skip" : "skip",String(skip)); urls.push(url); }
  for (let offset=0; offset<urls.length; offset+=6) {
    const batch = await Promise.all(urls.slice(offset,offset+6).map((url) => officialJSON(url,env)));
    records.push(...batch.flatMap((p) => p.items ?? []));
  }
  if (records.length < count) throw new Error("UK source returned an incomplete page set");
  return records;
}

export async function syncUK(env) {
  const [roster, categories] = await Promise.all([
    pages("https://members-api.parliament.uk/api/Members/Search?IsCurrentMember=true&take=20",env),
    officialJSON("https://interests-api.parliament.uk/api/v1/Categories",env)
  ]);
  const category = categories.items.find((c) => c.number === "7" && /shareholdings/i.test(c.name));
  if (!category) throw new Error("Shareholdings category unavailable");
  const cursor = await env.DB.prepare("SELECT value FROM app_metadata WHERE key='uk-interests-sync'").first();
  const url = new URL("https://interests-api.parliament.uk/api/v1/Interests");
  url.searchParams.set("CategoryId",String(category.id)); url.searchParams.set("Take","20");
  if (cursor) url.searchParams.set("UpdatedFrom",cursor.value);
  const [commons, lords] = await Promise.all([pages(url,env,"commons"), pages("https://members-api.parliament.uk/api/LordsInterests/Register?includeDeleted=true&page=0",env,"page")]);
  const members = roster.map((r) => ukMember(r.value)).filter(Boolean);
  // Lords register may include former members with ceased interests.
  for (const item of lords) { const member=ukMember(item.value.member); if (member && !members.some((m) => m.id===member.id)) members.push(member); }
  for (const record of commons) {
    if (!members.some((m)=>m.id===`uk:${record.member.id}`)) {
      const payload=await officialJSON(`https://members-api.parliament.uk/api/Members/${record.member.id}`,env);
      const member=ukMember(payload.value); if(member) members.push(member);
    }
  }
  const interests = [...commons.map(commonsInterest).filter(Boolean), ...lords.flatMap((r) => lordsInterests(r.value))];
  await writeMembers(env.DB,members);
  await writeInterests(env.DB,interests);
  const now = new Date().toISOString();
  await env.DB.prepare("INSERT INTO app_metadata VALUES('uk-interests-sync',?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value,updated_at=excluded.updated_at").bind(now.slice(0,10),now).run();
  return { recordsSeen: interests.length, recordsWritten: interests.length, coverageEnd: now.slice(0,10) };
}

export async function writeMembers(db,members) {
  const now = new Date().toISOString();
  const statements=bulkInsertStatements(db,"politicians",["bioguide_id","name","normalized_name","party","chamber","state","image_url","service_start","updated_at","country","source_id","legislature","region_label","party_color","wikidata_id","photo_source","service_end"],
    members.map(m=>[m.id,m.name,`${m.id}:${m.name.toLowerCase()}`,m.party,m.chamber,m.state,m.imageURL,m.serviceStart,now,m.country,m.sourceID,m.legislature,m.regionLabel,m.partyColor,m.wikidataID,m.photoSource,m.serviceEnd]),
    "ON CONFLICT(bioguide_id) DO UPDATE SET name=excluded.name,party=excluded.party,chamber=excluded.chamber,state=excluded.state,image_url=excluded.image_url,party_color=excluded.party_color,service_end=excluded.service_end,updated_at=excluded.updated_at");
  if(statements.length) await db.batch(statements);

}

export async function writeInterests(db,interests) {
  const securities=(await db.prepare("SELECT ticker,name,exchange,figi FROM securities").all()).results;
  const rows=interests.map(r=>{
    const match=matchSecurity(r.organisation,securities);
    return [r.id,r.memberID,r.country,r.category,r.organisation,match.exchange,match.ticker,match.figi,r.thresholdText,r.action,r.owner,r.registeredAt,r.effectiveAt,r.publishedAt,r.endedAt,r.sourceURL,JSON.stringify(r.raw),INTEREST_PARSER_VERSION,r.confidence,match.reviewStatus,match.confidence];
  });
  const statements=bulkInsertStatements(db,"interest_records",["id","member_id","country","category","organisation","exchange","ticker","figi","threshold_text","action","owner","registered_at","effective_at","published_at","ended_at","source_url","raw_json","parser_version","confidence","review_status","match_confidence"],rows,
    "ON CONFLICT(id) DO UPDATE SET organisation=excluded.organisation,threshold_text=excluded.threshold_text,action=excluded.action,owner=excluded.owner,registered_at=excluded.registered_at,effective_at=excluded.effective_at,published_at=excluded.published_at,ended_at=excluded.ended_at,raw_json=excluded.raw_json,parser_version=excluded.parser_version,ticker=CASE WHEN interest_records.organisation=excluded.organisation AND interest_records.ticker IS NOT NULL THEN interest_records.ticker ELSE excluded.ticker END,exchange=CASE WHEN interest_records.organisation=excluded.organisation AND excluded.exchange IS NULL THEN interest_records.exchange ELSE excluded.exchange END,figi=CASE WHEN interest_records.organisation=excluded.organisation AND excluded.figi IS NULL THEN interest_records.figi ELSE excluded.figi END,candidate_matches=CASE WHEN interest_records.organisation=excluded.organisation THEN interest_records.candidate_matches ELSE '[]' END,confidence=excluded.confidence,review_status=CASE WHEN interest_records.organisation=excluded.organisation AND excluded.ticker IS NULL THEN interest_records.review_status ELSE excluded.review_status END,match_confidence=CASE WHEN interest_records.organisation=excluded.organisation AND excluded.ticker IS NULL THEN interest_records.match_confidence ELSE excluded.match_confidence END");
  if(statements.length) await db.batch(statements);

}

export async function interestRoute(request,env) {
  const url=new URL(request.url);
  if(request.method!=="GET")return null;
  if(url.pathname!=="/v1/members" && url.pathname!=="/v1/interests")return null;
  const country=url.searchParams.get("country")??"uk";
  if(!["us","uk","ca","au"].includes(country))return json({error:"invalid_country"},400);
  if(["ca","au"].includes(country) && env[`${country.toUpperCase()}_INTERESTS_PERMISSION`]!=="granted")return json({error:"permission_pending",country},403);
  if(url.pathname==="/v1/members") {
    const rows=(await env.DB.prepare("SELECT * FROM politicians WHERE country=? ORDER BY name").bind(country).all()).results;
    return json({data:rows.map((r)=>({id:r.bioguide_id,name:r.name,party:r.party,state:r.state??"",district:r.district,chamber:r.chamber,imageURL:r.image_url,serviceStart:r.service_start??0,country:r.country,sourceID:r.source_id??r.bioguide_id,legislature:r.legislature,regionLabel:r.region_label,partyHex:r.party_color,wikidataID:r.wikidata_id,photoSource:r.photo_source,serviceEnd:r.service_end}))});
  }
  const member=url.searchParams.get("member_id"), ticker=url.searchParams.get("ticker");
  const conditions=["country=?"],args=[country];
  if(member){conditions.push("member_id=?");args.push(member);}
  if(ticker){conditions.push("ticker=?");args.push(ticker);}
  const rows=(await env.DB.prepare(`SELECT * FROM interest_records WHERE ${conditions.join(" AND ")} ORDER BY COALESCE(published_at,registered_at) DESC`).bind(...args).all()).results;
  return json({data:rows.map((r)=>({id:r.id,memberID:r.member_id,country:r.country,category:r.category,organisation:r.organisation,ticker:r.ticker,exchange:r.exchange,figi:r.figi,thresholdText:r.threshold_text,action:r.action,owner:r.owner,registeredAt:r.registered_at,effectiveAt:r.effective_at,publishedAt:r.published_at,endedAt:r.ended_at,sourceURL:r.source_url,confidence:r.confidence,reviewStatus:r.review_status}))});
}
function json(body,status=200){return new Response(JSON.stringify(body),{status,headers:{"content-type":"application/json","cache-control":"no-store"}});}

// Exact issuer matching is automatic. All ambiguous search results remain for human review.
export async function matchUnresolvedInterests(env) {
  const last = await env.DB.prepare("SELECT value FROM app_metadata WHERE key='openfigi-last-search'").first();
  if (last && Date.now() - Date.parse(last.value) < 60_000) return { recordsSeen: 0, recordsWritten: 0 };
  const limit = env.OPENFIGI_API_KEY ? 12 : 5;
  const rows = (await env.DB.prepare("SELECT id,country,organisation FROM interest_records WHERE review_status='unmatched' LIMIT ?").bind(limit).all()).results;
  if (!rows.length) return { recordsSeen: 0, recordsWritten: 0 };
  const now = new Date().toISOString();
  await env.DB.prepare("INSERT INTO app_metadata VALUES('openfigi-last-search',?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value,updated_at=excluded.updated_at").bind(now,now).run();
  let matched=0;
  for(const row of rows){
    const exchCode={uk:'LN',ca:'CN',au:'AU'}[row.country];
    if(!exchCode)continue;
    const response=await fetch('https://api.openfigi.com/v3/search',{method:'POST',headers:{'Content-Type':'application/json',...(env.OPENFIGI_API_KEY?{'X-OPENFIGI-APIKEY':env.OPENFIGI_API_KEY}:{})},body:JSON.stringify({query:plainText(row.organisation).replace(/\([^)]*\)/g," ").trim(),exchCode,marketSecDes:'Equity'}),signal:AbortSignal.timeout(20_000)});
    if(!response.ok)throw new Error(`OpenFIGI returned ${response.status}`);
    const payload=await response.json();
    const exchange={LN:'LSE',CN:'TSX',AU:'ASX'}[exchCode];
    const candidates=(payload.data??[]).filter(r=>r.exchCode===exchCode && r.ticker && r.figi).map(r=>({name:r.name,ticker:`${exchange}:${r.ticker}`,exchange,figi:r.figi}));
    const match=matchSecurity(row.organisation,candidates);
    if(match.ticker){
      const security=candidates.find(c=>c.ticker===match.ticker);
      await env.DB.prepare("INSERT INTO securities(ticker,name,exchange,figi,source_url,updated_at) VALUES(?,?,?,?,?,?) ON CONFLICT(ticker) DO UPDATE SET figi=excluded.figi,name=excluded.name").bind(security.ticker,security.name,security.exchange,security.figi,'https://www.openfigi.com/',new Date().toISOString()).run();
      matched++;
    }
    await env.DB.prepare("UPDATE interest_records SET ticker=?,exchange=?,figi=?,match_confidence=?,candidate_matches=?,review_status=? WHERE id=?").bind(match.ticker,match.exchange,match.figi,match.confidence,JSON.stringify(candidates),match.ticker?'matched':candidates.length?'needs-review':'no-match',row.id).run();
  }
  return {recordsSeen:rows.length,recordsWritten:matched};
}
