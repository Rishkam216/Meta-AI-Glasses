# Memory backend isolation

This is the first working cloud-storage boundary in the repository. It provides
a Node HTTP API backed by PostgreSQL RLS, server-issued opaque sessions and a
principal-scoped retrieval cache. It does not replace the Swift canonical ledger
or enable Supermemory. No cloud service has been provisioned or deployed.

## Run the tests

Requires Node 22+ (validated with Node 24.19.0):

```bash
cd backend
npm ci --ignore-scripts --no-audit --no-fund
npm test
```

The default suite executes the actual SQL migration and API on PostgreSQL 18.3
compiled to WebAssembly through PGlite 0.5.8. It does not mock RLS. PGlite has a
single connection, so three native-only tests are explicitly skipped: login
role escalation, concurrent cache fill/deletion and concurrent session revocation.
The separate native PostgreSQL CI job runs these tests using distinct logins
and connections. Do not report that gate passed until its result is observed.

For native local testing, supply `TEST_POSTGRES_URL` through a private environment
to an administrator of a **new disposable PostgreSQL cluster**, using the database
name `agent_isolation_test` on loopback. `REQUIRE_NATIVE_POSTGRES=1 npm test` then applies all numbered migrations
and configures disposable runtime/authentication logins. The native CI job sets
`REQUIRE_NATIVE_POSTGRES=1`, so missing database configuration is a hard failure
instead of a fallback to the embedded engine. The fixture refuses other
hosts/database names and fails if its roles already exist. Never point it at a
shared or production database. Roles are cluster-wide, not database-local.

## Identity and database authority

The trusted authentication process uses `SessionIssuer` with an `agent_auth`
database login **after** verifying identity and tenant/account membership with
the selected identity provider. That external login integration is not included.
There is no public session-issuance endpoint and no development login bypass.

Each session is 32 random bytes, encoded as a 43-character base64url bearer token.
Only its SHA-256 digest, bound principal, expiry and revocation are persisted.
Expiry is at most 24 hours. Reissuing a session for the same tenant/user/account
resolves the same principal, including a distinct, unambiguous null account.

The request process possesses only an `agent_runtime` database login. It cannot
read session/principal tables, issue sessions, modify the schema, truncate data
or write memory/cache tables directly. Transactions verify that the actual login
has no superuser, BYPASSRLS, role-creation, replication, database-creation or
owner/writer/auth-role membership privileges. `SET ROLE` is not used in production.

Requests accept semantic operation arguments, never authoritative ownership IDs.
The server binds the bearer with transaction-local `set_config`; the database
derives the principal from the private session table. A caller changing an
`agent.user_id` or `agent.tenant_id` setting has no effect. Unknown/revoked/expired
sessions fail before any cache read. Commit and rollback both clear local state.

The four data tables use ENABLE + FORCE RLS, with both USING and WITH CHECK on
the complete principal. Table ownership belongs to a separate NOLOGIN role.
Mutation functions belong to another NOLOGIN, NOBYPASSRLS role and remain subject
to RLS. Every security-definer function uses a fixed search path and qualified
table names; default PUBLIC execution is revoked. Canonical identifiers and
uniqueness constraints are principal-scoped, avoiding foreign-ID collision leaks.
An update trigger prohibits in-place memory edits and ownership transfer.

Database administrators and the trusted authentication issuer remain authorities.
These controls do not defend against an administrator granting new privileges,
an issuer minting a victim session, or an attacker stealing a valid bearer token.

## Working operations

`POST /v1/memory`, `Content-Type: application/json`, `Authorization: Bearer …`:

| operation | input | result |
| --- | --- | --- |
| `identity` | empty | authenticated tenant/user/account |
| `remember` | optional UUID `id`, `scope`, JSON `content`, optional `provenance` array | immutable memory UUID |
| `get` | UUID `id` | owned record or null |
| `search` | `scope`, `query`, optional `limit` 1–100 | owned, scoped lexical matches |
| `forget` | UUID `id` | null; exact principal-scoped deletion and tombstone |
| `export` | optional UUID `afterID`, optional `limit` 1–100 | ordered page of records and tombstones |

Example request body (the session header supplies ownership):

```json
{"operation":"remember","input":{"scope":{"kind":"project","referenceID":"project-one"},"content":{"fact":"The build command is swift test"},"provenance":[{"type":"user_entry","reference":"turn-123"}]}}
```

Scopes are private user, project or workspace partitions **inside a principal**;
a matching workspace name does not share records with another user. Requests
reject unknown keys, invalid IDs/scopes, overlarge content and excessive limits.
HTTP requests are capped at 40 KB and responses use `Cache-Control: no-store`.
Errors expose fixed codes, never raw SQL/parameters, bearer tokens or memory text.

Search is literal, case-insensitive substring retrieval, **not semantic/vector
retrieval**. SQL parameters are bound. Cache keys include principal plus a digest
of scope kind, scope reference, exact query and limit; entries include the ledger
revision, expire after 30 seconds and are capped at 128 per principal. Only UUIDs
are cached. Hits are re-resolved under RLS, the requested scope, the lexical
query and the requested result limit. Corrupted candidates cannot introduce an
unrelated same-user memory or exceed the caller's bound.

Writes/deletes and cache population take the same principal-scoped transaction
advisory lock. Triggers increment the revision and invalidate that principal's
cache in the write transaction. A tombstone prevents reinsertion of a deleted ID;
forgetting an unknown ID has the same response as forgetting an existing one.
Session rows are locked FOR SHARE during an operation, so a committed revocation
prevents later operations while allowing the preceding transaction to finish.

The export is a bounded storage-page format, not the Swift `PortableMemoryExport`
v3 or a point-in-time disaster-recovery snapshot. Do not import it as such.

## Local server / deployment gate

For a dedicated database, an administrator applies each numbered SQL migration
in order, with `psql -v ON_ERROR_STOP=1`. Apply `001_isolation.sql` once to a fresh
database, then `002_cache_revalidation.sql`. Existing installations apply only
`002`; it replaces the search function while preserving its writer ownership and
execution grants. The migration creates non-login roles; provision
private passwords and enable LOGIN only for `agent_runtime` and, in a separate
trusted authentication process, `agent_auth`. Never grant runtime membership in
the other roles. Do not put database credentials in Git or request payloads.

Supply `AGENT_DATABASE_URL` privately and run:

```bash
node src/server.mjs
```

The process checks its database role before listening on `127.0.0.1:8787`.
Non-loopback database URLs require verified TLS; connection-string query
overrides are refused. For custom certificate authorities, construct a `pg.Pool`
with verified TLS and pass it to `PostgresTransactions` instead. Public deployment
still requires a TLS ingress, rate limits, identity-provider integration and
operational key/session rotation. Ensure database/proxy tracing does not log
authorization headers or bind parameters (`log_parameter_max_length=0` and
`log_parameter_max_length_on_error=0` on PostgreSQL), and do not enable raw request
or SQL tracing. No raw request logging is added here.

## Integration boundary and remaining work

This API intentionally remains separate from the native application until a
remote `MemoryServiceLedger` adapter preserves the full existing Swift contract:
source/derived lineage, supersession, provider-ID mappings, atomic provider work,
revision receipts and portable v3 exports. This module must not silently replace
that ledger. Its `forget` deletes one stored record; the Swift service must still
calculate its full lineage/supersession deletion set before a future cloud adapter
can claim equivalent semantics. No provider deletion propagation is implemented.

Native PostgreSQL login/concurrency validation, real identity-provider enrollment,
cloud deployment, full canonical-ledger integration, semantic provider isolation,
shared-workspace ACLs, jobs/artifact isolation and encrypted backup lifecycle
remain gates. The broad end-to-end isolation checklist remains open.

Primary references reviewed 2026-09-24:
- https://www.postgresql.org/docs/18/ddl-rowsecurity.html
- https://www.postgresql.org/docs/18/sql-createfunction.html
- https://www.postgresql.org/docs/18/explicit-locking.html
- https://node-postgres.com/features/transactions
- https://node-postgres.com/features/ssl
- https://pglite.dev/docs/api

## 2026-09-26 validation follow-up

The local suite passes 31 tests, with zero failures and three native-only tests
skipped. It includes cache relevance/limit revalidation, auxiliary-table RLS,
function ownership/grant preservation and fail-closed native configuration.
GitHub Actions retries for macOS, portable core and the backend were accepted
but failed before any steps ran. The API connection cannot retrieve check-run
annotations (403), so billing is suspected from prior history, not confirmed by
this retry. No native PostgreSQL or macOS pass is claimed. No Supermemory API
request was made in this follow-up.
