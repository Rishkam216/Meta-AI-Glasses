import { createServer } from 'node:http';
import { authDatabase } from './database.mjs';
import { SupabaseIdentityProvider } from './identity.mjs';
import { SessionIssuer } from './sessions.mjs';
import { AuthService } from './auth.mjs';
import { createAuthHandler } from './auth-http.mjs';

async function main() {
  const databaseURL = process.env.AGENT_AUTH_DATABASE_URL;
  const projectURL = process.env.SUPABASE_PROJECT_URL;
  const publishableKey = process.env.SUPABASE_PUBLISHABLE_KEY;
  if (!databaseURL || !projectURL || !publishableKey) throw new Error('auth_configuration_required');

  const { database, close } = authDatabase(databaseURL);
  try { await database.transaction(tx => tx.query('SELECT 1')); }
  catch { await close(); throw new Error('auth_database_startup_failed'); }

  const provider = new SupabaseIdentityProvider({ projectURL, publishableKey });
  const service = new AuthService(provider, new SessionIssuer(database));
  const server = createServer({ requestTimeout: 10000, headersTimeout: 5000, maxHeaderSize: 8192 }, createAuthHandler(service));
  server.on('error', () => { console.error('auth_server_failed'); void close(); process.exitCode = 1; });
  server.listen(8788, '127.0.0.1', () => console.log('Auth API listening on 127.0.0.1:8788'));

  async function stop() { server.close(); server.closeAllConnections(); await close(); }
  process.once('SIGTERM', stop);
  process.once('SIGINT', stop);
}

main().catch(() => { console.error('auth_startup_failed'); process.exitCode = 1; });
