# Validation record

## Durable write coordination — 2026-09-24

- Full Swift 6.2.1 / Ubuntu 24.04 package: `swift test -j 2` — **182 tests passed, 0 failures**, no compiler warnings.
- Added 18 tests using real journal files and a remote lifecycle-contract simulator: durable replay; permanent tombstones; crash immediately after dispatch claim; lost create/delete responses; processing versus settlement; indefinite uncertain deletion; deletion while the original worker is paused before create; concurrent identical retries; late responses after deletion; cancellation with outcome persistence; immutable-content/revision conflicts; payload stripping; principal/deployment/corrupt/missing-file refusal; malformed provider IDs; size/invalid-mutation rollback; and unverified-driver rejection.
- Memory Service integration verifies pending work is not acknowledged, safe pending errors remain visible, and confirmed operations map/acknowledge once. Retrieval hides fenced records during pending remote deletion.
- Reused the existing secure filesystem primitive without changing its behavior; previous ledger tests still pass. `git diff --check` passed.
- These tests establish local coordination under the driver lifecycle contract. No live Supermemory write driver, vendor completion guarantee, cloud database isolation or macOS validation is claimed. No API key is configured. See `MEMORY_WRITE_SAFETY.md`.

## Supermemory read-only adapter foundation — 2026-09-23

- Complete package on Swift 6.2.1 / Ubuntu 24.04: `swift test -j 2` — **164 tests passed, 0 failures**.
- Added 12 tests with parameterized cases covering exact tenant/user/account ownership, bounded injective container tags, case-sensitive Unicode scope encoding, outgoing container/deployment/scope filters, canonical references only, malformed/foreign/duplicate/oversized responses, invalid credentials, sanitized failures and disabled defaults.
- Local URLProtocol fixtures exercise actual URLSession response handling: HTTP 429, wrong MIME, declared/streamed byte limits, success and cancellation. Fixtures never contact a remote server.
- Verified MemoryService refuses this adapter because durable revision fencing is unsupported; apply/delete/profile issue no requests. Mandatory service requirements are unchanged.
- `git diff --check` passed. Official current API schemas/changelog reviewed; no authenticated vendor calls performed and no key is configured. Live isolation, mutation fencing/deletion, native macOS transport and cloud RLS remain pending. See `SUPERMEMORY_ADAPTER.md`.

## MemoryProvider and Memory Service — 2026-09-23

- Complete package on Swift 6.2.1 / Ubuntu 24.04: `swift test -j 2` — **152 tests passed, 0 failures**.
- Added 26 service/provider tests covering canonical-first commits, processing disabled by default, every service identity boundary, same-ID cross-tenant canaries, scoped search/profile, canonical result validation, minimal provider payloads, capability gates, outage/cancellation retries, malformed receipts, bounded retry fairness, multiple providers/reindexing, lineage deletion and stale-acknowledgement rejection.
- Controlled two-worker race proves a contract-compliant provider rejects a delayed lower-revision upsert after a newer deletion.
- Real file-backed tests cover pending-work and acknowledgement restart recovery, remote-success/local-ack crash-window replay, atomic rollback on persistence failure, v2 upgrade, queue ownership/format corruption and revision-counter exhaustion.
- Existing 126 portable tests continue to pass. `git diff --check` passed.
- Provider tests use a revision-fenced contract double, not Supermemory or another live service. No live API behavior or production gateway is claimed. Native macOS and cloud RLS validation remain pending.


## Durable local Memory Ledger — 2026-09-23

Environment: Swift 6.2.1, Ubuntu 24.04 x86_64, Swift 6 language mode.

- Reconstructed the complete source tree from context foundation `58e135962cad5db38cdd433405045d280bc9dc84` plus the three Memory Ledger files from `d69f0b49693a546925717c721fdcb463414b79a5`; compared the branches before combining them. No existing source changes were dropped.
- Ran `swift test -j 2` against the complete combined package: **126 tests passed, 0 failures**. This includes all 18 existing memory-contract tests and 20 new durable-memory tests, plus the existing context/orchestrator/runtime tests.
- New coverage includes restart/fractional-date recovery; source and derived provenance; atomic supersession/mapping conflicts; exact tenant/user/account isolation across every public operation; same canonical/provider IDs in distinct users; concurrent handles with no lost accepted writes; size-failure rollback; corruption, cyclic references, tombstone resurrection and foreign ownership rejection; missing-file errors through the storage protocol; private file/directory modes; symlink/hard-link/FIFO/lock-file refusal; lock contention; local deletion of history/derived copies/mappings; unknown-ID tombstones; and deleted-ID reinsertion refusal.
- Durable reads now throw rather than silently returning empty memory after an I/O or decoding failure. The in-memory and file-backed implementations share the same value-state validation engine.
- File snapshots use an independent envelope version 1 and portable export format version 2 (adds content-free tombstones). No v1 import or provider migration pipeline is claimed.
- `git diff --check` passed.

Scope: implemented and tested local/offline persistence. Cloud database/RLS isolation, Memory Service orchestration, provider indexing/deletion propagation, encrypted backups, and native macOS execution remain open. File-lock tests cover competing handles and an independently opened advisory lock; they are not crash/power-loss or multi-host storage certification. Temporary snapshots are fsynced before rename and the directory is fsynced afterward; an error after rename is explicitly reported as `commitOutcomeUnknown`.


## Durable context + stale refresh + orchestrator consumption — 2026-09-23

Environment: portable Swift 6.x core; GitHub hosted runners currently unavailable before step execution.

- Added `FileBackedContextService` as the durable local/offline `ContextStoring` reference implementation.
- Durable writes use same-directory atomic replacement with a 0600 regular file, symlink refusal, owner checks, versioned decoding, corruption/size checks, and disk-before-memory mutation semantics.
- Durable-context tests cover restart recovery, same context UUID in different tenant partitions, persisted deletion, tenant-local `removeAll`, corrupt-file refusal, symlink refusal, and file permissions.
- Added application, connected-service, and device-runtime refresh adapter contracts plus `ContextRefreshCoordinator`.
- Stale ephemeral context can be refreshed before compilation with bounded refresh work. Adapter output cannot choose tenant, scope, key, bindings, or trust; those remain deterministic application-owned fields.
- Connected-service refresh is always classified as `external_content`; device/application refresh is system state. Cross-tenant refresh is rejected and ambiguous adapters fail closed.
- Added explicit Context Compiler scopes and provider opt-ins. User scope, memory, external content, and model-generated context are not included by default.
- Added `AgentInvocationContext`, which carries authenticated `TenantContext` separately from model-generated `ToolIntent`.
- `AgentOrchestrator` now consumes tenant-safe compiled context only for ambiguous read-only bounded device decisions. Explicit-device, active-device, single-candidate, and ambiguous non-read paths remain deterministic and do not perform model/context selection work.
- Candidate device scopes are included for bounded read selection, while external content, memory, model-generated content, user instructions, and other tenants remain excluded from the bounded decision context.
- Added an orchestrator regression test proving another tenant's canary and injected external-content instruction are not present in the bounded decision's compiled context.
- Added `.github/workflows/core-linux.yml` so portable AgentCore has a dedicated Linux CI lane separate from macOS-native validation.
- The new `Portable core` hosted workflow currently fails before step 1 with zero steps because of the same account-side Actions runner restriction affecting macOS. This is an infrastructure/billing restriction, not a Swift compile/test failure.

Conservative status: durable local context, stale-refresh boundaries, model-specific compilation, and bounded-decision orchestrator consumption are implemented. Cloud database/RLS isolation, real production application/connected-service adapters, session summarization/artifact handling, and realtime interface/model integration remain open.

## Context service + compiler — 2026-09-23

Environment: Swift 6.2.1 on Linux x86_64.

- Added tenant-partitioned `InMemoryContextService`; writes reject ownership mismatch and reads/queries/deletes enter the exact `TenantContext` partition before any filtering.
- Consolidated bounded-query semantics: exact scope, scope-kind, key, trust, origin, freshness, session, device and task filters; validated 1–100 result limits; newest-first deterministic ordering; partition-local count/clear/remove; and support for the same context UUID existing independently in different principals.
- Added validated typed `InterfaceContextState`, `SessionContextState`, `DeviceContextState`, and `TaskContextState`. User-controlled text/maps/lists are bounded, device capability names are trimmed/deduplicated/sorted, duplicate job IDs are rejected, and wire decoding re-runs validation. Meta-glasses interface state requires an explicit phone companion device.
- Added `ContextRefreshCoordinator` with device/application/connected-service adapter boundaries. Adapters cannot change tenant, scope, key, bindings, or trust. Connected-service refresh is always tagged `external_content`; ambiguous adapters fail closed; cross-tenant refresh is rejected before adapter execution.
- Added `ContextCompiler` with explicit requested scopes, same-user session/device/task isolation, stale-item exclusion, optional bounded stale-ephemeral refresh, deterministic item/byte budgets, and provider-facing output that omits tenant/user/account IDs while preserving trust/provenance labels.
- User scope is not included unless explicitly requested. Long-term memory requires both user-scope selection and `includeMemory`. External content requires `includeExternalContent`. Model-generated context is reasoning-only and requires `includeModelGenerated`.
- Jev-style bounded decisions receive only `system_state` and `tool_result`, even if a caller attempts to opt into user instructions, memory, external content, or model-generated context.
- Failed stale refresh never falls back to stale data. Refresh work is bounded per compilation request.
- Cross-tenant canary tests verify User A and User B cannot retrieve each other's context through direct lookup, query, compilation, or same-ID collisions.
- Focused Linux package using the current production context source contracts plus hardening/regression tests: **35 tests passed, 0 failures**.

This section records the earlier portable context milestone. Later sections above supersede its statements that durable persistence and orchestrator consumption were pending.

## Tenant + context-item foundation — 2026-09-23

Environment: Swift 6.2.1 on Linux x86_64.

- Added required `TenantContext` ownership metadata with tenant, user, and optional account identity.
- Added portable `ContextItem`, explicit scope, runtime bindings, provenance/trust classification, freshness metadata, and configurable max-age policy.
- Context scope/key/source identifiers are bounded and reject empty/ambiguous values.
- Private context ownership uses exact principal matching; future shared-workspace access must be an explicit ACL layer rather than weakening this boundary.
- Added explicit `external_content`, `memory`, and `model_generated` trust classifications so retrieved content cannot be represented as a user instruction by omission.
- Added custom decoding for validated wire-facing structs. Decoding re-runs validation instead of allowing Swift synthesized `Decodable` to bypass constructor invariants.
- Explicit validity windows and policy maximum ages both participate in staleness checks; no freshness class receives a hidden implicit TTL in AgentCore.
- Ran an isolated Swift package containing the production `JSONValue` contract, the committed context foundation, and its tests with `swift test -j 2`.
- **9 context-foundation tests passed with zero failures**.
- Tests cover exact tenant/user/account ownership, scope validation, round-trip preservation, cross-principal rejection, explicit and policy-driven staleness, invalid freshness policies, identifier bounds, external-content trust preservation, and malformed decoded-wire-data rejection.
- This branch is stacked on the previously validated 36-test orchestrator/decision/device/approval AgentCore base. A single complete private-repository checkout is not available in the current Linux tool environment, so this entry does not claim a fresh whole-repository run.

## Orchestrator + decision engine — 2026-09-23

Environment: Swift 6.2.1 on Linux x86_64.

- Added provider-neutral `DecisionProvider`, deterministic `DecisionRule`, validated decision outcomes, bounded-confidence escalation, and `DecisionEngine`.
- Added `AgentSession`, `ToolIntent`, and `AgentOrchestrator` on top of `DeviceRouter`.
- Ran `swift test -j 2` against the complete stacked AgentCore branch.
- **36 tests passed with zero failures**.
- New decision tests verify deterministic rules run before bounded providers, a confident bounded decision avoids the reasoning provider, low-confidence/failing bounded decisions escalate correctly, invented options are rejected, and low-confidence output without a fallback fails closed.
- New orchestrator tests verify explicit/active/single-device routing bypasses AI, ambiguous read routing requires explicit session opt-in, bounded selection can choose only among advertised read-only candidates, ambiguous non-read routing never invokes the bounded provider, inconsistent risk classification fails closed, and missing capabilities fail before decision.
- Decision state is provider-neutral structured JSON. External adapters must curate it and must not dump credentials, raw unrelated conversation history, or unnecessary screen/file contents into a decision request.
- No Jev/OpenAI/Claude SDK is linked yet. The future Jev adapter implements `DecisionProvider`; it does not become a security authority or execution layer.

This validates portable AgentCore behavior only. It does not validate AppKit, Accessibility, CoreGraphics, codesigning, TCC, or interactive macOS behavior.

## Device routing foundation — 2026-09-23

- **21 tests passed with zero failures** at this milestone: 10 original runtime/audit/contract tests, 5 approval tests, and 6 device-routing tests.
- Routing tests verify capability-based candidate selection independent of platform metadata, exact device/session context construction, approval forwarding, unknown-device rejection, unadvertised-capability rejection, duplicate-device rejection, and routing through a real `ToolRuntime` adapter.
- `snapshots()` copies the registered executor collection before awaiting capability calls so actor reentrancy cannot mutate the dictionary mid-iteration.

## Core approval foundation — 2026-09-23

- **15 tests passed with zero failures** at this milestone: the original 10 runtime/audit/contract tests plus 5 approval tests.
- Approval tests verify exact binding, one-time execution, replay rejection, argument tamper rejection, device/session binding, expiry, bounded TTL, and refusal to issue approval for read-only tools.
- Existing tests still verify default refusal of all non-read actions when no trusted approval issuer is supplied.
- The current Mac composition root still uses the default `DenyAllApprovals`, so these portable foundations do not enable mutations.

## Milestone 1 — 2026-09-22

- Swift 6.1.2 on Ubuntu 24.04, strict Swift 6 language mode.
- `swift test -j 2`: AgentCore compiled and linked; **10 tests passed**, including parameterized cases for all three non-read risks, malformed inputs, and both initial/completion audit failure. Zero failures.
- Verified successful output and correlation, metadata-only audit, denied permissions, unknown tools, invalid arguments, refusal before execution, failure after execution, duplicate registration, error redaction, JSON types and large integers, audit append behavior, 0600 permissions and symlink refusal.
- `bash -n scripts/build-app.sh`: passed.
- Info.plist parsed; bundle executable and menu-bar metadata checked.
- Native Swift sources parsed successfully with `swiftc -frontend -parse`. This checks syntax only, not Apple API availability or actor annotations.

## Native validation still pending

- macOS type checking, linking, bundle signing, or launch.
- MacRuntime adapter tests (excluded from the Linux manifest).
- Real foreground-app lookup, permission prompt/grant/revocation, or menu UI.
- GitHub Actions run 35757635596 has repeatedly failed before any workflow step starts because the account-side macOS hosted-runner restriction remains active. No Swift build failure has been observed from that workflow.
- The new Linux portable-core workflow also currently fails before step 1 with zero steps for the same hosted-runner account restriction.

Therefore the project is **portable-core verified at recorded milestones, native verification pending**. Do not describe it as a working, fully verified Mac app yet.

## Native gate

1. On macOS 14+ with Swift 6+, run `swift test`.
2. Run `bash scripts/build-app.sh`; verify successful codesign checks.
3. `open dist/MetaAIGlasses.app`; ensure one Agent menu appears.
4. Leave Accessibility disabled. Inspect Safari after the 3-second delay. Expect a success result identifying Safari, with a positive PID.
5. Repeat with another app and confirm the identity changes.
6. Check that each request has started/completed audit events sharing its ID, without application names, arguments or result data in the audit file.
7. Choose Request Accessibility permission. Confirm nothing is auto-granted; grant/revoke in System Settings and reopen the menu to verify status changes.
8. Run `RUN_MAC_GUI_TESTS=1 swift test` from the interactive Mac session.
9. Quit and relaunch the app. Confirm log appends and the first tool still works.

After this gate passes, `ui.get_windows` remains the next native read-only tool. Before the first mutating tool, wire a trusted local approval UI to `ApprovalStore`.

