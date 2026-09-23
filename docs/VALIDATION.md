# Validation record

## Context Service — 2026-09-23

Environment: Swift 6.2.1 on Linux x86_64.

- Added provider-neutral `ContextServing` boundary plus actor-backed `ContextService` reference implementation.
- Storage is partitioned by exact `TenantContext` before lookup/search; it does not scan a global collection and filter ownership afterward.
- Query data deliberately contains no tenant/user identity field. The principal is supplied separately by trusted caller/session code.
- Store operations reject principal mismatch.
- Reads, deletion, clear, count, and search are partition-local.
- Identical context UUIDs may coexist in different principal partitions without collision or cross-read.
- Search supports exact scope/key/trust/origin/session/device/task filters, configurable stale-item inclusion, deterministic newest-first ordering, and a hard 100-result maximum.
- Stale context is excluded by default using the `ContextFreshnessPolicy` supplied to the service.
- Ran `swift test -j 2` against the isolated production context schema + Context Service test package.
- **17 tests passed with zero failures**: the 9 context-schema tests plus 8 Context Service tests.
- Context Service tests include deterministic cross-principal canaries (`ALPHA-PINEAPPLE-7834` / `BETA-ZEBRA-9911`), same-ID partition isolation, wrong-principal write refusal, stale filtering, query bounds, filtering-before-limit behavior, deterministic ordering, and partition-local deletion/clear.

This is application-layer/reference isolation only. It does **not** satisfy the later database-level RLS, provider namespace isolation, tenant-scoped vector retrieval, tenant-scoped distributed cache, or durable persistence checklist items.

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
- This branch is stacked on the previously validated 36-test orchestrator/decision/device/approval AgentCore base. The existing sources were not modified by this slice. A single complete private-repository checkout is not available in the current Linux tool environment, so this entry does not claim a fresh whole-repository run.

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
- `swift test -j 2`: AgentCore compiled and linked; **10 tests passed**, including
  parameterized cases for all three non-read risks, malformed inputs, and both
  initial/completion audit failure. Zero failures.
- Verified successful output and correlation, metadata-only audit, denied
  permissions, unknown tools, invalid arguments, refusal before execution,
  failure after execution, duplicate registration, error redaction, JSON types
  and large integers, audit append behavior, 0600 permissions and symlink refusal.
- `bash -n scripts/build-app.sh`: passed.
- Info.plist parsed; bundle executable and menu-bar metadata checked.
- Native Swift sources parsed successfully with `swiftc -frontend -parse`.
  This checks syntax only, not Apple API availability or actor annotations.

## Native validation still pending

- macOS type checking, linking, bundle signing, or launch.
- MacRuntime adapter tests (excluded from the Linux manifest).
- Real foreground-app lookup, permission prompt/grant/revocation, or menu UI.
- GitHub Actions run 35757635596 has repeatedly failed before any workflow step
  starts because the account-side macOS hosted-runner restriction remains active.
  No Swift build failure has been observed from that workflow.

Therefore the project is **core-verified, native verification pending**.
Do not describe it as a working, fully verified Mac app yet.

## Native gate

1. On macOS 14+ with Swift 6+, run `swift test`.
2. Run `bash scripts/build-app.sh`; verify successful codesign checks.
3. `open dist/MetaAIGlasses.app`; ensure one Agent menu appears.
4. Leave Accessibility disabled. Inspect Safari after the 3-second delay.
   Expect a success result identifying Safari, with a positive PID.
5. Repeat with another app and confirm the identity changes.
6. Check that each request has started/completed audit events sharing its ID,
   without application names, arguments or result data in the audit file.
7. Choose Request Accessibility permission. Confirm nothing is auto-granted;
   grant/revoke in System Settings and reopen the menu to verify status changes.
8. Run `RUN_MAC_GUI_TESTS=1 swift test` from the interactive Mac session.
9. Quit and relaunch the app. Confirm log appends and the first tool still works.

After this gate passes, `ui.get_windows` remains the next native read-only tool.
Before the first mutating tool, wire a trusted local approval UI to `ApprovalStore`.
