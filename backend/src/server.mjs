import { createServer } from 'node:http';
import { runtimeDatabase } from './database.mjs';
import { MemoryBackend } from './memory.mjs';
import { RealtimeCredentialBroker } from './realtime.mjs';
import { createMemoryHandler } from './http.mjs';

async function main() {
  if (!process.env.AGENT_DATABASE_URL) throw new Error('database_configuration_required');
  const { database, close } = runtimeDatabase(process.env.AGENT_DATABASE_URL);
  try { await database.transaction(tx => tx.query('SELECT 1')); }
  catch { await close(); throw new Error('database_startup_failed'); }

  const hasRealtimeKey = Boolean(process.env.OPENAI_API_KEY);
  const hasSafetySecret = Boolean(process.env.AGENT_REALTIME_SAFETY_SECRET);
  if (hasRealtimeKey !== hasSafetySecret) {
    await close();
    throw new Error('realtime_configuration_incomplete');
  }
  const realtimeCredentials = hasRealtimeKey ? new RealtimeCredentialBroker(database, {
    apiKey: process.env.OPENAI_API_KEY,
    safetySecret: process.env.AGENT_REALTIME_SAFETY_SECRET,
    model: process.env.OPENAI_REALTIME_MODEL ?? 'gpt-realtime-2.1'
  }) : null;

  const server = createServer({ requestTimeout: 10000, headersTimeout: 5000, maxHeaderSize: 8192 },
    createMemoryHandler(new MemoryBackend(database), realtimeCredentials));
  server.on('error', () => { console.error('agent_server_failed'); void close(); process.exitCode=1; });
  server.listen(8787, '127.0.0.1', () => console.log('Agent API listening on 127.0.0.1:8787'));
  async function stop() { server.close(); server.closeAllConnections(); await close(); }
  process.once('SIGTERM', stop);
  process.once('SIGINT', stop);
}
main().catch(() => { console.error('backend_startup_failed'); process.exitCode=1; });
