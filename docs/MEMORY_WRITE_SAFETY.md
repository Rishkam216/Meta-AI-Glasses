# Durable memory write coordination

Status: implemented and integrated with MemoryService against a lifecycle-contract simulator. **Supermemory writes remain disabled.** This coordinator supplies durable revision fencing; it cannot invent remote processing/deletion guarantees that a vendor does not expose. A real driver must prove those guarantees before enrollment.

## Decision

Use one authoritative journal for each authenticated tenant/user/account and provider deployment. Every worker for that partition must share that journal. The coordinator accepts monotonic revisions, durably records dispatch before network I/O, sends an immutable upload at most once, and permanently fences deleted canonical IDs. A missing or ambiguous response leads to observation, never an automatic mutation retry.

This deliberately chooses safety over availability: a crash after recording dispatch but before actually sending may leave an operation blocked indefinitely. An absent document does not prove that a paused worker or delayed request cannot create it later. There is no lease timeout, force-unlock, blind resend or pretend-success escape hatch.

The coordinator implements `MemoryProvider`, so MemoryService can use it without weakening its three mandatory capabilities. Its constructor rejects drivers that have not established the stronger remote lifecycle contract. The existing direct Supermemory adapter still reports false for revision fencing and still rejects mutations.

## Remote lifecycle assumptions that must be proven

`MemoryMutationDriver` receives a `MemoryIndexAttempt` binding namespace, canonical ID, initial revision, initial operation ID and a random immutable upload ID. The driver must validate this complete identity on every observation. It must isolate retrieval before searching and must not internally retry mutation requests, including through an SDK. All calls need deadlines, cancellation and bounded responses.

The driver's `verifiedLifecycle` property represents implementation evidence, not a user-supplied enable switch. Setting it true to bypass the constructor would invalidate the safety argument.

| Observation | Required meaning |
| --- | --- |
| `unknown` | Missing, failed, uncertain or otherwise inconclusive outcome. No permission to resend or acknowledge. |
| `processing(id)` | The correct upload was accepted but can still cause remote changes. |
| `settled(id)` | All work for this upload has finished. No queued/retried operation can later create or change its data following deletion. |
| `deleted` | All indexed/derived copies for this upload are removed and cannot be recreated by its outstanding work. Valid only after deletion has been claimed. |

A normal 404 is not automatically `deleted`. A searchable document or status `done` is not automatically `settled`. Identity mismatches, changed provider IDs and premature deletion observations fail closed. The journal also rejects reuse of a provider document ID across its retained canonical entries.

## Durable state transitions

| Saved phase | Next permitted action |
| --- | --- |
| Ready | Atomically claim creation, save `creating`, then issue one create. |
| Creating | Observe the unique upload. Never send another create. |
| Processing | Observe until strong settlement is established. |
| Settled | Return an upsert receipt, or atomically claim the requested deletion. |
| Deleting | Observe until strong deletion is established. Never repeat the delete. |
| Deleted | Return the current deletion receipt; refuse every future upsert for this canonical ID. |

Each `apply` invocation performs at most one remote call. It returns `operationPending` while more observation is needed; MemoryService retains the work and now preserves that safe error category. Accepting deletion immediately persists the fence and removes the journal's document payload. The provider filters fenced records out of search/profile results while physical deletion is pending. MemoryService still resolves results through the canonical ledger, ownership, scope and provider mappings.

A new canonical ID is immutable. Corrections follow the existing ledger's supersession model: upload the replacement ID and delete the old ID. A higher revision containing the same payload can reuse the already-created upload. A higher revision cannot mutate its content or resurrect a deleted ID. Reusing the current revision with a different operation/action/payload is a conflict.

An unknown-ID deletion creates a content-free permanent fence and requires no remote request, because this authoritative deployment journal has never dispatched its upload. This conclusion requires a fresh index at provisioning and no writers outside the coordinator; it is invalid for an existing uncontrolled index.

## Crash and race argument

1. The journal's filesystem lock makes acceptance and dispatch claiming indivisible across handles/processes. It is released before network I/O. State is reloaded for every transaction.
2. Only the transaction that changes `ready` to `creating` receives create work. Once persisted, every other worker only observes that upload. A restart cannot issue a duplicate append/create.
3. A deletion accepted during an uncertain upload records the fence immediately but cannot dispatch delete until the upload is strongly settled. Even a worker paused just before create cannot cause a delete-then-late-create sequence to be acknowledged as complete.
4. Only the transaction changing `settled` to `deleting` receives delete work. Lost delete responses lead to observation, not another request.
5. Remote observations update only the matching attempt and saved phase. Late processing/create observations cannot move a settled/deleted entry backwards.
6. Receipts re-read the journal and require the exact current revision/operation/action. An older worker cannot acknowledge a newer operation. MemoryService separately checks the canonical queue before recording its acknowledgement.

These properties are conditional on the driver's lifecycle promises and one intact authoritative journal. The tests prove the local coordination behavior under those assumptions; they do not certify Supermemory's server internals.

## Storage and recovery boundary

The journal reuses the ledger's directory-relative POSIX storage: owner-only directory/file, symlink/hard-link refusal, nonblocking advisory lock, same-directory replacement, file fsync and directory fsync. The existing ledger implementation's behavior is unchanged; its helper is now internal for reuse.

Provisioning is an explicit operation for a fresh remote deployment. Opening a missing, corrupt, mismatched-principal or mismatched-deployment journal fails; it never silently creates a new empty fence table. Existing journals cannot be provisioned over. The journal retains content-free deletion fences and remote IDs rather than garbage-collecting them.

Never run workers against independent copies, restore an old journal snapshot against the current index, or delete/recreate it under the same deployment ID. Recovery from a lost journal requires an independently established remote quiescence/purge protocol or a genuinely new isolated deployment/index. This is a local, single-host reference implementation, not a cloud database, distributed gateway, global consent service or backup-erasure system. Production cloud storage still needs transactional compare-and-set and authenticated row isolation.

## Supermemory evidence and remaining integration

Re-read the [official live OpenAPI schema](https://api.supermemory.ai/openapi.json) and [document operations](https://supermemory.ai/docs/ingestion/document-operations) on 2026-09-24. Schema SHA-256 remains `05278ca4fc42dccbfed95eeafca1e1697fd72969ee10f8aa596d75c018171b6f`.

The document response includes `status`, `dreamingStatus`, `latestRevision`, `activeContentUpdateId` and `tombstonedAt`. These are useful observations, but the reviewed mutation schemas provide no client conditional revision precondition. Their mere presence does not establish that `done` drains every delayed retry or that a deletion response removes all derived copies without later recreation. POST returns an ID/status; DELETE documents a 204 response. Neither is promoted to a strong lifecycle observation in this implementation.

No Supermemory mutation driver is enabled or falsely marked verified. No API key is configured in the current environment, so authenticated ingestion, lifecycle and deletion tests cannot run. The complete Supermemory adapter milestone remains open.

Required next evidence: a documented or otherwise established vendor lifecycle guarantee, followed by credential-scoped live tests covering both document processing and memory extraction, same-ID retries, delayed delivery, deletion during processing, derived-copy removal, and two independent tenant/user/account partitions. A passing finite test alone cannot prove an undocumented unbounded delayed-job guarantee. If the vendor cannot provide it, use a backend whose transaction/worker lifecycle we control rather than weakening the contract.
