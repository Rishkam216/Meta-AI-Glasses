# MemoryProvider and Memory Service

`MemoryService` is the provider-neutral boundary above the canonical ledger. It implements remember/supersede, search, optional profile retrieval, forget, export, capability inspection and bounded synchronization. It uses the actual durable ledger through `MemoryServiceLedger`; provider SDK types stay behind `MemoryProvider`.

## Data and authority

Every service is bound to one exact authenticated tenant/user/account. Every public call still requires that identity. The provider namespace is derived by the service; it is never selected by a model. Adapters must enforce namespace and requested scopes **before** remote candidate retrieval. The service also validates responses defensively.

Search/profile responses contain canonical references and scores. Only active, requested-scope records with the matching provider mapping are returned from a fresh canonical snapshot. Foreign namespaces, oversized responses, duplicate IDs and invalid scores fail closed. Unmapped, historical, forgotten and wrong-scope hits are discarded. Returned content always comes from our ledger and has fixed `.memory` trust, never instruction/approval authority.

Provider documents contain only canonical ID, scope, kind, content and confidence. Source paths, source references, provider metadata and authorization fields are not copied to the provider document. The namespace still contains stable principal identifiers needed for partitioning. Application-level secrets redaction and retention policy remain separate unfinished plan items.

## Explicit processing and composition

Provider processing is disabled by default. Trusted application code must enable it after its consent and data-minimization checks. This is a composition switch, not a persisted account-wide consent system: revocation must stop every enabled worker. It does not erase already-indexed remote data. Enrollment with processing enabled prepares all existing canonical records for that provider; it is not per-record consent.

```swift
let service = try MemoryService(
    principal: authenticatedTenant,
    ledger: durableLedger,
    providers: [adapter],
    providerProcessingEnabled: true
)
let receipt = try await service.remember(record, as: authenticatedTenant)
let report = try await service.synchronize(as: authenticatedTenant, maxOperations: 32)
```

`remember`/`forget` return after canonical state and desired provider operations are saved atomically. They do not perform remote indexing on the realtime turn. A worker explicitly calls `synchronize` until `remaining` is zero. Successful save does not imply successful remote indexing. Identical remember retries are idempotent; conflicting reuse of a canonical ID is rejected. A storage error after a canonical commit can be retried using the same record ID.

## Durable synchronization

The ledger retains enrolled provider deployment IDs, a monotonic revision sequence, latest desired operations, acknowledgements and retry timestamps. Every original ledger write also reconciles enrolled providers, so bypassing the service cannot silently leave stale indexes. Forgetting schedules deletion for the entire removed lineage/derivation family and every previously enrolled provider, even if that adapter is temporarily absent.

Synchronization is bounded to 1–100 operations per call. Attempts are saved before network calls. Least-recently-attempted work runs first; never-attempted deletes win ties. Persistent failures therefore do not permanently block later work. Transport errors are reduced to safe error categories; raw provider bodies/credentials are not returned. Missing adapters leave their work pending. Cancellation leaves retryable work.

The remote write and local acknowledgement cannot be one transaction. Replaying the same operation ID/revision closes that crash window. Acknowledgement and provider mapping are saved together and only if the desired operation is still current. A late acknowledgement cannot erase a newer deletion. Portable export version 3 includes this synchronization state. Existing v2 local snapshots load without data loss and upgrade on their next successful write; a v2 snapshot containing v3 synchronization fields is rejected.

## Mandatory adapter guarantees

`MemoryProviderDescriptor` reports namespace isolation, scope filtering, idempotent revision fencing, search and optional profile support, plus payload/result limits. The service rejects adapters without the first three guarantees.

An adapter must durably fence mutations by `(namespace, canonicalID, revision)`. Lower revisions cannot overwrite higher revisions, and a deletion fence must survive removal of its document. A receipt must mean the fence is committed, not merely queued. Otherwise a delayed upsert could recreate data after deletion. A vendor that lacks native conditional writes needs an enforcing gateway or another proven adapter mechanism; do not advertise this capability based on an assumption. Each real adapter must also enforce transport deadlines, cancellation, response byte limits, credentials handling and the namespace contract.

Provider IDs identify deployments/index generations (for example `vendor.production-v2`), not just vendors. Registering a new ID rebuilds it from canonical records while keeping canonical IDs stable. This local implementation retains at most eight enrolled IDs. Provider retirement, shadow-read quality comparison and full migration orchestration remain later work. Restoring an older snapshot must not reset revision fences; stale-backup recovery needs the planned migration/recovery protocol.

## Validation and remaining integration

The complete portable suite passes 152 tests, including 26 new service/provider tests. Tests use a revision-fenced contract double, plus actual file-backed restart and corruption tests. They prove the service/ledger behavior; they do not prove any vendor implements the contract.

The Supermemory read-only adapter foundation is now implemented separately (see `SUPERMEMORY_ADAPTER.md`), but its false revision-fencing capability intentionally prevents enrollment. Full Supermemory mutation support, live API validation, cloud database isolation, Context Compiler retrieval wiring, native app composition, deployment workers, provider-wide deletion verification and full migration remain open. No external memory service has been contacted or configured by this milestone.

## Durable coordinator integration (2026-09-24)

`RevisionFencedMemoryProvider` now implements the mandatory revision/deletion fence using an authoritative local journal and a lower-level `MemoryMutationDriver`. It performs at most one remote call per apply, retains uncertain dispatches rather than resending them, and returns receipts only for the exact current operation after strong settlement/removal. `MemoryService.synchronize` preserves safe provider error categories such as `operationPending`, so pending processing is distinguishable from a generic outage.

A driver must prove its strong remote lifecycle semantics before this wrapper can be constructed. This is not a flag to enable the direct Supermemory adapter. The full package now passes 182 portable tests; the actual Supermemory lifecycle remains unverified. See `MEMORY_WRITE_SAFETY.md` for implementation, recovery restrictions and the remaining blocker.
