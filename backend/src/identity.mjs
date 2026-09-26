export class IdentityProviderError extends Error {
  constructor(code = 'identity_provider_unavailable') { super(code); this.code = code; }
}

function requiredString(value, maximum) {
  if (typeof value !== 'string' || value.length < 1 || value.length > maximum) throw new Error('invalid_identity_configuration');
  return value;
}

async function readBounded(body, maximumBytes) {
  if (!body) return Buffer.alloc(0);
  const reader = body.getReader(); const chunks = []; let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maximumBytes) throw new IdentityProviderError();
      chunks.push(Buffer.from(value));
    }
    return Buffer.concat(chunks, total);
  } finally { reader.releaseLock(); }
}

// Provider adapter only. Supabase authenticates the user; our backend owns the
// canonical tenant/user identity and the opaque agent session issued afterwards.
export class SupabaseIdentityProvider {
  id = 'supabase';
  #projectURL; #publishableKey; #fetch; #timeoutMs;
  constructor({ projectURL, publishableKey, fetchImpl = globalThis.fetch, timeoutMs = 5000 }) {
    if (typeof fetchImpl !== 'function') throw new Error('identity_fetch_required');
    const url = new URL(requiredString(projectURL, 2048));
    if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash || (url.pathname !== '/' && url.pathname !== ''))
      throw new Error('invalid_supabase_project_url');
    requiredString(publishableKey, 8192);
    if (!Number.isInteger(timeoutMs) || timeoutMs < 250 || timeoutMs > 15000) throw new Error('invalid_identity_timeout');
    this.#projectURL = url; this.#publishableKey = publishableKey; this.#fetch = fetchImpl; this.#timeoutMs = timeoutMs;
  }
  get issuer() { return new URL('/auth/v1', this.#projectURL).href.replace(/\/$/, ''); }

  async verify(accessToken) {
    if (typeof accessToken !== 'string' || accessToken.length < 16 || accessToken.length > 16384 || /\s/.test(accessToken))
      throw new IdentityProviderError('invalid_external_token');
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), this.#timeoutMs);
    try {
      let response;
      try {
        response = await this.#fetch(new URL('/auth/v1/user', this.#projectURL), {
          method: 'GET', redirect: 'error', signal: controller.signal,
          headers: { Accept: 'application/json', apikey: this.#publishableKey, Authorization: `Bearer ${accessToken}` }
        });
      } catch { throw new IdentityProviderError(); }
      if (response.status === 401 || response.status === 403) throw new IdentityProviderError('invalid_external_token');
      if (response.status !== 200) throw new IdentityProviderError();
      const type = response.headers.get('content-type')?.split(';')[0]?.trim();
      if (type !== 'application/json') throw new IdentityProviderError();
      const advertised = Number(response.headers.get('content-length'));
      if (Number.isFinite(advertised) && advertised > 65536) throw new IdentityProviderError();
      let user;
      try { user = JSON.parse((await readBounded(response.body, 65536)).toString('utf8')); }
      catch (error) { if (error instanceof IdentityProviderError) throw error; throw new IdentityProviderError(); }
      const subject = user?.id;
      if (typeof subject !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(subject))
        throw new IdentityProviderError();
      return Object.freeze({ provider: this.id, issuer: this.issuer, subject });
    } finally { clearTimeout(timeout); }
  }
}
