import { IdentityProviderError } from './identity.mjs';

export class AuthError extends Error {
  constructor(status, code) { super(code); this.status = status; this.code = code; }
}

function bearer(header, kind) {
  const match = typeof header === 'string' && /^Bearer ([^\s]+)$/.exec(header);
  if (!match) throw new AuthError(401, 'unauthenticated');
  const token = match[1];
  if (kind === 'agent' && !/^[A-Za-z0-9_-]{43}$/.test(token)) throw new AuthError(401, 'unauthenticated');
  if (kind === 'external' && (token.length < 16 || token.length > 16384)) throw new AuthError(401, 'unauthenticated');
  return token;
}

export class AuthService {
  #provider; #issuer;
  constructor(identityProvider, sessionIssuer) {
    if (!identityProvider?.verify || !sessionIssuer?.issueExternal || !sessionIssuer?.revoke)
      throw new Error('invalid_auth_service_dependencies');
    this.#provider = identityProvider; this.#issuer = sessionIssuer;
  }

  async exchange(authorization) {
    const externalToken = bearer(authorization, 'external');
    let externalIdentity;
    try { externalIdentity = await this.#provider.verify(externalToken); }
    catch (error) {
      if (error instanceof IdentityProviderError && error.code === 'invalid_external_token')
        throw new AuthError(401, 'unauthenticated');
      if (error instanceof IdentityProviderError) throw new AuthError(503, 'identity_provider_unavailable');
      throw new AuthError(503, 'identity_provider_unavailable');
    }
    try { return await this.#issuer.issueExternal(externalIdentity); }
    catch { throw new AuthError(503, 'session_issuance_unavailable'); }
  }

  async logout(authorization) {
    const token = bearer(authorization, 'agent');
    try { await this.#issuer.revoke(token); }
    catch { throw new AuthError(503, 'session_revocation_unavailable'); }
    return { revoked: true };
  }
}
