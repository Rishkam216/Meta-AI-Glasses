import pg from 'pg';

// Separate pools and credentials for runtime and trusted authentication. No
// production SET ROLE; the actual database login must have the exact role.
export class PostgresTransactions {
  #pool; #role;
  constructor(pool, role = 'agent_runtime') {
    if (!['agent_runtime', 'agent_auth'].includes(role)) throw new Error('invalid_database_role');
    this.#pool = pool;
    this.#role = role;
  }
  async transaction(work) {
    const client = await this.#pool.connect();
    let destroy = false;
    try {
      await client.query('BEGIN');
      await client.query("SET LOCAL statement_timeout = '5s'");
      await client.query("SET LOCAL lock_timeout = '1s'");
      await client.query("SET LOCAL idle_in_transaction_session_timeout = '5s'");
      const { rows } = await client.query(`SELECT current_user AS role, session_user AS login,
        rolsuper, rolbypassrls, rolcreaterole, rolcreatedb, rolreplication,
        pg_has_role(current_user,'agent_owner','MEMBER') AS owner_member,
        pg_has_role(current_user,'agent_writer','MEMBER') AS writer_member,
        pg_has_role(current_user,$1,'MEMBER') AS other_member
        FROM pg_roles WHERE rolname=current_user`,
        [this.#role === 'agent_runtime' ? 'agent_auth' : 'agent_runtime']);
      const r = rows[0];
      if (!r || r.role !== this.#role || r.login !== this.#role || r.rolsuper || r.rolbypassrls ||
          r.rolcreaterole || r.rolcreatedb || r.rolreplication || r.owner_member || r.writer_member || r.other_member) {
        throw new Error('unsafe_database_role');
      }
      const result = await work(client);
      await client.query('COMMIT');
      return result;
    } catch (error) {
      try { await client.query('ROLLBACK'); } catch { destroy = true; }
      throw error;
    } finally { client.release(destroy); }
  }
}

export function runtimeDatabase(connectionString) {
  const url = new URL(connectionString);
  if (!['postgres:', 'postgresql:'].includes(url.protocol) || url.search || url.hash)
    throw new Error('invalid_database_url');
  const local = ['localhost','127.0.0.1','[::1]'].includes(url.hostname);
  // Query-string overrides are refused. Non-loopback databases always require
  // TLS with certificate verification. Use a supplied Pool for a custom CA.
  const pool = new pg.Pool({ connectionString, max: 8, connectionTimeoutMillis: 5000,
    idleTimeoutMillis: 10000, application_name: 'agent-memory-runtime',
    ssl: local ? false : { rejectUnauthorized: true } });
  pool.on('error', () => console.error('database_idle_connection_failed'));
  return { database: new PostgresTransactions(pool), close: () => pool.end() };
}
