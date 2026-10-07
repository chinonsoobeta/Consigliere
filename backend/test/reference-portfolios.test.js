import test from 'node:test';
import assert from 'node:assert/strict';
import { amountBand, assetGroup, buildMemberPortfolio, aggregatePortfolios } from '../src/reference-portfolios.js';
import { ruleTags, validTags, relevance, parseWhiteHouseFeed } from '../src/statements.js';
const row = (id, type, amount, raw = {}, extra = {}) => ({ id, politician_id: 'A', ticker: 'ABC', asset_name: 'Example', owner: 'member', asset_type: 'ST', amount_range: amount, transaction_type: type, transaction_date: `2026-01-${id.padStart(2,'0')}`, report_date: `2026-02-${id.padStart(2,'0')}`, source_url: 'https://example.com/source', raw_json: JSON.stringify(raw), ...extra });

test('estimates preserve band uncertainty and unbounded highs', () => {
 assert.deepEqual(amountBand('$1,001 - $15,000'), { low:1000, high:15000, midpoint:8000 });
 assert.deepEqual(amountBand('Over $50,000,000'), { low:50000000, high:null, midpoint:50000000 });
 assert.equal(amountBand('Unknown'),null);
 const p=buildMemberPortfolio([row('1','purchase','$1,001 - $15,000'),row('2','sale','$1,001 - $5,000',{partial:true})],{memberID:'A'});
 assert.equal(p.positions[0].estimate,5000); assert.equal(p.positions[0].low,0); assert.equal(p.positions[0].high,14000); assert.equal(p.changes[1].action,'trimmed');
});
test('full sales close positions; exchanges do not affect estimates',()=>{
 const p=buildMemberPortfolio([row('1','purchase','$1,001 - $15,000'),row('2','exchange','$1,001 - $15,000'),row('3','sale','$1,001 - $5,000',{partial:false})],{memberID:'A'});
 assert.equal(p.positions[0].estimate,0); assert.equal(p.positions[0].high,0); assert.equal(p.changes[1].action,'exchange'); assert.equal(p.changes[2].action,'exited');
});
test('a sale before an observed purchase is kept as missing prior holdings',()=>{
 const p=buildMemberPortfolio([row('1','sale','$1,001 - $15,000')],{memberID:'A'});
 assert.equal(p.positions[0].estimate,0); assert.equal(p.positions[0].status,'held-before-records'); assert.match(p.changes[0].note,/Held before/);
});
test('options, bonds and owners stay separate; group holders count each member once',()=>{
 const rows=[row('1','purchase','$1,001 - $15,000'),row('2','purchase','$1,001 - $15,000',{}, {owner:'spouse'}),row('3','purchase','$1,001 - $15,000',{}, {asset_type:'OP'})];
 const p=buildMemberPortfolio(rows,{memberID:'A'}); assert.equal(p.positions.length,3);
 const group=aggregatePortfolios([p]); assert.equal(group.positions.find(p=>p.group==='stocks').membersHolding,1); assert.equal(group.positions.find(p=>p.group==='stocks').estimate,16000);
 assert.equal(buildMemberPortfolio(rows,{memberID:'A',ownOnly:true}).positions.length,2);
});
test('departed members stop at the public filing cutoff',()=>{
 const p=buildMemberPortfolio([row('1','purchase','$1,001 - $15,000'),row('2','purchase','$1,001 - $15,000')],{memberID:'A',frozenAt:'2026-02-01'}); assert.equal(p.positions[0].estimate,8000);
});
test('tags require literal evidence and dictionary company matches',()=>{
 const body='Microsoft Corporation faces a new tariff on steel imports from Canada.';
 const tags=ruleTags(body,[{name:'Microsoft Corporation',ticker:'MSFT'}]);
 assert.ok(tags.some(t=>t.value==='MSFT'&&t.quote==='Microsoft Corporation')); assert.ok(tags.some(t=>t.kind==='policy'&&t.quote==='tariff'));
 assert.equal(validTags([{kind:'company',value:'FAKE',quote:'Apple'}],body).length,0); assert.equal(relevance(tags).tier,'Names a company'); assert.ok(tags.every(t=>body.includes(t.quote)));
 assert.equal(ruleTags('Senator Lindsey O. Graham attended.',[{name:'Graham Corp',ticker:'GHM'}]).some(t=>t.kind==='company'),false);
 assert.equal(ruleTags('Graham Corp announced a contract.',[{name:'Graham Corp',ticker:'GHM'}]).find(t=>t.kind==='company')?.quote,'Graham Corp');
 assert.equal(ruleTags('Microsoft announced a tariff.',[{name:'Microsoft Corporation',ticker:'MSFT'}]).some(t=>t.kind==='company'),false);
});
test('RSS reads exact text and rejects unofficial source URLs',()=>{
 const xml='<item><title>Title</title><link>https://www.whitehouse.gov/presidential-actions/test/</link><pubDate>Tue, 06 Oct 2026 01:13:53 GMT</pubDate><content:encoded><![CDATA[<p>Steel &amp; tax</p>]]></content:encoded></item>';
 assert.equal(parseWhiteHouseFeed(xml)[0].body,'Steel & tax'); assert.equal(parseWhiteHouseFeed(xml.replace('www.whitehouse.gov','evil.example')).length,0);
 const framed=xml.replace('<p>Steel &amp; tax</p>', '<h1 class="wp-block-whitehouse-topper__headline">Briefings &amp; Statements</h1><nav class="wp-block-whitehouse-topper-navigation"><form>Search</form><select><option>Research</option></select></nav><p>Steel &amp; tax</p><p>The post <a>Title</a> appeared first on <a>The White House</a>.</p>');
 assert.equal(parseWhiteHouseFeed(framed)[0].body,'Steel & tax');
});

import { DatabaseSync } from 'node:sqlite';
import { readFileSync, readdirSync } from 'node:fs';
import { rebuildPortfolios, readPortfolio } from '../src/reference-portfolios.js';
import { commonsInterest, lordsInterests, ukMember, matchSecurity, writeMembers, writeInterests, interestRoute } from '../src/interests.js';
import { researchRoute } from '../src/research.js';
import worker from '../src/worker.js';

function database(beforeResearch) {
 const sqlite=new DatabaseSync(':memory:');
 sqlite.exec('PRAGMA foreign_keys=ON');
 const directory=new URL('../migrations/',import.meta.url);
 for(const file of readdirSync(directory).filter(f=>f.endsWith('.sql')).sort()) { if(file.startsWith('0008')) beforeResearch?.(sqlite); sqlite.exec('BEGIN;'+readFileSync(new URL(file,directory),'utf8')+'COMMIT;'); }
 sqlite.exec('PRAGMA foreign_keys=ON');
 const DB={prepare(sql){let args=[];return {bind(...values){args=values;return this;},async all(){return {results:sqlite.prepare(sql).all(...args)}},async first(){return sqlite.prepare(sql).get(...args)??null;},async run(){const r=sqlite.prepare(sql).run(...args);return {meta:{changes:Number(r.changes),last_row_id:Number(r.lastInsertRowid)}}}}},async batch(statements){sqlite.exec('BEGIN');try {const r=[];for(const s of statements)r.push(await s.run());sqlite.exec('COMMIT');return r;}catch(error){sqlite.exec('ROLLBACK');throw error;}}};
 return {DB,sqlite};
}

test('reranking and identity matching update full pages within D1 query limits',async()=>{
 const {DB,sqlite}=database();
 const insert=sqlite.prepare("INSERT INTO disclosures(id,provider,representative,report_date,transaction_date,ticker,asset_name,transaction_type,owner,amount_range,chamber,raw_json,observed_at,updated_at) VALUES(?,'test','Kevin Hern','2026-10-01','2026-09-01','AAPL','Apple','purchase','member','$1,001 - $15,000','house','{}','2026-10-01','2026-10-01')");
 for(let i=0;i<1001;i++)insert.run(String(i).padStart(5,'0'));
 let queries=0;
 const counted={...DB,prepare(sql){queries++;return DB.prepare(sql);}};
 const env={DB:counted,SYNC_TOKEN:'test'};
 const call=async(path,body)=>worker.fetch(new Request('https://example.com/internal/'+path,{method:'POST',headers:{authorization:'Bearer test','content-type':'application/json'},body:JSON.stringify(body)}),env).then(r=>r.json());
 const first=await call('rematch',{limit:1000});
 assert.equal(first.matched,1000);assert.equal(first.nextAfterID,'00999');assert.ok(queries<50);
 queries=0;assert.equal((await call('rematch',{limit:1000,afterID:first.nextAfterID})).matched,1);assert.ok(queries<50);
 assert.equal(sqlite.prepare("SELECT COUNT(*) AS count FROM disclosures WHERE politician_id='us:H001082'").get().count,1001);
 queries=0;const ranks=await call('rerank',{all:true,limit:1000});
 assert.equal(ranks.updated,1000);assert.equal(ranks.nextAfterID,'00999');assert.ok(queries<50);
 queries=0;assert.equal((await call('rerank',{all:true,limit:1000,afterID:ranks.nextAfterID})).updated,1);assert.ok(queries<50);
 assert.equal(sqlite.prepare('SELECT COUNT(*) AS count FROM disclosures WHERE ranking_score>0 AND why_it_matters IS NOT NULL AND json_valid(ranking_reasons)').get().count,1001);
 sqlite.close();
});

test('D1 schema and portfolio rebuild persist estimates and source-linked changes',async()=>{
 const {DB,sqlite}=database();
 sqlite.prepare("INSERT INTO politicians(bioguide_id,name,normalized_name,updated_at) VALUES('us:A','Member','member','2026-10-06')").run();
 for(const record of [row('1','purchase','$1,001 - $15,000'),row('2','sale','$1,001 - $5,000',{partial:true})]) {
  const fields=Object.keys(record).filter(k=>k!=='politician_id');
  sqlite.prepare(`INSERT INTO disclosures(${fields.join(',')},politician_id,provider,representative,observed_at,updated_at) VALUES(${fields.map(()=>'?').join(',')},'us:A','test','Member','2026-10-06','2026-10-06')`).run(...fields.map(k=>record[k]));
 }
 await rebuildPortfolios(DB);
 const p=await readPortfolio(DB,'member/us:A');assert.equal(p.positions[0].estimate,5000);
 const response=await researchRoute(new Request('https://example.com/v1/portfolios/member/us:A/changes'),{DB},r=>r);
 assert.equal(response.status,200);assert.equal((await response.json()).data.length,2);
 const all=await researchRoute(new Request('https://example.com/v1/portfolios/congress'),{DB},r=>r);
 assert.equal((await all.json()).data.positions[0].membersHolding,1);
 await rebuildPortfolios(DB);assert.equal((await readPortfolio(DB,'congress')).positions[0].estimate,5000);
 sqlite.close();
});

test('UK shareholding fixtures preserve thresholds, identities and ended dates',async()=>{
 const commons=JSON.parse(readFileSync(new URL('./fixtures/uk-commons-shareholding.json',import.meta.url)));
 const interest=commonsInterest(commons);assert.equal(interest.memberID,'uk:5158');assert.match(interest.thresholdText,/£70,000/);
 assert.equal(commonsInterest({...commons,category:{number:'6',name:'Land and property'}}),null);
 const lord=JSON.parse(readFileSync(new URL('./fixtures/uk-lords-shareholdings.json',import.meta.url)));
 const interests=lordsInterests(lord);assert.ok(interests.length>0);
 const ended=lordsInterests({...lord,interestCategories:[{name:'Category 2: Shareholdings',interests:[{id:999,interest:'Example PLC (interest ceased 25 June 2026)',createdWhen:'2026-01-01'}]}]})[0];assert.equal(ended.endedAt,'2026-06-25');assert.equal(ended.action,'removed');
 const {DB,sqlite}=database();await writeMembers(DB,[ukMember(lord.member)]);await writeInterests(DB,interests);
 const response=await interestRoute(new Request(`https://example.com/v1/interests?country=uk&member_id=uk:${lord.member.id}`),{DB});assert.equal((await response.json()).data.length,interests.length);
 assert.equal((await interestRoute(new Request('https://example.com/v1/interests?country=au'),{DB})).status,403);
 assert.equal(matchSecurity('Private company',[{name:'Example PLC',ticker:'EX',exchange:'LSE'}]).ticker,null);
 sqlite.close();
});

test('House retry health stays available until the third failed attempt and remains degraded afterward',async()=>{
 const {DB,sqlite}=database();
 sqlite.prepare("INSERT INTO source_filings VALUES('test','house','Member','house','2026-10-06','https://disclosures-clerk.house.gov/public_disc/ptr-pdfs/2026/20039999.pdf','20039999','official-metadata','{}','2026-10-06','2026-10-06')").run();
 const original=globalThis.fetch;globalThis.fetch=async()=>new Response('',{status:403});
 const env={DB,HOUSE_PTR_MODE:'live',PUBLISHER_USER_AGENT:'Consigliere test'};
 try {
  for(let attempt=1;attempt<=4;attempt++){
   let operation; await worker.scheduled({cron:'45 * * * *'},env,{waitUntil:promise=>{operation=promise;}}); await operation;
   const health=sqlite.prepare("SELECT status FROM source_health WHERE provider='house-ptr'").get();
   assert.equal(health.status,attempt<3?'available':'degraded');
   assert.equal(sqlite.prepare("SELECT attempts FROM house_ptr_extractions").get().attempts,Math.min(attempt,3));
  }
 } finally {globalThis.fetch=original;sqlite.close();}
});


test('identity migration preserves existing disclosure IDs and foreign keys',()=>{
 const {sqlite}=database(db=>{
  db.exec("INSERT INTO politicians(bioguide_id,name,normalized_name,updated_at) VALUES('A','Member','member','2026-10-06')");
  db.exec("INSERT INTO disclosures(id,provider,politician_id,representative,report_date,transaction_date,ticker,asset_name,transaction_type,owner,amount_range,raw_json,observed_at,updated_at) VALUES('existing','test','A','Member','2026-02-01','2026-01-01','ABC','Example','purchase','member','$1,001 - $15,000','{}','2026-02-01','2026-02-01')");
 });
 assert.equal(sqlite.prepare('SELECT bioguide_id,source_id FROM politicians').get().bioguide_id,'us:A');
 const record=sqlite.prepare('SELECT id,politician_id FROM disclosures').get(); assert.equal(record.id,'existing');assert.equal(record.politician_id,'us:A');
 assert.equal(sqlite.prepare('PRAGMA foreign_key_check').all().length,0);sqlite.close();
});

test('identity migration finishes a database already namespaced in batches',()=>{
 const disclosure=(id,member)=>`INSERT INTO disclosures(id,provider,politician_id,representative,report_date,transaction_date,ticker,asset_name,transaction_type,owner,amount_range,raw_json,observed_at,updated_at) VALUES('${id}','test','${member}','Member','2026-02-01','2026-01-01','ABC','Example','purchase','member','$1,001 - $15,000','{}','2026-02-01','2026-02-01')`;
 const {sqlite}=database(db=>{
  db.exec("INSERT INTO politicians(bioguide_id,name,normalized_name,updated_at) VALUES('A','Member','member','2026-10-06'),('us:A','Member','member','2026-10-06')");
  db.exec(disclosure('moved','us:A'));db.exec(disclosure('straggler','A'));
 });
 assert.deepEqual(sqlite.prepare('SELECT bioguide_id,source_id FROM politicians').all().map(r=>({...r})),[{bioguide_id:'us:A',source_id:'A'}]);
 assert.deepEqual(sqlite.prepare('SELECT DISTINCT politician_id FROM disclosures').all().map(r=>r.politician_id),['us:A']);
 assert.equal(sqlite.prepare('PRAGMA foreign_key_check').all().length,0);sqlite.close();
});

test('untickered funds stay separate and later purchases replace the missing-history status',()=>{
 const fund=buildMemberPortfolio([row('1','purchase','$1,001 - $15,000',{}, {asset_type:'MF',ticker:''})],{memberID:'A'});
 assert.equal(fund.positions[0].group,'funds');
 const p=buildMemberPortfolio([row('1','sale','$1,001 - $15,000'),row('2','purchase','$1,001 - $15,000')],{memberID:'A'});
 assert.equal(p.positions[0].status,'estimated-held');
});

import { reconcileStatements } from '../src/statements.js';
import { syncUK, matchUnresolvedInterests } from '../src/interests.js';
import { syncStatements, syncServiceDates, syncSecurityMetadata } from '../src/research.js';

test('SEC enrichment uses stored issuer identifiers and skips exchange-only securities',async()=>{
 const {DB,sqlite}=database();const original=globalThis.fetch;const requests=[];
 sqlite.exec("INSERT INTO securities(ticker,name,cik,source_url,updated_at) VALUES('OLD','Former dictionary issuer','1234','https://example.com/source','2026-01-01'),('LSE:HAL','Halma',NULL,'https://example.com/source','2026-01-01')");
 for (const record of [row('1','purchase','$1,001 - $15,000',{}, {ticker:'OLD'}),row('2','purchase','$1,001 - $15,000',{}, {ticker:'LSE:HAL'})]) {
  const fields=Object.keys(record).filter(k=>k!=='politician_id');
  sqlite.prepare(`INSERT INTO disclosures(${fields.join(',')},provider,representative,observed_at,updated_at) VALUES(${fields.map(()=>'?').join(',')},'test','Member','2026-02-01','2026-02-01')`).run(...fields.map(k=>record[k]));
 }
 globalThis.fetch=async(input)=>{requests.push(String(input));return Response.json(String(input).includes('company_tickers')?{}:{sic:'3571'});};
 try{
  await syncSecurityMetadata({DB,SEC_USER_AGENT:'Consigliere test'});
  assert.deepEqual(requests,['https://www.sec.gov/files/company_tickers.json','https://data.sec.gov/submissions/CIK0000001234.json']);
  assert.equal(sqlite.prepare("SELECT sector FROM securities WHERE ticker='OLD'").get().sector,'Technology');
  assert.equal(sqlite.prepare("SELECT sic FROM securities WHERE ticker='LSE:HAL'").get().sic,null);
 }finally{globalThis.fetch=original;sqlite.close();}
});

test('Federal Register confirmation preserves White House quote evidence',()=>{
 const wh={id:'wh',provider:'white-house',title:'An Action',body:'Original words',publishedAt:'2026-10-06T12:00:00Z',raw:'rss'};
 const fr={id:'fr',provider:'federal-register',title:'An action',body:'Official rendition',signedAt:'2026-10-06',publishedAt:'2026-10-08T12:00:00Z',documentNumber:'2026-1',sourceURL:'https://www.federalregister.gov/documents/2026-1',raw:{}};
 const rows=reconcileStatements([wh,fr]);assert.equal(rows.length,1);assert.equal(rows[0].body,wh.body);assert.equal(rows[0].documentNumber,'2026-1');assert.equal(rows[0].raw.confirmation.sourceURL,fr.sourceURL);
 assert.equal(reconcileStatements([wh,{...fr,title:'Different action'}]).length,2);
});

test('statement endpoints return neutral timing records and queue only valid tag corrections',async()=>{
 const {DB,sqlite}=database();
 const tag=ruleTags('Microsoft Corporation announced a tax change',[{ticker:'MSFT',name:'Microsoft Corporation'}]).find(t=>t.kind==='company');
 sqlite.prepare("INSERT INTO statements VALUES('statement','white-house','Action','Title','Microsoft Corporation announced a tax change','https://www.whitehouse.gov/test','2026-10-06T12:00:00Z',NULL,NULL,?,'Names a company',2,'{}','2026-10-06')").run(JSON.stringify([tag]));
 const detail=await researchRoute(new Request('https://example.com/v1/statements/statement'),{DB},r=>r);
 assert.equal((await detail.json()).data.tags[0].quote,tag.quote);
 const report=(tagID,reason)=>researchRoute(new Request('https://example.com/v1/statement-corrections',{method:'POST',body:JSON.stringify({statementID:'statement',tagID,reason})}),{DB},r=>r);
 assert.equal((await report('unknown','The issuer is incorrect')).status,400);
 assert.equal((await report(tag.id,'x')).status,400);
 assert.equal((await report(tag.id,'The issuer is incorrect')).status,202);
 await report(tag.id,'The issuer is incorrect');assert.equal(sqlite.prepare('SELECT COUNT(*) AS count FROM statement_corrections').get().count,1);
 assert.equal((await worker.fetch(new Request('https://example.com/internal/review'),{DB,SYNC_TOKEN:'secret'})).status,401);sqlite.close();
});

test('UK collector loads every roster page and preserves amended dates',async()=>{
 const {DB,sqlite}=database();const original=globalThis.fetch;
 const lord=JSON.parse(readFileSync(new URL('./fixtures/uk-lords-shareholdings.json',import.meta.url)));
 const makeMember=id=>({...lord.member,id,nameDisplayAs:`Peer ${id}`});let sawSecond=false;
 globalThis.fetch=async input=>{
  const url=new URL(input);let data;
  if(url.pathname.endsWith('/Categories'))data={items:[{id:8,number:'7',name:'Shareholdings'}]};
  else if(url.pathname.endsWith('/Members/Search')){const skip=Number(url.searchParams.get('skip')??0);sawSecond ||= skip===20;data={totalResults:21,take:20,items:Array.from({length:skip?1:20},(_,i)=>({value:makeMember(i+skip+1)}))};}
  else if(url.pathname.endsWith('/LordsInterests/Register'))data={totalResults:0,items:[]};
  else data={totalResults:0,take:20,items:[]};
  return Response.json(data);
 };
 try {
  await syncUK({DB,PUBLISHER_USER_AGENT:'Consigliere test'});assert.ok(sawSecond);assert.equal(sqlite.prepare('SELECT COUNT(*) AS count FROM politicians').get().count,21);
  const record={...lordsInterests(lord)[0],memberID:'uk:1'};await writeInterests(DB,[record]);
  await writeInterests(DB,[{...record,registeredAt:'2026-02-01',endedAt:'2026-09-01',action:'removed'}]);
  const stored=sqlite.prepare('SELECT registered_at,ended_at FROM interest_records WHERE id=?').get(record.id);assert.equal(stored.registered_at,'2026-02-01');assert.equal(stored.ended_at,'2026-09-01');
 }finally{globalThis.fetch=original;sqlite.close();}
});

test('public OpenFIGI matching respects its rate window and keeps ambiguous results for review',async()=>{
 const {DB,sqlite}=database();const original=globalThis.fetch;
 const lord=JSON.parse(readFileSync(new URL('./fixtures/uk-lords-shareholdings.json',import.meta.url)));await writeMembers(DB,[ukMember(lord.member)]);
 await writeInterests(DB,[{...lordsInterests(lord)[0],organisation:'Example PLC (technology)'}]);let requests=0;
 globalThis.fetch=async(_url,options)=>{requests++;assert.equal(JSON.parse(options.body).query,'Example PLC');assert.equal(options.headers['X-OPENFIGI-APIKEY'],undefined);return Response.json({data:[{name:'EXAMPLE PLC',ticker:'EX',figi:'BBG1',exchCode:'LN'}]});};
 try {
  assert.equal((await matchUnresolvedInterests({DB})).recordsWritten,1);
  assert.equal(sqlite.prepare('SELECT ticker FROM interest_records').get().ticker,'LSE:EX');
  await matchUnresolvedInterests({DB});assert.equal(requests,1);
  const candidates=[{name:'Example PLC',ticker:'LSE:EX',exchange:'LSE'},{name:'Example PLC',ticker:'LSE:EX2',exchange:'LSE'}];assert.equal(matchSecurity('Example PLC',candidates).reviewStatus,'needs-review');
 }finally{globalThis.fetch=original;sqlite.close();}
});

test('Congress departure dates freeze retained members without freezing current terms',async()=>{
 const {DB,sqlite}=database();const original=globalThis.fetch;
 sqlite.exec("INSERT INTO politicians(bioguide_id,name,normalized_name,updated_at) VALUES('us:A','Current','current','2026-10-06'),('us:B','Former','former','2026-10-06')");
 globalThis.fetch=async url=>Response.json(String(url).includes('current')?[{id:{bioguide:'A'},terms:[{end:'2027-01-03'}]}]:[{id:{bioguide:'B'},terms:[{end:'2025-01-03'}]}]);
 try{await syncServiceDates({DB});assert.equal(sqlite.prepare("SELECT service_end FROM politicians WHERE bioguide_id='us:A'").get().service_end,null);assert.equal(sqlite.prepare("SELECT service_end FROM politicians WHERE bioguide_id='us:B'").get().service_end,'2025-01-03');}finally{globalThis.fetch=original;sqlite.close();}
});

test('statement re-sync retains first-mention relevance and exact evidence',async()=>{
 const {DB,sqlite}=database();const original=globalThis.fetch;
 const feed='<item><title>Policy</title><link>https://www.whitehouse.gov/presidential-actions/policy/</link><pubDate>Tue, 06 Oct 2026 01:00:00 GMT</pubDate><description>New tariff on steel.</description></item>';
 globalThis.fetch=async url=>String(url).includes('whitehouse.gov')?new Response(feed):Response.json({results:[]});
 try{await syncStatements({DB});const first=sqlite.prepare('SELECT priority,tags FROM statements').get();await syncStatements({DB});const second=sqlite.prepare('SELECT priority,tags FROM statements').get();assert.deepEqual(second,first);assert.equal(second.priority,2);}finally{globalThis.fetch=original;sqlite.close();}
});


import { annualAnchor, ANNUAL_PARSER_VERSION, syncHouseAnnual } from '../src/house-annual.js';
test('annual values anchor later trades without counting older purchases twice',()=>{
 const anchor={asOf:'2025-12-31',filedDate:'2026-05-15',sourceURL:'https://disclosures-clerk.house.gov/annual.pdf',assets:[{name:'Example',ticker:'ABC',assetType:'ST',owner:'member',amountRange:'$1,001 - $15,000'},{name:'Example',ticker:'ABC',assetType:'ST',owner:'spouse',amountRange:'$1,001 - $15,000'}]};
 const rows=[row('1','purchase','$1,001 - $15,000',{}, {transaction_date:'2025-12-01'}),row('2','sale','$1,001 - $5,000',{partial:true})];
 const p=buildMemberPortfolio(rows,{memberID:'A',anchor});assert.equal(p.positions.find(p=>p.owner==='member').estimate,5000);assert.equal(p.changes.length,1);assert.equal(p.anchorSourceURL,anchor.sourceURL);
 assert.equal(buildMemberPortfolio(rows,{memberID:'A',anchor,ownOnly:true}).positions.length,1);
 assert.equal(p.positions[0].lastActivity,'2026-05-15');
});
test('annual anchors ignore review reports and evidence published after departure',()=>{
 const annual={doc_id:'annual',member_id:'A',reporting_year:2025,filed_date:'2026-05-15',source_url:'https://example.com/source',parser_version:ANNUAL_PARSER_VERSION,status:'extracted',assets:'[]'};
 assert.equal(annualAnchor([annual],'A','2026-02-01'),null);assert.equal(annualAnchor([{...annual,status:'needs-review'}],'A'),null);assert.equal(annualAnchor([annual],'A').asOf,'2025-12-31');
});
test('annual extraction preserves the previous anchor when a report fails validation',async()=>{
 const {DB,sqlite}=database();sqlite.exec("INSERT INTO politicians(bioguide_id,name,normalized_name,updated_at) VALUES('us:A','Member','member','2026-10-06')");
 sqlite.exec("INSERT INTO house_annual_reports(doc_id,member_id,reporting_year,filed_date,source_url) VALUES('10001','us:A',2025,'2026-05-15','https://disclosures-clerk.house.gov/public_disc/financial-pdfs/2025/10001.pdf')");
 const original=globalThis.fetch;globalThis.fetch=async()=>new Response('',{status:403});
 try{for(let i=0;i<4;i++)await syncHouseAnnual({DB},{refreshIndex:false});const r=sqlite.prepare('SELECT status,attempts FROM house_annual_reports').get();assert.equal(r.status,'failed');assert.equal(r.attempts,3);}finally{globalThis.fetch=original;sqlite.close();}
});


import { zipSync, strToU8 } from 'fflate';
test('routine Apify requests Senate only after the indexed House backlog is classified',async()=>{
 const {DB,sqlite}=database();const original=globalThis.fetch;const chambers=[];
 sqlite.exec("INSERT INTO source_filings VALUES('filing','house','Member','house','2026-10-01','https://disclosures-clerk.house.gov/public_disc/ptr-pdfs/2026/20039999.pdf','20039999','official-metadata','{}','2026-10-01','2026-10-01')");
 sqlite.exec("INSERT INTO house_ptr_extractions(doc_id,filing_url,disclosure_date,parser_version,status,attempts) VALUES('20039999','https://disclosures-clerk.house.gov/public_disc/ptr-pdfs/2026/20039999.pdf','2026-10-01',1,'needs-review',1)");
 globalThis.fetch=async(input,options)=>{
  const url=new URL(input);
  if(url.hostname==='api.apify.com' && url.pathname.endsWith('/runs')){chambers.push(JSON.parse(options.body).chamber);return Response.json({data:{status:'SUCCEEDED',defaultDatasetId:'test-dataset'}});}
  if(url.hostname==='api.apify.com')return Response.json([]);
  if(url.hostname==='test.example')return new Response('Prefix\tLast\tFirst\tSuffix\tFilingType\tStateDst\tYear\tFilingDate\tDocID');
  if(url.pathname.endsWith('FD.zip'))return new Response(zipSync({'2025FD.txt':strToU8('Prefix\tLast\tFirst\tSuffix\tFilingType\tStateDst\tYear\tFilingDate\tDocID')}));
  if(url.pathname.endsWith('/Categories'))return Response.json({items:[{id:8,number:'7',name:'Shareholdings'}]});
  if(url.hostname.includes('parliament.uk'))return Response.json({totalResults:0,take:20,items:[]});
  if(url.hostname==='www.whitehouse.gov')return new Response('<rss/>');
  if(url.hostname==='www.federalregister.gov')return Response.json({results:[]});
  if(url.pathname.includes('committee-membership'))return Response.json({});
  return Response.json([]);
 };
 const env={DB,SYNC_TOKEN:'test',APIFY_API_TOKEN:'fake-for-test',HOUSE_PTR_MODE:'live',HOUSE_INDEX_URL:'https://test.example/index.txt'};
 const run=()=>worker.fetch(new Request('https://example.com/internal/sync',{method:'POST',headers:{authorization:'Bearer test'}}),env);
 try{
  assert.equal((await run()).status,200);assert.deepEqual(chambers,['house','senate']);chambers.length=0;
  sqlite.exec("UPDATE house_ptr_extractions SET status='extracted'");assert.equal((await run()).status,200);assert.deepEqual(chambers,['senate']);
 }finally{globalThis.fetch=original;sqlite.close();}
});

test('funds are grouped by House code or an ETF name filed as a stock',()=>{
 assert.equal(assetGroup({asset_type:'EF',ticker:'VOO',asset_name:'Vanguard S&P 500 ETF (VOO)'}),'funds');
 assert.equal(assetGroup({asset_type:'ST',ticker:'IWR',asset_name:'iShares Russell Mid-Cap ETF (IWR)'}),'funds');
 assert.equal(assetGroup({asset_type:'ST',ticker:'NFLX',asset_name:'Netflix, Inc.'}),'stocks');
 assert.equal(assetGroup({asset_type:'OP',ticker:'MSFT',asset_name:'Microsoft ETF-linked call'}),'options');
});
