import { PGlite } from '@electric-sql/pglite';
import pg from 'pg';
import { readFile, readdir } from 'node:fs/promises';
import { PostgresTransactions } from '../src/database.mjs';

export async function createTestDatabase() {
  if (process.env.REQUIRE_NATIVE_POSTGRES === '1' && !process.env.TEST_POSTGRES_URL)
    throw new Error('native_postgres_configuration_required');
  const directory = new URL('../sql/', import.meta.url);
  const names = (await readdir(directory)).filter(name => /^\d{3}_.*\.sql$/.test(name)).sort();
  const migrations = await Promise.all(names.map(name => readFile(new URL(name, directory), 'utf8')));
  if (!process.env.TEST_POSTGRES_URL) {
    const db = await PGlite.create();
    for (const migration of migrations) await db.exec(migration);
    const role = name => ({ transaction: work => db.transaction(async tx => {
      await tx.exec(`SET LOCAL ROLE ${name}`); return work(tx);
    }) });
    return { admin: db, runtime: role('agent_runtime'), auth: role('agent_auth'),
      writer: role('agent_writer'), native: false, close: () => db.close() };
  }
  // Native tests require an explicitly named disposable local database. Never
  // apply test-role credentials to an arbitrary supplied production endpoint.
  const url = new URL(process.env.TEST_POSTGRES_URL);
  if (!['localhost','127.0.0.1','[::1]'].includes(url.hostname) || url.pathname !== '/agent_isolation_test')
    throw new Error('disposable_local_test_database_required');
  const adminPool = new pg.Pool({ connectionString: url.href });

  // node:test files run sequentially against one native PostgreSQL service. The
  // bootstrap migration owns roles and default privileges at cluster/database
  // scope, so it must run once. Later test files reuse that isolated fixture;
  // each test issues fresh random principals, so persisted rows cannot collide.
  const installed = await adminPool.query("SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='agent_owner') AS value");
  if (!installed.rows[0].value) {
    for (const migration of migrations) await adminPool.query(migration);
    await adminPool.query("ALTER ROLE agent_runtime LOGIN PASSWORD 'test-runtime-only'; ALTER ROLE agent_auth LOGIN PASSWORD 'test-auth-only'");
  }

  const pool = (role, password) => {
    const u = new URL(url); u.username = role; u.password = password;
    return new pg.Pool({ connectionString: u.href, max: 4 });
  };
  const runtimePool = pool('agent_runtime','test-runtime-only'), authPool = pool('agent_auth','test-auth-only');
  const admin = { query: (...args) => adminPool.query(...args), exec: sql => adminPool.query(sql) };
  const writer = { async transaction(work) {
    const c = await adminPool.connect();
    try { await c.query('BEGIN'); await c.query('SET LOCAL ROLE agent_writer');
      const result=await work(c); await c.query('COMMIT'); return result;
    } catch(e) { await c.query('ROLLBACK'); throw e; } finally { c.release(); }
  } };
  return { admin, runtime: new PostgresTransactions(runtimePool), auth: new PostgresTransactions(authPool,'agent_auth'),
    writer, native:true, close: async () => { await runtimePool.end(); await authPool.end(); await adminPool.end(); } };
}

export function asSession(database, token, work) {
  return database.transaction(async tx => {
    await tx.query("SELECT set_config('agent.session_token',$1,true)", [token]);
    return work(tx);
  });
}
