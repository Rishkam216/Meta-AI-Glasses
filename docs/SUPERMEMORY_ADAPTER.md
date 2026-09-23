# Supermemory adapter checkpoint

The direct Supermemory adapter now supports **explicit diagnostic search only**. It is disabled by default, performs no writes/deletes, and cannot be registered with `MemoryService`: its `idempotentRevisionFencing` capability is false. The complete adapter milestone remains open.

## API evidence and write blocker

Reviewed the official live [OpenAPI specification](https://api.supermemory.ai/openapi.json) and [API changelog](https://supermemory.ai/changelog/api/) on 2026-09-23. The downloaded specification identified version 3.0.0 and SHA-256 `05278ca4fc42dccbfed95eeafca1e1697fd72969ee10f8aa596d75c018171b6f`.

`POST /v3/documents` returns a document ID and processing status. The current changelog says adding an existing custom ID appends content; `PATCH /v3/documents/{id}` replaces and reprocesses it. The reviewed schemas do not document a conditional revision argument, compare-and-set precondition, or persistent deletion fence. This is a missing documented guarantee, not proof about unexposed vendor internals. A queued response is not our synchronization receipt.

A process-local actor/mutex cannot solve the delayed-write race across crashes or multiple workers. Read-before-write and local acknowledgement checks also cannot stop an already accepted vendor job. Do not substitute any of these for the mandatory contract or mark the capability true to bypass the service gate.

Before writes can be implemented/enabled, establish a proven mechanism that controls all writers and the asynchronous vendor processing lifecycle, durably rejects stale revisions, retains deletion fences, and reconciles uncertain outcomes after restart. An enforcing gateway is one possible architecture; an ordinary HTTP proxy is insufficient. Alternatively obtain documented native conditional-write guarantees and validate them. The app's canonical ledger remains authoritative throughout.

## Read contract

`SupermemoryProvider` is bound to one authenticated tenant/user/account. `searchReferences(_:as:)` is the explicit diagnostic entry point, and checks the exact principal before reading credentials or sending a request. Reads require `readsEnabled: true`; this is trusted composition configuration, not persisted consent. The credential closure is evaluated per request and should read a secure store. No credential is built into the package.

Search uses `POST https://api.supermemory.ai/v3/search`. We intentionally use document search, because document IDs map back to canonical records. Generated profiles and inferred memory entries are not canonical facts and are unsupported at this checkpoint.

The request always carries one container tag plus an AND filter for namespace, provider deployment, and an OR of exactly the requested scopes. Conditions are case-sensitive metadata equality. No unscoped fallback, query rewriting, full-document inclusion or summary inclusion is requested. The service's query validation still bounds query bytes, scope count and result count.

The future controlled index writer must use this metadata convention (arbitrary existing Supermemory indexes do not automatically satisfy it):

| Field | Encoding |
| --- | --- |
| `containerTag` / `ag_namespace` | `n` + 32 lowercase tenant UUID hex digits + `_` + 32 user UUID hex digits + `_` + 32 account UUID hex digits, or `none` for no account |
| `ag_deployment` | Exact validated `MemoryProviderDescriptor.id` |
| `ag_scope` | Unpadded base64url of sorted-key JSON encoding of `MemoryScope` |
| `ag_id` | Canonical memory UUID string |

The container encoding is injective and at most 99 ASCII characters, within the documented 100-character limit. These stable principal identifiers are not anonymized. Scope encoding preserves kind, case, Unicode and delimiters without ambiguous concatenation. Use a container-scoped credential for the bound principal when provisioning live tests; request filters do not replace account authorization.

Every result must echo matching namespace/deployment/scope metadata, a parseable unique canonical UUID, a unique nonempty bounded provider ID, and a finite score between zero and one. The entire response fails on a foreign or malformed hit. Remote content/chunks/instructions are ignored; only IDs and scores leave the adapter. Callers must still resolve these untrusted references through an active canonical record with matching ownership, scope and provider mapping. The diagnostic path does not confer memory or approval authority.

## HTTP boundary

The endpoint is fixed HTTPS; production initialization cannot supply another URL or transport. Each request uses an ephemeral URLSession with no cookie store, credential store or URL cache. Redirects are refused, including same-origin redirects. Credentials reject whitespace, control characters and excessive length. Errors expose only provider-neutral categories, never response bodies or underlying exception messages.

Request and resource timeouts are 15 seconds. Cancellation cancels the underlying task. The delegate rejects non-200 responses, non-JSON content types and oversized declared bodies, and enforces a 1 MiB cap incrementally even with unknown Content-Length. There are no automatic application retries. Each request has independent state; a lock serializes cancellation and completion so the continuation resumes once.

## Validation and next work

Portable tests use the documented response shape, an injected transport and a local URLProtocol fixture. They exercise exact-principal and scope boundaries, outgoing server filters, reference-only results, malformed/foreign/duplicate/oversized responses, credential validation, disabled defaults, cancellation, HTTP failures, MIME/streaming limits and refusal to enroll an unfenced provider.

No live API key is configured in this environment. No authenticated vendor requests, ingestion, deletion, profile calls or live isolation tests were performed. Tests do not certify remote filter enforcement or cross-user isolation. Native macOS URLSession behavior remains to be checked on macOS.

Next: resolve the durable write-fence mechanism, implement mutation/receipt handling against it, and run credential-scoped live canaries for two tenants/users/accounts and multiple scopes, including delayed upsert after deletion, crash/restart replay, provider outage, eventual indexing and deletion completion. Then integrate the proven adapter with MemoryService. Cloud RLS and context/compiler wiring remain separate later milestones.
