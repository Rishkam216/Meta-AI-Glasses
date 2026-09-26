import { before, after, beforeEach, test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { MemoryBackend } from '../src/memory.mjs';
import { SessionIssuer } from '../src/sessions.mjs';
import { createTestDatabase, asSession } from './support.mjs';

let db, issuer, api, identities, tokens;
before(async () => {
  db = await createTestDatabase(); issuer = new SessionIssuer(db.auth); api = new MemoryBackend(db.runtime);
});
after(async () => { if (db) await db.close(); });
beforeEach(async () => {
  const tenant=randomUUID(), account=randomUUID();
  identities=[
    {tenantID:tenant,userID:randomUUID(),accountID:account},
    {tenantID:tenant,userID:randomUUID(),accountID:account},
    {tenantID:randomUUID(),userID:randomUUID(),accountID:null}
  ];
  tokens=[];
  for(const identity of identities) tokens.push((await issuer.issue(identity)).token);
});
const run=(who,operation,input={}) => api.execute('Bearer '+tokens[who],{operation,input});
const code=(expected) => e => e.code===expected;

function record(identity,id,marker) {
  return {
    id, tenant:identity, scope:{kind:'user'}, kind:'source_backed',
    content:{marker}, sourceReferences:[], derivedFromMemoryIDs:[],
    visibility:'private_user', state:'active', supersedes:[],
    createdAt:0, updatedAt:0
  };
}
function snapshot(identity, marker='empty', id=randomUUID()) {
  return {
    formatVersion:3, exportedAt:0,
    memories:marker==='empty'?[]:[record(identity,id,marker)],
    providerMappings:[], tombstones:[],
    synchronization:{providers:[],sequence:0,entries:[],attemptTimes:{}}
  };
}

test('canonical state starts empty and CAS commit round-trips a v3 snapshot',async () => {
  assert.deepEqual(await run(0,'canonical_load'),{revision:0,snapshot:null});
  const state=snapshot(identities[0],'owner');
  assert.deepEqual(await run(0,'canonical_commit',{expectedRevision:0,snapshot:state}),{revision:1});
  assert.deepEqual(await run(0,'canonical_load'),{revision:1,snapshot:state});
});

test('same canonical memory ID remains isolated across principals',async () => {
  const id=randomUUID();
  for(let i=0;i<3;i++) {
    const state=snapshot(identities[i],'principal-'+i,id);
    await run(i,'canonical_commit',{expectedRevision:0,snapshot:state});
  }
  for(let i=0;i<3;i++) {
    const loaded=await run(i,'canonical_load');
    assert.equal(loaded.snapshot.memories.length,1);
    assert.equal(loaded.snapshot.memories[0].id,id);
    assert.equal(loaded.snapshot.memories[0].content.marker,'principal-'+i);
    const raw=await asSession(db.runtime,tokens[i],tx=>tx.query('SELECT revision,snapshot FROM agent_canonical.snapshots'));
    assert.equal(raw.rows.length,1);
    assert.equal(raw.rows[0].snapshot.memories[0].content.marker,'principal-'+i);
  }
});

test('stale canonical revision fails instead of losing a concurrent update',async () => {
  const first=snapshot(identities[0],'first');
  await run(0,'canonical_commit',{expectedRevision:0,snapshot:first});
  const second=snapshot(identities[0],'second');
  assert.deepEqual(await run(0,'canonical_commit',{expectedRevision:1,snapshot:second}),{revision:2});
  await assert.rejects(run(0,'canonical_commit',{expectedRevision:1,snapshot:first}),code('state_conflict'));
  const loaded=await run(0,'canonical_load');
  assert.equal(loaded.revision,2); assert.equal(loaded.snapshot.memories[0].content.marker,'second');
});

test('foreign identities embedded in memories, tombstones, or sync entries are rejected',async () => {
  const foreign=identities[1];
  const memorySnapshot=snapshot(foreign,'foreign-memory');
  await assert.rejects(run(0,'canonical_commit',{expectedRevision:0,snapshot:memorySnapshot}),code('invalid_request'));

  const tombstoneSnapshot=snapshot(identities[0]);
  tombstoneSnapshot.tombstones=[{memoryID:randomUUID(),tenant:foreign,deletedAt:0}];
  await assert.rejects(run(0,'canonical_commit',{expectedRevision:0,snapshot:tombstoneSnapshot}),code('invalid_request'));

  const syncSnapshot=snapshot(identities[0]);
  syncSnapshot.synchronization.providers=['provider']; syncSnapshot.synchronization.sequence=1;
  syncSnapshot.synchronization.entries=[{operationID:randomUUID(),tenant:foreign,providerID:'provider',memoryID:randomUUID(),revision:1,action:'upsert',acknowledged:false}];
  await assert.rejects(run(0,'canonical_commit',{expectedRevision:0,snapshot:syncSnapshot}),code('invalid_request'));
});

test('absent account identity is accepted only for the matching principal',async () => {
  const own=snapshot(identities[2],'no-account');
  await run(2,'canonical_commit',{expectedRevision:0,snapshot:own});
  assert.equal((await run(2,'canonical_load')).snapshot.memories[0].content.marker,'no-account');
  const forged=snapshot({...identities[2],accountID:randomUUID()},'forged-account');
  await assert.rejects(run(2,'canonical_commit',{expectedRevision:1,snapshot:forged}),code('invalid_request'));
});

test('runtime cannot mutate canonical table and writer RLS rejects foreign principal',async () => {
  await run(0,'canonical_commit',{expectedRevision:0,snapshot:snapshot(identities[0],'owner')});
  await assert.rejects(asSession(db.runtime,tokens[0],tx=>tx.query('UPDATE agent_canonical.snapshots SET revision=revision+1')),code('42501'));
  const foreign=await asSession(db.runtime,tokens[1],tx=>tx.query('SELECT agent_private.current_principal() AS p'));
  await assert.rejects(asSession(db.writer,tokens[0],tx=>tx.query(
    'INSERT INTO agent_canonical.snapshots(principal_id,revision,snapshot) VALUES($1,1,$2::jsonb)',
    [foreign.rows[0].p,JSON.stringify(snapshot(identities[1],'foreign'))])),code('42501'));
});

test('canonical table has FORCE RLS and non-owner ownership',async () => {
  const result=await db.admin.query("SELECT relrowsecurity,relforcerowsecurity,pg_get_userbyid(relowner) AS owner FROM pg_class WHERE oid='agent_canonical.snapshots'::regclass");
  assert.equal(result.rows.length,1);
  assert.equal(result.rows[0].relrowsecurity,true);
  assert.equal(result.rows[0].relforcerowsecurity,true);
  assert.equal(result.rows[0].owner,'agent_owner');
});

test('revoked session cannot load canonical state',async () => {
  await run(0,'canonical_commit',{expectedRevision:0,snapshot:snapshot(identities[0],'owner')});
  await issuer.revoke(tokens[0]);
  await assert.rejects(run(0,'canonical_load'),code('unauthenticated'));
});
