# PostgreSQL Canonical Memory Bridge

Status: **Implemented and merged to `main` via PR #14 on 2026-09-26.**

This document records the completed bridge between the provider-neutral Swift `MemoryService` / `MemoryServiceLedger` contract and PostgreSQL-backed canonical persistence.

## Purpose

The memory provider is not the source of truth. Canonical memory remains provider-independent and controlled by our infrastructure. The bridge must preserve the complete Swift v3 ledger semantics while adding durable authenticated cloud-capable persistence and database-enforced tenant isolation.

## Architecture

```text
MemoryService
    ↓
RemoteMemoryServiceLedger
    ↓
MemoryLedgerState
    ↓ validated PortableMemoryExport v3
CanonicalMemorySnapshotStore
    ↓ compare-and-swap
HTTPMemorySnapshotStore (macOS)
    ↓ authenticated /v1/memory
PostgreSQL
    ↓
agent_canonical.snapshots + FORCE RLS
```

Swift `MemoryLedgerState` remains the semantic authority for:

- stable canonical memory IDs;
- source and derived provenance;
- lineage and supersession;
- deletion families and permanent tombstones;
- provider-ID mappings;
- provider synchronization inventory;
- revision-fenced provider work;
- validation of portable v3 snapshots.

PostgreSQL is responsible for:

- authenticated principal derivation from the server session;
- durable atomic persistence of the full v3 canonical snapshot;
- FORCE RLS isolation;
- compare-and-swap revisions;
- rejection of stale concurrent writes;
- independent rejection of embedded foreign tenant/user/account identities.

The design intentionally avoids independently reimplementing the complete Swift lifecycle state machine in SQL.

## PostgreSQL boundary

Migration `backend/sql/003_canonical_memory_snapshot.sql` adds `agent_canonical.snapshots`.

Each authenticated principal has at most one canonical snapshot row containing:

- a monotonic revision;
- one complete `PortableMemoryExport` v3 JSON document;
- update timestamp.

The table uses both `ENABLE ROW LEVEL SECURITY` and `FORCE ROW LEVEL SECURITY`.

The runtime login receives read access only. Mutation functions execute through the restricted writer role; the request-facing runtime does not own the table and does not receive direct mutation privileges.

`agent_private.canonical_snapshot_identity_valid` independently inspects memories, tombstones, and synchronization entries and requires every embedded `TenantContext` to match the principal derived from the opaque server session. A caller therefore cannot smuggle another user's identity inside an otherwise structurally valid snapshot.

## Optimistic concurrency

`canonical_memory_load` returns:

```json
{"revision": 0, "snapshot": null}
```

for an uninitialized principal, or the current revision and v3 snapshot.

`canonical_memory_commit(expectedRevision, snapshot)` performs a principal-scoped atomic compare-and-swap. A stale revision raises `state_conflict` rather than silently overwriting another writer.

`RemoteMemoryServiceLedger` reloads and retries a bounded number of times after a CAS conflict. Each retry re-applies the requested operation through `MemoryLedgerState` to the newest validated canonical snapshot. This allows multiple authorized clients/devices to converge without last-writer-wins data loss.

## Swift remote ledger

`Sources/AgentCore/RemoteMemoryServiceLedger.swift` implements the complete `MemoryServiceLedger` protocol over a provider-neutral `CanonicalMemorySnapshotStore`.

It supports:

- insert/read/query;
- supersession;
- provider mappings;
- export;
- forget/tombstones;
- provider enrollment;
- canonical remember + desired provider work atomically;
- mark-attempt;
- provider acknowledgement.

Before any remote access it enforces exact `TenantContext` ownership. A malformed, corrupt, or foreign remote snapshot fails closed as `invalidResponse`; it is never "repaired" by overwriting it.

No-op/idempotent retries do not create unnecessary remote revisions.

## macOS transport

`Sources/MacRuntime/HTTPMemorySnapshotStore.swift` provides the native macOS transport.

Security properties:

- ephemeral `URLSession`;
- URL cache disabled;
- cookie storage disabled;
- redirects refused so bearer credentials cannot leak through redirect chains;
- HTTPS required for non-loopback endpoints;
- HTTP permitted only for localhost/127.0.0.1/::1 development;
- URL credentials, query strings, and fragments rejected;
- strict bearer-token shape validation;
- bounded request/resource timeouts;
- bounded response body;
- JSON content type required;
- sanitized error mapping with no SQL, memory body, credentials, or provider response surfaced.

The transport accepts either a static development session token or an async token-provider closure so a future real identity/session layer can rotate credentials without changing the ledger contract.

## Validation

The branch was validated before merge by all repository CI lanes:

- **Backend isolation**: embedded PostgreSQL passed.
- **Backend isolation**: native PostgreSQL 18.3 passed.
- **Portable Core**: Swift AgentCore tests passed.
- **Portable Core**: offline Supermemory canary harness passed.
- **macOS runtime**: AgentCore + MacRuntime compile/tests passed.
- **macOS runtime**: native `.app` bundle build and verification passed.

New tests cover:

- canonical empty load and v3 round-trip;
- same canonical ID across different principals without leakage;
- stale CAS rejection;
- foreign identity rejection in memories, tombstones, and synchronization entries;
- optional-account identity isolation;
- FORCE RLS and table ownership;
- revoked-session rejection;
- restart persistence through a new Swift remote ledger instance;
- deletion/tombstone persistence;
- bounded CAS retry without dropping the requested mutation;
- atomic persistence of canonical memory plus provider synchronization work;
- foreign caller rejection before remote I/O;
- malformed/foreign stored snapshot refusal without overwrite.

## Completed milestone

The following previously-open canonical-ledger requirements are now satisfied at the implementation/validation layer:

- canonical Memory Ledger has durable PostgreSQL-backed persistence;
- canonical memory and provider work are persisted atomically as v3 state;
- provider-ID mappings are durably retained inside the canonical v3 state;
- database-level exact-principal isolation is enforced with FORCE RLS;
- concurrent clients use explicit CAS instead of silent last-writer-wins replacement;
- the native Swift `MemoryServiceLedger` can use this canonical backend through a provider-neutral store interface;
- macOS has a bounded authenticated HTTP adapter for the backend.

## Explicitly not complete

This milestone does **not** claim:

- production cloud PostgreSQL deployment;
- a production external identity provider;
- account signup/login/token refresh UX;
- cross-device gateway/session continuation;
- Supermemory production mutations;
- proof of Supermemory's delayed-processing/deletion lifecycle guarantees;
- Memory-to-Context automatic retrieval/injection;
- realtime model integration;
- end-user conversational Mac control.

The repository's server-issued session mechanism is still the trusted authentication boundary used for the bridge tests. A real identity-provider/session-issuance integration is the next security/infrastructure milestone.

## Next step

Implement the real authentication/session layer without weakening the current rule:

> Tenant/user/account identity is derived from trusted authenticated server state, never from model output or request-supplied identity fields.

After that, wire canonical memory retrieval into the Context Service/Context Compiler and continue toward realtime model → orchestrator → Mac executor integration.
