import { randomUUID } from 'node:crypto';

export class APIError extends Error {
  constructor(status, code) { super(code); this.status = status; this.code = code; }
}
function requireValid(value) { if (!value) throw new APIError(400, 'invalid_request'); }
function shape(value, allowed, required = allowed) {
  requireValid(value !== null && typeof value === 'object' && !Array.isArray(value));
  requireValid(Object.keys(value).every(k => allowed.includes(k)) && required.every(k => Object.hasOwn(value,k)));
}
function uuid(value) {
  requireValid(typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value));
  return value;
}
function scope(value) {
  shape(value, ['kind','referenceID'], ['kind']);
  requireValid(['user','project','workspace'].includes(value.kind));
  if (value.kind === 'user') {
    requireValid(value.referenceID === undefined || value.referenceID === null);
    return ['user', ''];
  }
  requireValid(typeof value.referenceID === 'string' && value.referenceID.trim().length > 0 &&
    Buffer.byteLength(value.referenceID) <= 256);
  return [value.kind, value.referenceID];
}
function limit(value = 50) { requireValid(Number.isInteger(value) && value >= 1 && value <= 100); return value; }

// No tenant/user/account arguments. Identity always comes from a valid server
// session. This storage API is distinct from Swift MemoryService until a full
// canonical ledger adapter (lineage, supersession, provider queue) is wired.
export class MemoryBackend {
  #database;
  constructor(database) { this.#database = database; }
  async execute(authorization, request) {
    const match = typeof authorization === 'string' && /^Bearer ([A-Za-z0-9_-]{43})$/.exec(authorization);
    if (!match) throw new APIError(401, 'unauthenticated');
    shape(request, ['operation','input'], ['operation']);
    const input = request.input ?? {};
    let sql, params;
    switch (request.operation) {
      case 'identity':
        shape(input, []); sql = 'SELECT agent_api.identity() AS value'; params = []; break;
      case 'remember': {
        shape(input, ['id','scope','content','provenance'], ['scope','content']);
        const [kind, ref] = scope(input.scope);
        const body = JSON.stringify(input.content), sources = JSON.stringify(input.provenance ?? []);
        requireValid(body !== undefined && Buffer.byteLength(body) <= 24000 &&
          Array.isArray(input.provenance ?? []) && Buffer.byteLength(sources) <= 6000);
        sql = 'SELECT agent_api.remember($1::uuid,$2,$3,$4::jsonb,$5::jsonb) AS value';
        params = [input.id === undefined ? randomUUID() : uuid(input.id), kind, ref, body, sources]; break;
      }
      case 'get': case 'forget':
        shape(input, ['id']);
        sql = request.operation === 'get' ? 'SELECT agent_api.read_memory($1::uuid) AS value'
          : 'SELECT agent_api.forget($1::uuid) AS value';
        params = [uuid(input.id)]; break;
      case 'search': {
        shape(input, ['scope','query','limit'], ['scope','query']);
        const [kind, ref] = scope(input.scope);
        requireValid(typeof input.query === 'string' && input.query.trim().length > 0 && Buffer.byteLength(input.query) <= 1024);
        sql = 'SELECT agent_api.search_memories($1,$2,$3,$4::integer) AS value';
        params = [kind, ref, input.query, limit(input.limit)]; break;
      }
      case 'export':
        shape(input, ['afterID','limit'], []);
        sql = 'SELECT agent_api.export_page($1::uuid,$2::integer) AS value';
        params = [input.afterID == null ? null : uuid(input.afterID), limit(input.limit)]; break;
      default: throw new APIError(400, 'unknown_operation');
    }
    try {
      return await this.#database.transaction(async tx => {
        // SET LOCAL via parameter binding disappears on BOTH commit and rollback.
        await tx.query("SELECT set_config('agent.session_token',$1,true)", [match[1]]);
        await tx.query('SELECT agent_private.current_principal()');
        const result = await tx.query(sql, params);
        return result.rows[0].value;
      });
    } catch (error) {
      if (error.code === '28000') throw new APIError(401, 'unauthenticated');
      if (error.code === '23505') throw new APIError(409, 'memory_conflict');
      if (['22023','22P02','23514','23502'].includes(error.code)) throw new APIError(400, 'invalid_request');
      if (error.code === '42501') throw new APIError(403, 'forbidden');
      // Never surface SQL, bind parameters, provider responses or memory bodies.
      throw new APIError(503, 'storage_unavailable');
    }
  }
}
