import { PGlite } from '@electric-sql/pglite';
import pg from 'pg';
import { readFile, readdir } from 'node:fs/promises';
import { randomBytes, createHash } from 'node:crypto';
import { PostgresTransactions } from '../src/database.mjs';

function attachTestIssuance(auth, query) {
  auth.issueInternalForTest = async (identity,digest,expires) => query(
    'SELECT agent_private.issue_session($1::uuid,$2::uuid,$3::uuid,$4::bytea,$5::timestamptz)',
    [identity.tenantID,identity.userID,identity.accountID??null,digest,expires]);
  return auth;
}

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
    const auth=attachTestIssuance(role('agent_auth'),(...args)=>db.query(...args));
    return { admin: db, runtime: role('agent_runtime'), auth,
      writer: role('agent_writer'), native: false, close: () => db.close() };
  }
  const url = new URL(process.env.TEST_POSTGRES_URL);
  if (!['localhost','127.0.0.1','[::1]'].includes(url.hostname) || url.pathname !== '/agent_isolation_test')
    throw new Error('disposable_local_test_database_required');
  const adminPool = new pg.Pool({ connectionString: url.href });

  const installed = await adminPool.query("SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='agent_owner') AS value");
  if (!installed.rows[0].value) {
    for (const migration of migrations) await adminPool.query(migration);
    await adminPool.query("ALTER ROLE agent_runtime LOGIN PASSWORD 'test-runtime-only'; ALTER ROLE agent_auth LOGIN PASSWORD 'test-auth-only'");
  } else {
    const authInstalled = await adminPool.query("SELECT to_regclass('agent_private.external_identities') IS NOT NULL AS value");
    if (!authInstalled.rows[0].value) await adminPool.query(migrations.at(-1));
  }

  const pool = (role, password) => {
    const u = new URL(url); u.username = role; u.password = password;
    return new pg.Pool({ connectionString: u.href, max: 4 });
  };
  const runtimePool = pool('agent_runtime','test-runtime-only'), authPool = pool('agent_auth','test-auth-only');
  const admin = { query: (...args) => adminPool.query(...args), exec: sql => adminPool.query(sql) };
  const auth=attachTestIssuance(new PostgresTransactions(authPool,'agent_auth'),(...args)=>adminPool.query(...args));
  const writer = { async transaction(work) {
    const c = await adminPool.connect();
    try { await c.query('BEGIN'); await c.query('SET LOCAL ROLE agent_writer');
      const result=await work(c); await c.query('COMMIT'); return result;
    } catch(e) { await c.query('ROLLBACK'); throw e; } finally { c.release(); }
  } };
  return { admin, runtime: new PostgresTransactions(runtimePool), auth,
    writer, native:true, close: async () => { await runtimePool.end(); await authPool.end(); await adminPool.end(); } };
}

export async function issueTestSession(db, identity, lifetimeSeconds = 3600) {
  const token = randomBytes(32).toString('base64url');
  const digest = createHash('sha256').update(token).digest();
  const expires = new Date(Date.now() + lifetimeSeconds * 1000);
  await db.auth.issueInternalForTest(identity,digest,expires);
  return { token, expiresAt: expires.toISOString() };
}

export function asSession(database, token, work) {
  return database.transaction(async tx => {
    await tx.query("SELECT set_config('agent.session_token',$1,true)", [token]);
    return work(tx);
  });
}
