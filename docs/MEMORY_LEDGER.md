# Canonical Memory Ledger: durable local milestone

The ledger owns provider-independent facts, source evidence references, derived provenance, supersession history and provider-ID mappings. Supermemory or another provider will index this ledger later. A provider never owns canonical IDs or supplies authenticated tenant identity.

`FileBackedMemoryLedger` and `InMemoryMemoryLedger` implement `MemoryLedgerStoring` using the same validation engine. The file-backed implementation persists actual records and lifecycle changes; it is not a mock. It is intended for a trusted local/offline runtime. It is **not** the cloud database for a multi-user service.

## Composition

Create one file per exact authenticated `TenantContext` (tenant, user and optional account). The containing directory must already exist, belong to the current OS user, and have mode 0700. Snapshot and lock files are 0600. Resolve known platform directory aliases before supplying the URL: the implementation rejects symlinks in every path component and does not follow them automatically.

```swift
let ledger: any MemoryLedgerStoring = try FileBackedMemoryLedger(
    url: privateDirectory.appendingPathComponent("memory.json"),
    principal: authenticatedTenant
)
try await ledger.insert(record, as: authenticatedTenant)
let results = try await ledger.query(
    MemoryLedgerQuery(scope: .user, limit: 20),
    as: authenticatedTenant
)
```

Construct `authenticatedTenant` from trusted session/backend code. Do not accept authoritative tenant IDs from model output. Binding is checked before every read, query, write, export or delete. An empty file is bound to its principal at initialization; reopening it under another principal fails. The in-memory implementation partitions by the same full identity.

No app composition root is wired to a memory provider yet. The next slice is the MemoryProvider/Memory Service boundary. The ledger does not grant approvals, select devices or execute tools.

## Transactions and recovery

Each operation opens and locks the sidecar `.lock` file, loads and validates the latest snapshot, and performs its work without an asynchronous suspension. Competing handles cannot save stale cached state. Lock contention returns `MemoryPersistenceError.busy`; the service may retry with bounded backoff. Never remove the lock file while any process is using the store.

Mutations validate completely before writing. A new same-directory temporary snapshot is written and fsynced, renamed over the old snapshot, and followed by directory fsync. Directory-relative syscalls retain the original directory handle. No state is cached across operations. The default 64 MiB snapshot limit bounds reads and writes; this local implementation rewrites the snapshot and is not intended for large server datasets.

Errors before rename leave the committed snapshot intact. A directory-fsync failure after rename returns `commitOutcomeUnknown`: the new state may already be visible, so re-read before retrying. Crash-orphaned `.memory-*.tmp` files are never loaded as state. Cleanup of such files requires exclusive maintenance with all ledger users stopped. No encryption, forensic erasure of old disk blocks, distributed filesystem support or power-loss certification is claimed.

Read methods on `MemoryLedgerStoring` are now `async throws`. Missing, corrupt, oversized or insecure storage must not be interpreted as an empty memory result. Deleting an open store's snapshot causes errors; initialization at a new path creates an empty store, so the application must not silently replace a missing established account store with a newly initialized one.

Loading checks schema version, per-record constructor invariants, ownership, duplicate IDs/mappings, dangling and cyclic derivations, reciprocal supersession links, provider mapping uniqueness, and tombstone conflicts. Timestamps retain fractional seconds. A snapshot containing even one invalid record is refused as a whole.

## Forgetting and exports

Local `forget` removes the requested memory's entire supersession family and all derived descendants (including their supersession families), with their provider mappings. Independent sources of a forgotten derived fact remain. The operation is atomic and idempotent. An unknown ID receives a tombstone too, so a delayed insert cannot resurrect it.

Content-free tombstones contain the canonical ID, exact principal and deletion time. Inserts and supersessions cannot reuse tombstoned IDs. Portable export version 2 includes active records, history, provenance, mappings and tombstones in deterministic order. File envelope version 1 is separate from the portable format version. The new file store has no earlier persisted version to migrate; old v1 portable exports require an explicit future import/migration implementation.

This is local deletion only. A future Memory Service must atomically retain provider-deletion work (including provider IDs) before discarding live mappings, and propagate deletion to providers, caches, indexes and backups. Restoring a stale backup or regenerating a fact under a new ID is not prevented by these local tombstones alone; the planned migration/deletion pipeline must enforce that wider guarantee.

## Completion boundary

The local durable ledger, local mappings, local deletion and isolation tests are complete. The broad plan remains open for database-enforced cloud isolation, the Memory Service, provider adapters, provider deletion, disaster recovery/import, and migration. Do not expose this local file implementation as a cloud memory API or mark the overall architecture DONE.
