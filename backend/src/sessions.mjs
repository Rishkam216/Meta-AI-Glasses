import { randomBytes, createHash } from 'node:crypto';

function validExternal(identity) {
  if (!identity || typeof identity !== 'object') throw new Error('invalid_external_identity');
  for (const key of ['provider','issuer','subject'])
    if (typeof identity[key] !== 'string' || identity[key].length < 1) throw new Error('invalid_external_identity');
  return identity;
}
function lifetime(value) {
  if (!Number.isInteger(value) || value < 1 || value > 86400) throw new Error('invalid_session_lifetime');
  return value;
}
function freshSession(lifetimeSeconds) {
  const token = randomBytes(32).toString('base64url');
  return { token, digest:createHash('sha256').update(token).digest(), expires:new Date(Date.now()+lifetimeSeconds*1000) };
}

// SERVER-ONLY: this object belongs in the isolated authentication service. It
// has agent_auth credentials and cannot access memory tables or choose arbitrary
// tenant/user IDs. PostgreSQL maps the verified external identity atomically.
export class SessionIssuer {
  #database;
  constructor(authDatabase) { this.#database = authDatabase; }

  async issueExternal(externalIdentity, lifetimeSeconds = 3600) {
    const identity = validExternal(externalIdentity); lifetime(lifetimeSeconds);
    const session = freshSession(lifetimeSeconds);
    const result = await this.#database.transaction(tx => tx.query(
      'SELECT agent_private.issue_external_session($1,$2,$3,$4::bytea,$5::timestamptz) AS identity',
      [identity.provider, identity.issuer, identity.subject, session.digest, session.expires]));
    const internal = result.rows?.[0]?.identity;
    if (!internal?.tenantID || !internal?.userID) throw new Error('identity_mapping_failed');
    return { token:session.token, expiresAt:session.expires.toISOString(), identity:internal };
  }

  // Exists solely so the long-standing RLS test matrix can mint synthetic
  // principals. Real authDatabase() objects do not implement this capability.
  async issue(verifiedIdentity, lifetimeSeconds = 3600) {
    if (typeof this.#database?.issueInternalForTest !== 'function') throw new Error('trusted_internal_issuance_disabled');
    lifetime(lifetimeSeconds); const session=freshSession(lifetimeSeconds);
    await this.#database.issueInternalForTest(verifiedIdentity,session.digest,session.expires);
    return { token:session.token, expiresAt:session.expires.toISOString() };
  }

  async revoke(token) {
    if (typeof token !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(token)) throw new Error('invalid_session_token');
    const digest = createHash('sha256').update(token).digest();
    await this.#database.transaction(tx => tx.query('SELECT agent_private.revoke_session($1::bytea)', [digest]));
  }
}
