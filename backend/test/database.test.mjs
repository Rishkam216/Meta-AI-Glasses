import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PostgresTransactions, runtimeDatabase } from '../src/database.mjs';

function fixture(overrides={}) {
  const calls=[]; let released;
  const client={async query(sql) {
    calls.push(sql);
    if(sql.includes('pg_roles')) return {rows:[{role:'agent_runtime',login:'agent_runtime',...overrides}]};
    return {rows:[]};
  },release(destroy){released=destroy;}};
  return {calls,client,pool:{connect:async()=>client},released:()=>released};
}
test('runtime pool rejects superusers, bypass roles, wrong logins and privileged memberships before work',async () => {
  for(const overrides of [{rolsuper:true},{rolbypassrls:true},{rolcreaterole:true},{rolreplication:true},
    {owner_member:true},{writer_member:true},{other_member:true},{login:'postgres'},{role:'agent_auth'}]) {
    const f=fixture(overrides); let called=false;
    await assert.rejects(new PostgresTransactions(f.pool).transaction(async()=>{called=true;}),/unsafe_database_role/);
    assert.equal(called,false); assert(f.calls.includes('ROLLBACK')); assert.equal(f.released(),false);
  }
});
test('rollback failure destroys the pooled connection instead of reusing its session',async () => {
  const f=fixture(); const original=f.client.query;
  f.client.query=async sql=>{if(sql==='ROLLBACK')throw new Error('broken connection'); return original(sql);};
  await assert.rejects(new PostgresTransactions(f.pool).transaction(async()=>{throw new Error('failed');}),/failed/);
  assert.equal(f.released(),true);
});
test('commit failure is rolled back and never reported successful',async () => {
  const f=fixture(); const original=f.client.query;
  f.client.query=async sql=>{if(sql==='COMMIT')throw new Error('commit response lost'); return original(sql);};
  await assert.rejects(new PostgresTransactions(f.pool).transaction(async()=>42),/commit response lost/);
  assert(f.calls.includes('ROLLBACK')); assert.equal(f.released(),false);
});
test('database URL cannot override host or certificate verification through query parameters',() => {
  assert.throws(()=>runtimeDatabase('postgres://u:p@localhost/db?host=remote'),/invalid_database_url/);
  assert.throws(()=>runtimeDatabase('postgres://u:p@remote/db?sslmode=disable'),/invalid_database_url/);
  assert.throws(()=>runtimeDatabase('https://remote/db'),/invalid_database_url/);
});
