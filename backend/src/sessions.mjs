import { randomBytes, createHash } from 'node:crypto';

// SERVER-ONLY: call after an identity provider has authenticated the user and
// checked tenant/account membership. Never expose issue() as a public route.
// The request-serving process should not possess this database credential.
export class SessionIssuer {
  #database;
  constructor(authDatabase) { this.#database = authDatabase; }
  async issue(verifiedIdentity, lifetimeSeconds = 3600) {
    if (!Number.isInteger(lifetimeSeconds) || lifetimeSeconds < 1 || lifetimeSeconds > 86400)
      throw new Error('invalid_session_lifetime');
    const token = randomBytes(32).toString('base64url');
    const digest = createHash('sha256').update(token).digest();
    const expires = new Date(Date.now() + lifetimeSeconds * 1000);
    await this.#database.transaction(tx => tx.query(
      'SELECT agent_private.issue_session($1::uuid,$2::uuid,$3::uuid,$4::bytea,$5::timestamptz)',
      [verifiedIdentity.tenantID, verifiedIdentity.userID, verifiedIdentity.accountID ?? null, digest, expires]));
    return { token, expiresAt: expires.toISOString() };
  }
  async revoke(token) {
    const digest = createHash('sha256').update(token).digest();
    await this.#database.transaction(tx => tx.query('SELECT agent_private.revoke_session($1::bytea)', [digest]));
  }
}
