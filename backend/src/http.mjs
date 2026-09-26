import { APIError } from './memory.mjs';

export function createMemoryHandler(backend) {
  return async (req, res) => {
    res.setHeader('Content-Type', 'application/json');
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    try {
      if (req.method !== 'POST' || req.url !== '/v1/memory') throw new APIError(404, 'not_found');
      if (req.headers['content-type']?.split(';')[0] !== 'application/json') throw new APIError(415, 'json_required');
      // A reverse proxy must also impose body/header/time/rate limits. No CORS
      // allowance, cookies or query-string credentials on this transport. The
      // canonical v3 snapshot is capped at 8 MiB by both JS and PostgreSQL;
      // wrapper JSON receives a small bounded allowance here.
      let size = 0; const chunks = [];
      for await (const chunk of req) {
        size += chunk.length;
        if (size > 9 * 1024 * 1024) throw new APIError(413, 'request_too_large');
        chunks.push(chunk);
      }
      let request;
      try { request = JSON.parse(Buffer.concat(chunks).toString('utf8')); }
      catch { throw new APIError(400, 'invalid_json'); }
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
