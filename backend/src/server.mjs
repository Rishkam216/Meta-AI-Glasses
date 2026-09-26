import { createServer } from 'node:http';
import { runtimeDatabase } from './database.mjs';
import { MemoryBackend } from './memory.mjs';
import { createMemoryHandler } from './http.mjs';

async function main() {
  if (!process.env.AGENT_DATABASE_URL) throw new Error('database_configuration_required');
  const { database, close } = runtimeDatabase(process.env.AGENT_DATABASE_URL);
  try { await database.transaction(tx => tx.query('SELECT 1')); }
  catch { await close(); throw new Error('database_startup_failed'); }
  const server = createServer({ requestTimeout: 10000, headersTimeout: 5000, maxHeaderSize: 8192 },
    createMemoryHandler(new MemoryBackend(database)));
  server.on('error', () => { console.error('memory_server_failed'); void close(); process.exitCode=1; });
  server.listen(8787, '127.0.0.1', () => console.log('Memory API listening on 127.0.0.1:8787'));
  async function stop() { server.close(); server.closeAllConnections(); await close(); }
  process.once('SIGTERM', stop);
  process.once('SIGINT', stop);
}
main().catch(() => { console.error('backend_startup_failed'); process.exitCode=1; });
