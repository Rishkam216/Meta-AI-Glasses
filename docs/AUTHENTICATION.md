# Authentication Foundation

Status: **Foundation implemented; live Supabase project configuration and end-user login UI remain pending.**

Date: 2026-09-26

## Goal

Use Supabase Auth as the first external login provider without making Supabase identity, JWTs, or database IDs the canonical identity of the agent platform.

The intended boundary is:

```text
Supabase Auth
    ↓ verifies user
External identity
(provider + issuer + subject)
    ↓
Isolated Agent Auth Service
    ↓
Our stable internal tenant_id / user_id
    ↓
Our opaque short-lived agent session
    ↓
Memory / Context / Jobs / Devices / Approvals / Agent
```

Supabase is replaceable. Downstream systems must not depend on Supabase-specific user IDs or tokens.

## Implemented backend path

### External identity verification

`SupabaseIdentityProvider` validates a supplied Supabase access token against the project's Auth user endpoint.

The adapter:

- uses the configured Supabase project HTTPS origin;
- sends the configured Supabase publishable key;
- sends the user access token only in the Authorization header;
- refuses redirects;
- has bounded timeouts and response size;
- requires a JSON response with a UUID user subject;
- returns only a provider-neutral tuple:

```text
provider = supabase
issuer   = https://<project>/auth/v1
subject  = <Supabase user UUID>
```

The external access token is not written to the canonical memory database and is not used by Memory/Context/RLS.

### Internal identity mapping

Migration `004_external_auth.sql` adds the private mapping:

```text
(provider, issuer, subject) -> principal_id
```

A first login atomically creates our own internal principal with our own generated `tenant_id` and `user_id`. Repeated or concurrent login for the same external subject resolves to the same principal.

The mapping table is private. `agent_runtime`, `agent_writer`, and `agent_auth` cannot directly read it.

### Session issuance

After successful provider verification, the isolated auth service asks PostgreSQL to issue an opaque agent session for the mapped principal.

Properties:

- random 32-byte session secret;
- only SHA-256 digest stored in PostgreSQL;
- default lifetime: 1 hour;
- database-enforced maximum lifetime: 24 hours;
- revocable;
- existing Memory/RLS path receives only our opaque bearer token;
- session response includes our internal `tenantID`, `userID`, and optional `accountID`.

Production `agent_auth` can no longer call the arbitrary-principal `issue_session(...)` function. It can only issue a session through a verified external identity mapping. Synthetic arbitrary-principal issuance remains available only to controlled database-owner test fixtures.

## Process and database separation

Authentication runs as a separate service/process from the memory runtime.

Auth service database credential:

```text
agent_auth
```

Memory service database credential:

```text
agent_runtime
```

The auth service cannot read user memory tables. The memory runtime cannot issue login sessions or read external identity mappings.

Required auth-service environment variables:

```text
AGENT_AUTH_DATABASE_URL
SUPABASE_PROJECT_URL
SUPABASE_PUBLISHABLE_KEY
```

No Supabase secret/service-role key is required for the current user-token verification flow and no credential is committed to the repository.

## HTTP contract

### Exchange

```text
POST /v1/auth/exchange
Authorization: Bearer <external Supabase access token>
```

No request body is accepted.

Success returns:

```json
{
  "result": {
    "token": "<opaque agent token>",
    "expiresAt": "<ISO-8601 timestamp>",
    "identity": {
      "tenantID": "<our UUID>",
      "userID": "<our UUID>",
      "accountID": null
    }
  }
}
```

### Logout

```text
POST /v1/auth/logout
Authorization: Bearer <opaque agent token>
```

The server revokes the session digest. The Mac client clears its local credential after successful revocation (and also treats an already-unauthenticated response as locally log-outable).

## macOS credential boundary

`AgentSessionCredential` is provider-neutral and contains only:

- our opaque agent token;
- its expiry;
- our internal `TenantContext`.

`KeychainAgentSessionStore` stores this credential in macOS Keychain using `AfterFirstUnlockThisDeviceOnly` accessibility.

The Supabase external access token is deliberately not stored by this component. It exists only long enough to call the exchange endpoint.

`AuthExchangeClient`:

- permits HTTPS endpoints, plus loopback HTTP for local development;
- requires the exact `/v1/auth/exchange` path;
- uses an ephemeral URL session;
- disables cookies/cache;
- refuses redirects in production transport;
- bounds response size;
- validates our opaque token and internal principal before saving it;
- persists the resulting agent credential through the injected credential store.

The existing memory HTTP transport can use the Keychain store's opaque bearer token rather than a Supabase token.

## Isolation and validation coverage

Tests cover:

- same external identity -> stable internal principal across fresh sessions;
- different external subjects -> different internal users/tenants;
- concurrent first login -> one internal principal;
- `agent_auth` cannot mint arbitrary principals;
- `agent_auth` cannot read private identity/principal/session tables;
- opaque session works with the existing memory identity/RLS boundary;
- logout revokes the opaque session;
- malformed/rejected/oversized provider responses fail closed;
- auth HTTP boundary accepts no body and returns sanitized errors;
- portable agent-session token/expiry validation;
- native macOS exchange persistence and logout behavior without external network access;
- external access token is not the token persisted as the agent credential.

No test requires a live Supabase account or incurs Supabase/API usage.

## Explicitly not complete yet

This milestone does **not** claim the following:

- a configured production Supabase project;
- a live end-to-end Supabase login;
- email/password signup UI;
- Google Sign-In UI;
- Apple Sign-In;
- password reset/account recovery UX;
- MFA/passkeys;
- production reverse-proxy TLS/rate limiting;
- refresh-token lifecycle for the external provider;
- account/organization/team membership;
- linking two external identities/providers to one existing internal user;
- multi-device session-management UI;
- cloud deployment of the auth service/database.

Those should be added only when the product surface needs them.

## Important future account-linking rule

Do not automatically merge identities merely because two providers report the same email address.

A future flow such as Google + Apple + email/password linking must require an authenticated, explicit account-link operation and must preserve one canonical internal user. Email equality alone is not sufficient authorization to merge principals.

## Next milestone after this foundation

Once this branch is validated and merged:

```text
Authentication backbone
        ↓
Memory retrieval into Context Compiler
        ↓
Realtime AI session
        ↓
Agent Orchestrator
        ↓
Mac executor / real computer control
```

Polished login/signup UI can be developed alongside the first real client-facing application surface rather than blocking the agent core now.
