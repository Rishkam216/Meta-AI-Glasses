import { before, after, beforeEach, test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID, randomBytes, createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { MemoryBackend } from '../src/memory.mjs';
import { SessionIssuer } from '../src/sessions.mjs';
import { createMemoryHandler } from '../src/http.mjs';
import { createTestDatabase, asSession } from './support.mjs';

let db, issuer, api, identities, tokens;
before(async () => {
  db = await createTestDatabase(); issuer = new SessionIssuer(db.auth); api = new MemoryBackend(db.runtime);
});
after(async () => { if (db) await db.close(); });
beforeEach(async () => {
  const t=randomUUID(), u=randomUUID(), a=randomUUID();
  identities=[{tenantID:t,userID:u,accountID:a},{tenantID:t,userID:randomUUID(),accountID:a},
    {tenantID:randomUUID(),userID:u,accountID:a},{tenantID:t,userID:u,accountID:randomUUID()},
    {tenantID:t,userID:u,accountID:null}];
  tokens=[];
  for(const id of identities) tokens.push((await issuer.issue(id)).token);
});
const run=(who,operation,input={}) => api.execute('Bearer '+tokens[who],{operation,input});
const remember=(who,id=randomUUID(),content='CANARY',scope={kind:'user'}) =>
  run(who,'remember',{id,content,scope,provenance:[{type:'test',reference:'synthetic-only'}]});
const code=(expected) => e => e.code===expected;

test('identity is derived from an opaque session with all account variants distinct',async () => {
  for(let i=0;i<5;i++) assert.deepEqual(await run(i,'identity'),identities[i]);
  const other=(await issuer.issue(identities[4])).token;
  const old=tokens[4]; await remember(4); tokens[4]=other;
  assert.equal((await run(4,'export')).length,1); tokens[4]=old;
});

test('same canonical ID across five principals stays private in direct reads and export',async () => {
  const id=randomUUID();
  for(let i=0;i<5;i++) await remember(i,id,'CANARY-'+i);
  for(let i=0;i<5;i++) {
    assert.equal((await run(i,'get',{id})).content,'CANARY-'+i);
    const records=await run(i,'export'); assert.equal(records.length,1); assert.equal(records[0].content,'CANARY-'+i);
    const raw=await asSession(db.runtime,tokens[i],tx=>tx.query('SELECT * FROM agent_data.memories'));
    assert.equal(raw.rows.length,1); assert.equal(raw.rows[0].content,'CANARY-'+i);
  }
});

test('foreign direct lookup and deletion reveal no record and leave owner data intact',async () => {
  const id=await remember(1);
  assert.equal(await run(0,'get',{id}),null);
  await run(0,'forget',{id});
  assert.equal((await run(1,'get',{id})).content,'CANARY');
  assert.equal((await run(1,'export')).length,1);
});

test('all five principals reject every foreign canary query with positive controls',async () => {
  for(let i=0;i<5;i++) await remember(i,randomUUID(),'UNIQUE-CANARY-'+i);
  for(let i=0;i<5;i++) for(let j=0;j<5;j++) {
    const hits=await run(i,'search',{query:'UNIQUE-CANARY-'+j,scope:{kind:'user'}});
    assert.equal(hits.length,i===j?1:0);
  }
});

test('same query cache partitions by principal and scope including absent account',async () => {
  const project={kind:'project',referenceID:'same'}, workspace={kind:'workspace',referenceID:'same'};
  for(let i=0;i<5;i++) await remember(i,randomUUID(),'common '+i);
  await remember(0,randomUUID(),'common project',project); await remember(0,randomUUID(),'common workspace',workspace);
  for(let pass=0;pass<2;pass++) for(let i=0;i<5;i++) {
    const hits=await run(i,'search',{query:'common',scope:{kind:'user'}});
    assert.equal(hits.length,1); assert.equal(hits[0].content,'common '+i);
  }
  assert.equal((await run(0,'search',{query:'common',scope:project}))[0].content,'common project');
  assert.equal((await run(0,'search',{query:'common',scope:workspace}))[0].content,'common workspace');
  const rows=await asSession(db.runtime,tokens[1],tx=>tx.query('SELECT * FROM agent_data.retrieval_cache'));
  assert.equal(rows.rows.length,1); assert.equal(Object.hasOwn(rows.rows[0],'content'),false);
});

test('deletion invalidates populated cache and tombstones prevent resurrection',async () => {
  const id=await remember(0);
  assert.equal((await run(0,'search',{query:'CANARY',scope:{kind:'user'}})).length,1);
  await run(0,'forget',{id});
  assert.deepEqual(await run(0,'search',{query:'CANARY',scope:{kind:'user'}}),[]);
  assert.equal(await run(0,'get',{id}),null);
  await assert.rejects(remember(0,id),code('memory_conflict'));
  await remember(1,id); // Tombstones are also exactly principal-scoped.
  const records=await run(0,'export'); assert.equal(records[0].entry_type,'tombstone');
});

test('new records invalidate a cached empty result',async () => {
  assert.deepEqual(await run(0,'search',{query:'CANARY',scope:{kind:'user'}}),[]);
  await remember(0);
  assert.equal((await run(0,'search',{query:'CANARY',scope:{kind:'user'}})).length,1);
});

test('cache key includes limit and cursor export remains principal scoped',async () => {
  for(let i=0;i<3;i++) await remember(0);
  await remember(1);
  assert.equal((await run(0,'search',{query:'CANARY',scope:{kind:'user'},limit:1})).length,1);
  assert.equal((await run(0,'search',{query:'CANARY',scope:{kind:'user'},limit:3})).length,3);
  const first=await run(0,'export',{limit:2}); const next=await run(0,'export',{afterID:first[1].id,limit:2});
  assert.equal(first.length,2); assert.equal(next.length,1);
  assert.equal(new Set([...first,...next].map(x=>x.id)).size,3);
});

test('expired or revoked session cannot read even a warm cache',async () => {
  await remember(0); await run(0,'search',{query:'CANARY',scope:{kind:'user'}});
  await issuer.revoke(tokens[0]);
  await assert.rejects(run(0,'search',{query:'CANARY',scope:{kind:'user'}}),code('unauthenticated'));
  await db.admin.query('UPDATE agent_private.sessions SET expires_at=now()-interval \'1 second\' WHERE token_hash=$1',
    [createHash('sha256').update(tokens[1]).digest()]);
  await assert.rejects(run(1,'identity'),code('unauthenticated'));
});

test('forged, missing and malformed bearer tokens fail closed',async () => {
  for(const header of [null,'','Bearer '+randomBytes(32).toString('base64url'),'Bearer bad','Basic abc'])
    await assert.rejects(api.execute(header,{operation:'identity'}),code('unauthenticated'));
});

test('model-supplied identities and extra operation fields are rejected',async () => {
  for(const field of ['tenantID','userID','accountID','principal_id','authorization'])
    await assert.rejects(run(0,'search',{query:'CANARY',scope:{kind:'user'},[field]:identities[1].userID}),code('invalid_request'));
  await assert.rejects(api.execute('Bearer '+tokens[0],{operation:'export',tenantID:identities[1].tenantID}),code('invalid_request'));
});

test('forged identity settings cannot override the authenticated principal',async () => {
  await remember(0,randomUUID(),'OWNER'); await remember(1,randomUUID(),'FOREIGN');
  const rows=await asSession(db.runtime,tokens[0],async tx=>{
    await tx.query("SELECT set_config('agent.tenant_id',$1,true), set_config('agent.user_id',$2,true)",
      [identities[1].tenantID,identities[1].userID]);
    return tx.query('SELECT content FROM agent_data.memories');
  });
  assert.deepEqual(rows.rows.map(x=>x.content),['OWNER']);
});

test('runtime cannot read sessions, mint sessions, mutate tables or truncate',async () => {
  await remember(0);
  const attempts=[
    'SELECT * FROM agent_private.sessions', 'SELECT * FROM agent_private.principals',
    "SELECT agent_private.issue_session(gen_random_uuid(),gen_random_uuid(),NULL,sha256('x'::bytea),now()+interval '1 hour')",
    'UPDATE agent_data.memories SET content=\'"changed"\'::jsonb',
    'DELETE FROM agent_data.memories', 'TRUNCATE agent_data.memories',
    'ALTER TABLE agent_data.memories DISABLE ROW LEVEL SECURITY',
    'DELETE FROM agent_data.tombstones', 'DELETE FROM agent_data.retrieval_cache'
  ];
  for(const sql of attempts) await assert.rejects(asSession(db.runtime,tokens[0],tx=>tx.query(sql)),code('42501'));
});

test('RLS WITH CHECK rejects foreign inserts even by the non-owner writer',async () => {
  const foreign=await asSession(db.runtime,tokens[1],tx=>tx.query('SELECT agent_private.current_principal() AS p'));
  await assert.rejects(asSession(db.writer,tokens[0],tx=>tx.query(
    "INSERT INTO agent_data.memories(principal_id,id,scope_kind,content) VALUES($1,$2,'user','{}')",
    [foreign.rows[0].p,randomUUID()])),code('42501'));
});

test('immutable records refuse ownership changes and in-place edits',async () => {
  await remember(0);
  await assert.rejects(asSession(db.writer,tokens[0],tx=>tx.query(
    'UPDATE agent_data.memories SET principal_id=gen_random_uuid()')),code('42501'));
  await assert.rejects(asSession(db.writer,tokens[0],tx=>tx.query(
    'UPDATE agent_data.memories SET content=\'{}\'::jsonb')),code('42501'));
});

test('unauthenticated direct SQL and RLS-off attempts cannot expose rows',async () => {
  await remember(0);
  await assert.rejects(db.runtime.transaction(tx=>tx.query('SELECT * FROM agent_data.memories')),code('28000'));
  await assert.rejects(asSession(db.runtime,tokens[0],async tx=>{
    await tx.query('SET LOCAL row_security=off'); return tx.query('SELECT * FROM agent_data.memories');
  }),code('42501'));
});

test('commit and rollback both clear transaction session context on connection reuse',async () => {
  await run(0,'identity');
  await assert.rejects(db.runtime.transaction(tx=>tx.query('SELECT agent_private.current_principal()')),code('28000'));
  await assert.rejects(asSession(db.runtime,tokens[1],async tx=>{await tx.query('SELECT 1/0');}));
  await assert.rejects(db.runtime.transaction(tx=>tx.query('SELECT agent_private.current_principal()')),code('28000'));
  assert.deepEqual(await run(2,'identity'),identities[2]);
});

test('schema has forced RLS and runtime/writer have no ownership or bypass',async () => {
  const tables=await db.admin.query("SELECT relrowsecurity,relforcerowsecurity,pg_get_userbyid(relowner) AS owner FROM pg_class WHERE relnamespace='agent_data'::regnamespace AND relkind='r'");
  assert.equal(tables.rows.length,4);
  assert(tables.rows.every(x=>x.relrowsecurity&&x.relforcerowsecurity&&x.owner==='agent_owner'));
  const roles=await db.admin.query("SELECT rolsuper,rolbypassrls,rolcreaterole FROM pg_roles WHERE rolname IN ('agent_runtime','agent_writer')");
  assert(roles.rows.every(x=>!x.rolsuper&&!x.rolbypassrls&&!x.rolcreaterole));
});

test('query injection remains literal and bounded inputs reject invalid sizes',async () => {
  await remember(0);
  assert.deepEqual(await run(0,'search',{query:"' OR true --",scope:{kind:'user'}}),[]);
  await assert.rejects(run(0,'search',{query:'x',scope:{kind:'user'},limit:101}),code('invalid_request'));
  await assert.rejects(remember(0,randomUUID(),'x'.repeat(24001)),code('invalid_request'));
  await assert.rejects(run(0,'search',{query:'x',scope:{kind:'project',referenceID:''}}),code('invalid_request'));
});

test('HTTP boundary derives identity from header, rejects malformed JSON and never caches replies',async () => {
  const server=createServer(createMemoryHandler(api));
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const url=`http://127.0.0.1:${server.address().port}/v1/memory`;
  try {
    const response=await fetch(url,{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+tokens[0]},body:JSON.stringify({operation:'identity'})});
    assert.equal(response.status,200); assert.equal(response.headers.get('cache-control'),'no-store');
    assert.deepEqual((await response.json()).result,identities[0]);
    const bad=await fetch(url,{method:'POST',headers:{'Content-Type':'application/json'},body:'{bad'});
    assert.equal(bad.status,400); assert.deepEqual(await bad.json(),{error:'invalid_json'});
    const missing=await fetch(url,{method:'POST',headers:{'Content-Type':'application/json'},body:'{"operation":"export"}'});
    assert.equal(missing.status,401);
    const large=await fetch(url,{method:'POST',headers:{'Content-Type':'application/json'},body:'x'.repeat(40001)});
    assert.equal(large.status,413);
  } finally { server.closeAllConnections(); await new Promise(resolve=>server.close(resolve)); }
});

test('native login cannot SET ROLE to writer/auth/owner',async t => {
  if(!db.native) return t.skip('PGlite single connection cannot test PostgreSQL login privileges');
  for(const role of ['agent_writer','agent_owner','agent_auth'])
    await assert.rejects(db.runtime.transaction(tx=>tx.query('SET ROLE '+role)),code('42501'));
});

test('cached IDs are re-resolved under principal and scope instead of trusted as payload',async () => {
  const own=await remember(0), foreign=await remember(1), project=await remember(0,randomUUID(),'CANARY',{kind:'project',referenceID:'private'});
  await run(0,'search',{query:'CANARY',scope:{kind:'user'}});
  await asSession(db.writer,tokens[0],tx=>tx.query('UPDATE agent_data.retrieval_cache SET memory_ids=$1::uuid[]',[[own,foreign,project]]));
  const result=await run(0,'search',{query:'CANARY',scope:{kind:'user'}});
  assert.deepEqual(result.map(x=>x.id),[own]);
});

test('cache eviction enforces its per-principal bound without deleting another cache',async () => {
  await remember(1); await run(1,'search',{query:'CANARY',scope:{kind:'user'}});
  for(let i=0;i<130;i++) await run(0,'search',{query:'query '+i,scope:{kind:'user'}});
  const counts=await asSession(db.runtime,tokens[0],tx=>tx.query('SELECT count(*)::int AS count FROM agent_data.retrieval_cache'));
  assert(counts.rows[0].count<=128);
  const other=await asSession(db.runtime,tokens[1],tx=>tx.query('SELECT count(*)::int AS count FROM agent_data.retrieval_cache'));
  assert.equal(other.rows[0].count,1);
});

test('database errors do not disclose SQL parameters or private memory',async () => {
  const broken=new MemoryBackend({transaction:async()=>{throw new Error('secret bearer and private memory');}});
  await assert.rejects(broken.execute('Bearer '+tokens[0],{operation:'identity'}),
    e=>e.status===503 && e.message==='storage_unavailable' && e.cause===undefined);
});

test('native simultaneous cache population and deletion never leave stale results',async t => {
  if(!db.native) return t.skip('Requires independent PostgreSQL connections');
  for(let i=0;i<5;i++) {
    const id=await remember(0);
    await Promise.all([run(0,'search',{query:'CANARY',scope:{kind:'user'}}),run(0,'forget',{id})]);
    assert.deepEqual(await run(0,'search',{query:'CANARY',scope:{kind:'user'}}),[]);
  }
});

test('native revocation waits for an already authenticated transaction then denies future calls',async t => {
  if(!db.native) return t.skip('Requires independent PostgreSQL connections');
  let ready, release;
  const authenticated=new Promise(r=>{ready=r;}); const hold=new Promise(r=>{release=r;});
  const active=asSession(db.runtime,tokens[0],async tx=>{
    await tx.query('SELECT agent_private.current_principal()'); ready(); await hold;
  });
  await authenticated;
  let revoked=false;
  const revocation=issuer.revoke(tokens[0]).then(()=>{revoked=true;});
  try { await new Promise(r=>setTimeout(r,50)); assert.equal(revoked,false); }
  finally { release(); await active; await revocation; }
  await assert.rejects(run(0,'identity'),code('unauthenticated'));
});

test('cached candidates must still match the requested query and result limit',async () => {
  const matching=[];
  for(let i=0;i<3;i++) matching.push(await remember(0,randomUUID(),'MATCHING-CANARY'));
  const irrelevant=await remember(0,randomUUID(),'UNRELATED-PRIVATE-FACT');
  await run(0,'search',{query:'MATCHING-CANARY',scope:{kind:'user'},limit:1});
  await asSession(db.writer,tokens[0],tx=>tx.query(
    'UPDATE agent_data.retrieval_cache SET memory_ids=$1::uuid[]',[[irrelevant,...matching]]));
  const hits=await run(0,'search',{query:'MATCHING-CANARY',scope:{kind:'user'},limit:1});
  assert.equal(hits.length,1); assert.equal(hits[0].content,'MATCHING-CANARY');
  await asSession(db.writer,tokens[0],tx=>tx.query(
    'UPDATE agent_data.retrieval_cache SET memory_ids=$1::uuid[]',[[irrelevant]]));
  assert.deepEqual(await run(0,'search',{query:'MATCHING-CANARY',scope:{kind:'user'},limit:1}),[]);
});

test('all auxiliary tables filter out other principals without application predicates',async () => {
  for(let i=0;i<5;i++) {
    await remember(i); const removed=await remember(i); await run(i,'forget',{id:removed});
    await run(i,'search',{query:'CANARY',scope:{kind:'user'}});
  }
  for(let i=0;i<5;i++) await asSession(db.runtime,tokens[i],async tx=>{
    const principal=(await tx.query('SELECT agent_private.current_principal() AS p')).rows[0].p;
    for(const table of ['memories','tombstones','revisions','retrieval_cache']) {
      const result=await tx.query('SELECT principal_id FROM agent_data.'+table);
      assert(result.rows.length>0,table+' positive control');
      assert(result.rows.every(row=>row.principal_id===principal),table+' ownership');
    }
  });
});

test('cache replacement migration retains restricted function ownership and execution rights',async () => {
  const fn=(await db.admin.query(`SELECT pg_get_userbyid(proowner) AS owner, prosecdef,
    has_function_privilege('agent_runtime',oid,'EXECUTE') AS runtime_access,
    has_function_privilege('agent_auth',oid,'EXECUTE') AS auth_access
    FROM pg_proc WHERE oid='agent_api.search_memories(text,text,text,integer)'::regprocedure`)).rows[0];
  assert.equal(fn.owner,'agent_writer'); assert.equal(fn.prosecdef,true);
  assert.equal(fn.runtime_access,true); assert.equal(fn.auth_access,false);
});
