# Supermemory live API validation

Status (2026-09-24): **22 offline tests pass**. A credentialed one-document smoke attempt ended with transport failures on its create and cleanup lookup (two attempts total); no vendor response or remote ID was received. A separate unauthenticated diagnostic confirmed vendor-host DNS failure (`gaierror`, errno -3). Cleanup is unconfirmed and the uncertain create must not be replayed. The credential was not saved. No live pass, balance measurement or billing amount is claimed. Production writes remain disabled.

## Small-budget smoke test

Start here when credits are limited. This uses one short synthetic document, the supplied organization credential, no temporary keys, at most six readiness polls, one positive search, and bounded scoped cleanup. It does not test isolation, all scopes, or deletion races. The full eight-document suite below remains a separate explicit command.

```bash
python3 scripts/supermemory_live_canary.py plan --state-dir .canary-runs-smoke
SUPERMEMORY_LIVE_TESTS=1 python3 scripts/supermemory_live_canary.py smoke --state-dir .canary-runs-smoke --prompt-key --poll-rounds 6 --poll-interval 8
```

The plan lists all fixtures, but smoke dispatches only the first. Smoke enforces at most 20 probe requests plus 10 cleanup requests, each phase with a 120-second budget. Explicit later cleanup of this state is limited to ten requests per invocation. There are no automatic upload retries. Interrupted/uncertain creates require cleanup on the same state directory, never another smoke invocation. Reports distinguish `mode: smoke` from full-suite observations.

[Published pricing](https://supermemory.ai/pricing/) reviewed 2026-09-24 lists plain-text memory at $5 per million SM tokens, search at $5 per million queries, and operations at $100 per million operations. One under-200-character document and these bounded calls suggest a cost well below $0.01, but SM token accounting and actual billing cannot be verified by this harness. A request cap is not a vendor-enforced dollar cap. No top-up or billing settings are changed.

The attempted workspace run is retained locally in `.canary-runs-budget-one`. It ended before any successful vendor response; do not treat its cleanup as confirmed. DNS/network access must work before further live testing. Rotate a credential shared in chat and use the non-echoing prompt for future runs.

## Run the probes

Requires Python 3.10+ on macOS/Linux. The harness uses the standard library only. Use a dedicated Supermemory test organization. This creates eight short synthetic documents and five temporary container-scoped keys; provider usage may be billed. It never uses real user memories.

From the repository root:

```bash
python3 scripts/supermemory_live_canary.py plan --state-dir .canary-runs-one
SUPERMEMORY_LIVE_TESTS=1 python3 scripts/supermemory_live_canary.py run --state-dir .canary-runs-one --prompt-key
```

The key prompt requires an interactive terminal and does not echo the key or put it in command history. Use an organization key for the test organization, because creating/revoking temporary scoped keys requires it. It stays in memory. For a CI secret store, set `SUPERMEMORY_API_KEY` instead and omit `--prompt-key`. Never paste a key into chat or commit it.

The supplied directory must be private (0700). The harness creates it if absent and maintains a locked, fsynced state file. Choose a fresh directory for each new run. Keep it until cleanup is resolved. State and reports include only synthetic IDs, test outcomes and cleanup identifiers; credentials and raw provider bodies are not saved. Directories matching `.canary-runs*` are ignored by git, including the path used above.

A run that already began cannot be replayed. This prevents another POST from appending to an uncertain earlier document. After interruption or incomplete cleanup, use the existing state:

```bash
SUPERMEMORY_LIVE_TESTS=1 python3 scripts/supermemory_live_canary.py cleanup --state-dir .canary-runs-one --prompt-key
```

Cleanup validates the exact run metadata, namespace and custom ID before deleting a known document. It does not perform organization-wide, container-wide or bulk deletion. For a create whose response was lost, it searches only the run's container and metadata to locate its unique custom ID. If that remains unknown, cleanup reports it unresolved; it does not resend the create. Explicit subsequent cleanup can repeat a deletion only after confirming that the remaining document belongs to this run.

Known temporary key IDs are revoked even if document cleanup fails. Keys request a one-day expiry. An uncertain key-creation response leaves an unresolved entry: the harness cannot revoke an ID it never received and will not claim complete cleanup. Expiry is a fallback, not a successful revocation observation.

Exit codes: `0` = requested bounded observations completed; `1` = failed/incomplete observations; `2` = missing credential, missing opt-in, invalid local state/configuration or another preflight failure. Check both `report.json` and `state.json`. `production_ready` always remains false, including on exit 0.

## What is exercised

Five distinct container identities vary tenant, user, account and absent account independently. The same canonical UUID is intentionally used in separate principals. The owner also has project and workspace records, with distinct scope metadata. Unique run IDs ensure no existing index is reused.

The harness performs these checks:

- Ingestion with minimum synthetic content, namespace/deployment/scope metadata and matching ingestion-context filters.
- Polling of document processing and memory-extraction readiness. `done` is only a condition for starting observations, not a strong completion guarantee.
- Positive document-search controls for every intended principal/scope, using both its scoped credential and the test organization credential. Empty searches cannot pass this control.
- Adversarial searches using another scope/principal's exact canary as the query while retaining the intended container and scope filters.
- Cross-principal document/search requests using the wrong scoped key, plus denied cross-principal DELETE attempts against synthetic fixtures. A delete-denial response is followed by an authorized read to verify the document still exists.
- One deletion immediately following ingestion. If it is already fully processed by the time deletion begins, the race check is marked `not_exercised` and the run stays incomplete.
- Repeated bounded post-deletion checks for document lookup, document search, memory search including forgotten entries, memory listings with source-document/history references, and exact canary-marker presence in profiles.
- Scoped cleanup after both success and failure. Retained derived memory entries prevent a clean observation even when document lookup is 404 and search is empty.

This is a vendor API probe suite, separate from the Swift provider's portable contract tests. It does not enable or silently implement the missing production mutation driver. It does not inject arbitrary server-side job delays or prove an unbounded guarantee. Same-document append/replacement retry semantics, native macOS networking, cloud RLS and full migration remain separate work.

## Bounds and failure behavior

The HTTP client uses a fixed HTTPS host, no redirect following, no environment proxies and no automatic request retries. Requests have ten-second socket timeouts, a run budget of 400 requests/600 seconds checked around I/O, and a 1 MiB response limit. These are probe safeguards, not a hard real-time guarantee for operating-system DNS/header parsing. Cleanup receives a separate 100-request/180-second budget. Readiness polling defaults to 20 rounds with a two-second interval; each probe invocation does bounded work.

Memory listings are bounded to two pages of 100 entries per container. More pages make the result incomplete rather than assuming missing pages are empty. Profile checks detect exact retained canary text, not every possible semantic paraphrase. Missing/unobserved derivations and unavailable endpoints can leave evidence incomplete. An empty retrieval is never represented as proof of physical erasure.

## Evidence still required before production writes

Reviewed primary sources on 2026-09-24:

- [API keys and container-scoped credentials](https://supermemory.ai/docs/authentication): scoped-key creation/revocation and container restrictions.
- [Document operations](https://supermemory.ai/docs/ingestion/document-operations): asynchronous processing, update/delete operations and readiness statuses.
- [Memory lifecycle and deletion](https://supermemory.ai/blog/memory-lifecycle-retention-corrections-deletion/): memory forgetting differs from source deletion; an empty search does not establish that every stored copy was erased.
- [Memory search](https://supermemory.ai/docs/api-reference/recall-search/search-memory-entries), [profiles](https://supermemory.ai/docs/api-reference/profiles/get-user-profile) and the [live OpenAPI schema](https://api.supermemory.ai/openapi.json) define the probe request shapes.

The reviewed material does not establish the stronger lifecycle promises required by `MemoryMutationDriver`. Obtain concrete answers/evidence for:

1. Which observable state guarantees that **all** processing, extraction, dreaming and retry jobs for a particular immutable upload can no longer write following deletion?
2. Does a successful document deletion durably fence every such job, including one already running or delayed, and remove associated derived memories/profile contributions? How is completed removal observed?
3. Can a request accepted before deletion create data afterward? What happens after response loss, internal retries, and requests with an existing custom ID?
4. Which indexed, derived, cached or backup copies remain outside the deletion guarantee, and what cleanup/retention mechanism covers them?

No message has been sent to the vendor. These are the specific unresolved integration requirements. A finite successful run supplies regression evidence; it cannot establish an undocumented unlimited-lateness guarantee. If the provider cannot satisfy the contract, the production decision must be a controlled backend or an explicit product-contract change, not setting `verifiedLifecycle` to true.
