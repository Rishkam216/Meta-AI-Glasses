import { APIError } from './memory.mjs';

export function createMemoryHandler(backend) {
  return async (req, res) => {
    res.setHeader('Content-Type', 'application/json');
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    try {
      const canonicalEndpoint = req.url === '/v1/memory/canonical';
      if (req.method !== 'POST' || (!canonicalEndpoint && req.url !== '/v1/memory'))
        throw new APIError(404, 'not_found');
      if (req.headers['content-type']?.split(';')[0] !== 'application/json') throw new APIError(415, 'json_required');
      // A reverse proxy must also impose body/header/time/rate limits. No CORS,
      // cookies or query-string credentials. The legacy endpoint keeps its
      // original small bound; the canonical v3 endpoint permits an 8 MiB
      // snapshot plus bounded wrapper overhead.
      const maximumBytes = canonicalEndpoint ? 9 * 1024 * 1024 : 40000;
      let size = 0; const chunks = [];
      for await (const chunk of req) {
        size += chunk.length;
        if (size > maximumBytes) throw new APIError(413, 'request_too_large');
        chunks.push(chunk);
      }
      let request;
      try { request = JSON.parse(Buffer.concat(chunks).toString('utf8')); }
      catch { throw new APIError(400, 'invalid_json'); }
      if (canonicalEndpoint && !['identity','canonical_load','canonical_commit'].includes(request?.operation))
        throw new APIError(400, 'unknown_operation');
      const result = await backend.execute(req.headers.authorization, request);
      res.statusCode = 200;
      res.end(JSON.stringify({ result }));
    } catch (error) {
      const safe = error instanceof APIError ? error : new APIError(503, 'unavailable');
      res.statusCode = safe.status;
      res.end(JSON.stringify({ error: safe.code }));
    }
  };
}
