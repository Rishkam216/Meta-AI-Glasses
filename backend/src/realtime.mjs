import { createHmac } from 'node:crypto';
import { APIError } from './memory.mjs';

const SESSION_PATTERN = /^Bearer ([A-Za-z0-9_-]{43})$/;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MODEL_PATTERN = /^[A-Za-z0-9._-]{1,128}$/;
const MAX_PROVIDER_RESPONSE_BYTES = 64 * 1024;
const MAX_CREDENTIAL_BYTES = 8 * 1024;

function validSecret(value) {
  return typeof value === 'string' && value.length >= 32 && Buffer.byteLength(value) <= 4096;
}

function validAPIKey(value) {
  return typeof value === 'string' && value.length >= 8 && Buffer.byteLength(value) <= 8192 &&
    value === value.trim() && !/[\u0000-\u0020\u007f]/.test(value);
}

function requireIdentity(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new APIError(503, 'identity_unavailable');
  if (!UUID_PATTERN.test(value.tenantID ?? '') || !UUID_PATTERN.test(value.userID ?? ''))
    throw new APIError(503, 'identity_unavailable');
  if (value.accountID !== null && value.accountID !== undefined && !UUID_PATTERN.test(value.accountID))
    throw new APIError(503, 'identity_unavailable');
  return value;
}

export class RealtimeCredentialBroker {
  #database;
  #apiKey;
  #safetySecret;
  #model;
  #fetch;
  #endpoint;

  constructor(database, {
    apiKey,
    safetySecret,
    model = 'gpt-realtime-2.1',
    fetchImpl = globalThis.fetch,
    endpoint = 'https://api.openai.com/v1/realtime/client_secrets'
  }) {
    if (!validAPIKey(apiKey)) throw new Error('realtime_api_key_configuration_required');
    if (!validSecret(safetySecret)) throw new Error('realtime_safety_secret_configuration_required');
    if (!MODEL_PATTERN.test(model)) throw new Error('realtime_model_configuration_invalid');
    if (typeof fetchImpl !== 'function') throw new Error('realtime_fetch_configuration_required');
    const url = new URL(endpoint);
    if (url.protocol !== 'https:' || url.hostname !== 'api.openai.com' ||
        url.pathname !== '/v1/realtime/client_secrets' || url.username || url.password ||
        url.search || url.hash) throw new Error('realtime_endpoint_configuration_invalid');
    this.#database = database;
    this.#apiKey = apiKey;
    this.#safetySecret = safetySecret;
    this.#model = model;
    this.#fetch = fetchImpl;
    this.#endpoint = url.href;
  }

  async mint(authorization) {
    const match = typeof authorization === 'string' && SESSION_PATTERN.exec(authorization);
    if (!match) throw new APIError(401, 'unauthenticated');

    let identity;
    try {
      identity = await this.#database.transaction(async tx => {
        await tx.query("SELECT set_config('agent.session_token',$1,true)", [match[1]]);
        const result = await tx.query('SELECT agent_api.identity() AS value');
        return requireIdentity(result.rows[0]?.value);
      });
    } catch (error) {
      if (error instanceof APIError) throw error;
      if (error.code === '28000') throw new APIError(401, 'unauthenticated');
      if (error.code === '42501') throw new APIError(403, 'forbidden');
      throw new APIError(503, 'identity_unavailable');
    }

    const safetyIdentifier = 'agent_' + createHmac('sha256', this.#safetySecret)
      .update(`${identity.tenantID}:${identity.userID}:${identity.accountID ?? ''}`, 'utf8')
      .digest('base64url');

    let response;
    try {
      response = await this.#fetch(this.#endpoint, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${this.#apiKey}`,
          'Content-Type': 'application/json',
          'OpenAI-Safety-Identifier': safetyIdentifier
        },
        body: JSON.stringify({
          session: {
            type: 'realtime',
            model: this.#model
          }
        }),
        signal: AbortSignal.timeout(8000)
      });
    } catch {
      throw new APIError(503, 'realtime_unavailable');
    }

    if (!response?.ok) throw new APIError(503, 'realtime_unavailable');

    let text;
    try {
      text = await response.text();
    } catch {
      throw new APIError(503, 'realtime_unavailable');
    }
    if (Buffer.byteLength(text) > MAX_PROVIDER_RESPONSE_BYTES)
      throw new APIError(503, 'realtime_invalid_response');

    let payload;
    try { payload = JSON.parse(text); }
    catch { throw new APIError(503, 'realtime_invalid_response'); }

    const credential = payload?.value;
    if (typeof credential !== 'string' || credential.length < 8 ||
        Buffer.byteLength(credential) > MAX_CREDENTIAL_BYTES || credential !== credential.trim() ||
        /[\u0000-\u0020\u007f]/.test(credential)) {
      throw new APIError(503, 'realtime_invalid_response');
    }

    const result = { credential, model: this.#model };
    if (Number.isSafeInteger(payload.expires_at) && payload.expires_at > 0)
      result.expiresAt = payload.expires_at;
    return result;
  }
}
