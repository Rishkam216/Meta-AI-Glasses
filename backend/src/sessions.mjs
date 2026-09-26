import { randomBytes, createHash } from 'node:crypto';

function validExternal(identity) {
  if (!identity || typeof identity !== 'object') throw new Error('invalid_external_identity');
  for (const key of ['provider','issuer','subject'])
    if (typeof identity[key] !== 'string' || identity[key].length < 1) throw new Error('invalid_external_identity');
  return identity;
}

// SERVER-ONLY: this object belongs in the isolated authentication service. It
// has agent_auth credentials and cannot access memory tables or choose arbitrary
// tenant/user IDs. PostgreSQL maps the verified external identity atomically.
export class SessionIssuer {
  #database;
  constructor(authDatabase) { this.#database = authDatabase; }

  async issueExternal(externalIdentity, lifetimeSeconds = 3600) {
    const identity = validExternal(externalIdentity);
    if (!Number.isInteger(lifetimeSeconds) || lifetimeSeconds < 1 || lifetimeSeconds > 86400)
      throw new Error('invalid_session_lifetime');
    const token = randomBytes(32).toString('base64url');
    const digest = createHash('sha256').update(token).digest();
    const expires = new Date(Date.now() + lifetimeSeconds * 1000);
    const result = await this.#database.transaction(tx => tx.query(
      'SELECT agent_private.issue_external_session($1,$2,$3,$4::bytea,$5::timestamptz) AS identity',
      [identity.provider, identity.issuer, identity.subject, digest, expires]));
    const internal = result.rows?.[0]?.identity;
    if (!internal?.tenantID || !internal?.userID) throw new Error('identity_mapping_failed');
    return { token, expiresAt: expires.toISOString(), identity: internal };
  }

  async revoke(token) {
    if (typeof token !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(token)) throw new Error('invalid_session_token');
    const digest = createHash('sha256').update(token).digest();
    await this.#database.transaction(tx => tx.query('SELECT agent_private.revoke_session($1::bytea)', [digest]));
  }
}
