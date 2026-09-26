import { AuthError } from './auth.mjs';

export function createAuthHandler(service) {
  return async (req, res) => {
    res.setHeader('Content-Type', 'application/json');
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    try {
      if (req.method !== 'POST' || !['/v1/auth/exchange','/v1/auth/logout'].includes(req.url))
        throw new AuthError(404, 'not_found');
      // Auth endpoints do not accept request bodies; identity comes only from the
      // Authorization bearer token. Reverse proxy rate limits are still required.
      let size = 0;
      for await (const chunk of req) {
        size += chunk.length;
        if (size > 0) throw new AuthError(400, 'body_not_allowed');
      }
      const result = req.url === '/v1/auth/exchange'
        ? await service.exchange(req.headers.authorization)
        : await service.logout(req.headers.authorization);
      res.statusCode = 200;
      res.end(JSON.stringify({ result }));
    } catch (error) {
      const safe = error instanceof AuthError ? error : new AuthError(503, 'unavailable');
      res.statusCode = safe.status;
      res.end(JSON.stringify({ error: safe.code }));
    }
  };
}
