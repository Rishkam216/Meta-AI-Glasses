# Finalized Product, Context, Memory, and Orchestration Plan

Status: **Design locked. Implementation is active. Follow this document unless an explicit later architecture decision supersedes it.**

Originally finalized: 2026-09-23  
Current implementation checkpoint: **2026-09-27**

This document is the master implementation checklist and source of truth for the Personal Agent / Glasses Agent architecture.

Do **not** mark an item `[x]` because a type, interface, mock, placeholder, or partial path exists. Mark an item complete only when the intended behavior is implemented, integrated, and covered by tests appropriate to the layer.

The product is a personal agent platform. The agent is the product; models, interfaces, devices, memory providers, and identity providers are replaceable components around it.

---

# 0. Current implementation checkpoint

## Realtime response bounds — implementation validated

Branch: `core/realtime-response-bounds`, based on PR #20 merge `807522f`.
This slice bounds coordinator event/text accumulation and OpenAI wire frame/byte
processing, including duplicates and ignored frames. Budgets span tool-result
continuations and reset only for a genuine new user turn. Exhaustion closes the
session; it does not trigger a retry or roll back an already-started action.
See `docs/REALTIME_RESPONSE_BOUNDS.md` for exact limits and required merge gates.
PR #21 implementation `2bd05fa` passed native workflow `36309434676` with
**270 Swift tests**, both canary builds and app verification. Portable
`36309434705` and backend `36309434665` passed. No paid calls were made by this
implementation task; these local limits are not a precise billing cap.

## Realtime cancellation and connection cleanup — implementation validated

Branch: `core/realtime-cancellation`, based on PR #19 merge `5310f7f`.
This slice prevents a cancelled realtime turn from executing after delayed local
approval, scopes cancellation to the active session/turn, and closes failed or
cancelled provider startup. It does not add retries, reconnect/resume, voice,
production deployment, or a shipping Stop-button/approval-dialog UX.

PR #20 implementation `f5f6a76` and independent source review are complete.
Native workflow `36293794592` passed **257 Swift tests**, both canary builds and
app-bundle verification. Portable `36293794741` and backend `36293794672` passed.
PR #20 is merged at `807522fcad0838027ba4a239f62975ce89a0f9ff`, and all three
post-merge main workflows passed. No paid calls were made. See
`docs/REALTIME_CANCELLATION.md` for the behavior and validation boundary.

## Calculator execution validation — merged, live Mac gate pending

Branch: `core/calculator-execution-validation`, based on `805c7f0`.
The baseline's Backend, Portable core, and macOS workflows were freshly confirmed
successful before this work. This slice adds stitched OpenAI wire-to-native-tool
tests for allow/deny/expiry/replay and a manual, opt-in Calculator-only diagnostic.
No production scope expansion or paid provider call is included in implementation.

- [x] New stitched tests and manual diagnostic pass native CI at `373e203` (PR #19).
- [ ] Real model tool call → exact local human approval → native Calculator launch
  is verified on an interactive Mac.
- [ ] Shipping menu-bar approval UI is validated with real provider execution.

Local regression checks: 22 offline harness tests passed; backend 54 passed,
0 failed, 3 native-only skipped. Native workflow `36262825289` passed 243 Swift
tests, both canary builds, and app-bundle verification; portable `36262825249`
and backend `36262825361` also passed on implementation commit `373e203`. Do not
interpret an injected OS launcher in automated tests as real Mac execution.
See `docs/CALCULATOR_EXECUTION_VALIDATION.md` for the cost bounds, prerequisites,
exact manual command, evidence distinctions, and session stopping point.

## Repository milestones

Latest validated implementation:

- PR #21: realtime response event, text and wire bounds.
- Implementation head: `2bd05fa041a90b74516ab073167a1b092af52ba3`.
- CI and independent source review passed; merge state is recorded in PR #21.

Previous validated and merged implementation:

- PR #20: realtime cancellation and provider startup cleanup.
- Implementation head: `f5f6a76620040bc2d35b4a1b599735177844eb1c`.
- Merged `main`: `807522fcad0838027ba4a239f62975ce89a0f9ff`; post-merge CI passed.

Immediately preceding merged milestone:

- PR #19: **Bounded Calculator execution validation**.
- Merged `main` commit: `5310f7f061bdd2c37981f7c91e610f304970b276`.
- Validated feature/documentation head: `40d390e073749283069886d4a0bac56fc096490e`.
- Both push and PR gates passed: backend, portable core, native macOS tests/builds.
- Native suite: 243 passing tests, including five stitched Calculator safety cases.
- No paid provider call or real Mac launch was performed for PR #19.

Immediately preceding merged milestones:

- PR #18: bounded live OpenAI text canary; successful paid-network commit
  `f1c12c59a21143b8109ca0a127fd41056c2185ba`.
- PR #17: Realtime orchestrator and native Mac control.
- PR #16: canonical Memory → Context Compiler integration.
- PR #15: provider-neutral Supabase authentication foundation.
- PR #14: PostgreSQL canonical Memory Service bridge.

Merged PR #17 provides the first user-visible text/control slice:

- provider-neutral realtime session/event contracts in AgentCore;
- semantic capability layer hiding native executor names from the model;
- realtime coordinator through AgentOrchestrator and DeviceRouter;
- selective authenticated memory compilation for realtime turns;
- real macOS `ui.get_frontmost_app` read path via `computer.inspect`;
- real macOS `app.open` action path via `computer.open_app`;
- trusted local exact single-use approval UI;
- duplicate/replay-safe action handling;
- text-first OpenAI Realtime WebSocket adapter outside AgentCore;
- backend-issued short-lived Realtime credential path using our opaque agent session;
- Keychain-authenticated Mac Realtime credential client;
- menu-bar text-agent UI.

Merged PR #18 adds the bounded live-provider validation infrastructure:

- standalone `RealtimeLiveCanary` executable using the production Swift provider/transport;
- opt-in-only GitHub Actions paid canary workflow;
- compile-only canary validation in normal macOS CI;
- successful one-turn real OpenAI Realtime network validation;
- audited credential-safe live logs;
- updated master/realtime/canary documentation.

Post-merge `main` at `b41ac966780f3c5f5cbe18703f80a16e062404e3` passed:

- [x] Backend isolation — embedded PostgreSQL.
- [x] Backend isolation — native PostgreSQL.
- [x] Portable AgentCore.
- [x] Offline live-canary harness.
- [x] macOS AgentCore/MacRuntime compile and tests.
- [x] Compile-only `RealtimeLiveCanary` build with no provider network call.
- [x] Native macOS `.app` bundle build and verification.
- [x] Paid canary did not rerun on the ordinary merge push.

## Live Realtime validation milestone — MERGED + PASSED

Merged through PR #18.

Successful paid-network canary commit:

`f1c12c59a21143b8109ca0a127fd41056c2185ba`

GitHub Actions run:

`36239995353` — `Realtime live canary` run #3

Validated live behavior:

- [x] GitHub Actions `OPENAI_API_KEY` secret gate passed.
- [x] Standard server-side OpenAI key successfully minted one short-lived Realtime credential.
- [x] Production Swift `OpenAIRealtimeProvider` used the real native WebSocket transport.
- [x] Realtime `session.created` handshake path completed.
- [x] Exactly one bounded text-only turn completed on the real provider network.
- [x] Normalized result contained `REALTIME_LIVE_CANARY_OK`.
- [x] No Mac tool/action was exposed or executed by this canary.
- [x] No automatic retry occurred.
- [x] Long-lived API key was masked as `***` in the audited job logs.
- [x] No short-lived credential appeared in the audited job logs.

The first guarded attempt had stopped before any OpenAI request because the secret was absent; after the repository secret was configured, the single bounded rerun passed.

Details: `docs/REALTIME_LIVE_CANARY.md`.

Still **not** claimed by this checkpoint:

- live model function/tool execution through local approval;
- automatic provider transport reconnect/resume hardening;
- voice/audio UX;
- production Supabase configuration/login UX;
- production backend/cloud deployment;
- shipping Mac Keychain session → deployed backend → OpenAI credential path;
- broader Mac click/type/file/process/shell/screen tool surface.

## Authentication foundation

External authentication is provider-neutral. Supabase Auth is the initial verifier adapter, not the canonical identity system.

```text
Supabase Auth
    ↓ verifies external user
(provider, issuer, subject)
    ↓
Isolated Agent Auth Service
    ↓
Stable internal tenant_id / user_id
    ↓
Opaque short-lived agent session
    ↓
Memory / Context / Jobs / Devices / Approvals / Realtime credential broker
```

Implemented:

- [x] External identity mapping `(provider, issuer, subject) -> internal principal`.
- [x] Stable internal tenant/user identity independent of Supabase IDs.
- [x] Concurrent first-login serialization.
- [x] Production auth role cannot choose arbitrary internal principal IDs.
- [x] `/v1/auth/exchange` verifies an external token and mints our opaque session.
- [x] `/v1/auth/logout` revokes our opaque session.
- [x] Downstream memory APIs consume our opaque session, not Supabase JWTs.
- [x] macOS stores our opaque session in Keychain.
- [x] External provider access token is not persisted by the Mac exchange layer.
- [x] Runtime/writer DB roles cannot invoke session issuance.
- [x] Repeated-login, concurrent-login, isolation, revocation, HTTP exchange/logout, and privilege-regression tests.
- [x] Realtime credential endpoint derives principal from the opaque agent session.
- [x] Invalid/expired/revoked Realtime sessions fail before the upstream model provider is called.

Still open:

- [ ] Production Supabase project configuration.
- [ ] Live end-to-end Supabase login.
- [ ] Consumer login/signup UI.
- [ ] Google/Apple login UI.
- [ ] Password recovery.
- [ ] MFA/passkeys.
- [ ] Account/provider linking UX.
- [ ] Production reverse-proxy/rate-limit deployment.

Details: `docs/AUTHENTICATION.md`.

## Canonical memory persistence

The provider is not the source of truth.

```text
MemoryService
    ↓
RemoteMemoryServiceLedger
    ↓
MemoryLedgerState
    ↓ PortableMemoryExport v3
CanonicalMemorySnapshotStore
    ↓ CAS
HTTPMemorySnapshotStore
    ↓ authenticated request
PostgreSQL
    ↓
agent_canonical.snapshots + FORCE RLS
```

Implemented:

- [x] Stable canonical IDs.
- [x] Source + derived provenance.
- [x] Supersession/history.
- [x] Deletion families and tombstones.
- [x] Provider-ID mappings.
- [x] Provider synchronization inventory/revision-fenced work.
- [x] Portable v3 snapshot/export.
- [x] PostgreSQL durable canonical persistence.
- [x] FORCE RLS exact-principal isolation.
- [x] Embedded foreign identity rejection.
- [x] CAS concurrency and bounded retry.
- [x] Restart/deletion persistence tests.
- [x] Authenticated macOS snapshot transport using Keychain session.

Details: `docs/POSTGRES_MEMORY_BRIDGE.md`.

## Memory → Context Compiler milestone — COMPLETE

Merged through PR #16.

Target path:

```text
Authenticated Agent Session
        ↓
TenantContext
        ↓
Agent Orchestrator
        ↓
Context Compiler
        ↓
Selective MemoryContextQuery
        ↓
Memory Service
        ↓
Canonical active memories
        ↓
ContextItem(trust = memory, provenance preserved)
        ↓
Role-appropriate compiled model context
```

Completed guarantees:

- [x] Provider-neutral memory retrieval boundary.
- [x] Exact `TenantContext` required on memory retrieval.
- [x] Model-facing query cannot choose authoritative tenant/user/account identity.
- [x] Only active canonical memories are eligible.
- [x] Deleted/superseded memories are excluded.
- [x] Project/workspace/user scope is enforced before exposure to compiler.
- [x] Canonical ID/provenance/timestamps survive conversion.
- [x] Memory is classified as `memory`, never as instruction/authority.
- [x] Result count and byte budgets are enforced.
- [x] Memory retrieval is explicit opt-in.
- [x] Bounded/Jev-style decisions remain memory-free.
- [x] Reasoning/realtime compilation can receive selected memory within policy budgets.
- [x] Context Compiler trust labels are preserved.
- [x] Orchestrator uses Memory Service boundary, never Supermemory directly.
- [x] Retrieval failure degrades to no-memory context without changing identity/authorization.
- [x] Cross-tenant and adversarial memory tests are present.
- [x] Prompt-injection-shaped memory remains untrusted data.
- [x] Orchestrator exposes the authenticated model-context compilation boundary.
- [x] Exact feature head and merged `main` passed all required CI.
- [x] Realtime-specific test proves opt-in memory is retrieved under trusted `TenantContext` and remains `trust = memory`.

---

# 1. Product identity

The product is a **personal agent platform**, not a Meta-glasses-only application.

Long-term shape:

```text
Meta Glasses / Phone / Desktop / Future Interfaces
                    ↓
             Realtime Session
                    ↓
             Agent Orchestrator
                    ↓
          Model + Context Routing
                    ↓
               Tool Router
                    ↓
             Device Executors
                    ↓
      Mac / Windows / Linux / Android
```

One internal agent identity should span authorized interfaces and devices.

Required future modes:

- phone only;
- phone + computer;
- direct desktop;
- glasses through a phone companion when platform APIs permit it.

Checklist:

- [ ] First-class multi-interface adapter contract beyond the desktop/realtime provider boundary.
- [ ] One agent identity proven across at least two real user interfaces.
- [ ] Cross-interface session continuation.
- [ ] Cross-interface job visibility.
- [x] Interface/session identifiers carried in the trusted desktop invocation path.
- [x] Explicit-device instruction override is enforced in the realtime orchestrator path.
- [x] Trusted local active-device resolution exists for the first Mac slice.
- [x] Provider-neutral external-auth foundation.
- [x] Opaque internal agent-session foundation.

---

# 2. Interface layer vs device executor layer

An **interface** is where the user communicates with the agent.  
A **device executor** is where capabilities execute.

The desktop app implements both roles for the first local slice.

Potential Mac executor tools:

```text
app.open
ui.get_frontmost_app
ui.get_windows
ui.get_tree
ui.click
ui.type
file.read
file.write
process.list
shell.run
screen.capture
```

All execution remains subject to OS permissions, deterministic policy, approvals, risk handling, device/session identity, and audit logging.

Checklist:

- [ ] Mobile interface client.
- [x] Desktop text conversational interface client foundation.
- [ ] Desktop voice interface.
- [ ] Mobile executor boundary.
- [x] Native macOS executor/runtime boundary foundation.
- [x] Desktop interface → orchestrator → local Mac executor proven for first read/action slice.
- [ ] Windows executor — deferred.
- [ ] Future glasses companion boundary.

---

# 3. The orchestrator is the agent

Central rule:

> **The orchestrator is the agent. Models are components used by the orchestrator.**

The realtime model is not the authority for permissions, approvals, device identity, tenant identity, tool authorization, or OS-native execution.

Realtime model responsibilities:

- speech/text interaction;
- turn-taking;
- intent interpretation;
- clarification;
- conversational continuity;
- presentation of results;
- structured handoff of user goals/tool intents.

Orchestrator responsibilities:

- authenticated invocation identity;
- model-context compilation;
- session/task state;
- device resolution;
- capability selection;
- tool routing;
- workflow progression;
- approval integration;
- decision escalation;
- stopping conditions;
- correlation IDs;
- observability;
- Context Service;
- Memory Service;
- model/provider routing.

Existing foundation:

- [x] Provider-neutral decision provider.
- [x] Deterministic-rule-first decision engine.
- [x] Reasoning fallback abstraction.
- [x] Provider-neutral AgentOrchestrator.
- [x] Capability-based device routing.
- [x] Exact single-use approvals.
- [x] Context Compiler integration.
- [x] Selective Memory → Context integration.
- [x] Provider-neutral realtime session/provider contract integrated with orchestrator.
- [x] Real Mac read/action executor capabilities invoked through orchestrator.
- [x] Production OpenAI Realtime text adapter exercised on a bounded real network canary.

---

# 4. Realtime AI → Orchestrator → Mac Executor — FIRST TEXT SLICE MERGED + LIVE TEXT CANARY PASSED

Merged implementation:

- PR #17
- feature head `dc46ad1179c06eced8b7cab7292377eec60715bd`
- merge commit `8496fd7ef707653c71224ec18bd6ef2483a63cfb`

Live-provider validation:

- PR #18 merged into `main` at `b41ac966780f3c5f5cbe18703f80a16e062404e3`
- canary branch `core/realtime-live-canary`
- successful canary commit `f1c12c59a21143b8109ca0a127fd41056c2185ba`
- Actions run `36239995353`

Target/implemented flow:

```text
Mac text interface
        ↓
RealtimeModelSession
        ↓
provider adapter
        ↓ structured user/model events
RealtimeCoordinator
        ↓
Agent Orchestrator
        ↓
Context Compiler + selective Memory
        ↓
semantic capability intent
        ↓
Device Router
        ↓
prepare exact native operation
        ↓
Policy + local approval when required
        ↓
Mac Executor
        ↓
typed semantic tool result
        ↓
Realtime session
        ↓
assistant response
```

## Architecture decisions retained

### Provider neutrality

- [x] AgentCore does not import provider-specific event types.
- [x] Orchestrator does not know OpenAI WebSocket/event names.
- [x] Provider-specific session/auth handling stays in MacRuntime adapter code.
- [x] Semantic/native tool contracts remain provider replaceable.

### Realtime model is not a direct tool executor

Every native action remains:

```text
authenticated invocation
→ semantic capability validation
→ orchestrator prepare
→ trusted device routing
→ risk/approval
→ executor
→ audit/result
```

The model cannot mint approval, lower action risk, choose another tenant, or call native Mac APIs directly.

### Mac-first scope

Windows remains deferred. The first real executor slice is macOS only.

### Text/control before voice

Text/control correctness is implemented, deterministically tested, and the provider text-network boundary has now been validated live. Voice/audio remains a later layer over the same provider-neutral session/orchestration boundary.

## Realtime session layer

- [x] Provider-neutral `RealtimeModelProvider` / `RealtimeModelSession` contract.
- [x] Typed input/output events independent of vendor wire format.
- [x] Stable provider session + turn/event correlation IDs.
- [x] Trusted interface/session/device context remains outside model payload authority.
- [x] User text input in deterministic harness and Mac UI.
- [ ] Audio input/output event boundaries — deferred to voice milestone.
- [x] Assistant text events.
- [x] Structured semantic tool-intent events.
- [x] Structured typed tool-result return.
- [x] Cancellation forwarding.
- [x] Event text/tool-argument/tool-count/capability bounds.
- [x] Provider event cannot authoritatively set tenant/user/account identity.

## Orchestrator loop

- [x] Realtime tool requests enter through AgentOrchestrator, not directly through MacRuntime.
- [x] Role-appropriate realtime context compiles through ContextCompiler.
- [x] Relevant long-term memory can be explicitly requested for realtime context.
- [x] Bounded decision provider remains minimal/memory-free.
- [x] Semantic intent is validated against locally registered capability mappings.
- [x] Unknown/unadvertised capabilities fail closed.
- [x] Explicit trusted device selection wins.
- [x] Default local-device routing uses trusted session state, not model claims.
- [x] Typed result/error returns to the provider session.
- [x] Turn/event/request correlation IDs are preserved through the orchestration/result path.

## Mac executor: first completed vertical slice

Read:

- [x] `ui.get_frontmost_app` via semantic `computer.inspect`.
- [ ] `ui.get_windows` / bounded window inventory.
- [ ] `process.list` bounded output.
- [ ] `file.read` path/size policy.

Action:

- [x] `app.open` via semantic `computer.open_app`.
- [ ] `ui.click`.
- [ ] `ui.type`.
- [ ] `shell.run`.

The first slice intentionally proves depth before adding a broad shallow tool catalog.

## Native security requirements

- [x] Accessibility permission checks remain explicit.
- [x] Current inspect/open-app deterministic tests require no microphone/camera permission.
- [x] Non-read action preserves exact single-use approval semantics.
- [x] Tool name + canonical arguments + device + session are frozen before approval/execution.
- [x] Approval replay is rejected.
- [x] Native/provider errors used by the current slice are sanitized before model/user context.
- [x] Existing audit boundary remains in the ToolRuntime execution path.
- [ ] Screen-recording policy for future pixel tools.
- [ ] Shell/process command/timeout/output bounds — tool not implemented yet.
- [ ] File path/size policy — tool not implemented yet.

## OpenAI Realtime adapter

Provider-specific implementation lives outside AgentCore.

- [x] Native WebSocket transport.
- [x] Trusted bearer credential closure.
- [x] `session.created` handshake gate.
- [x] Text request/response translation.
- [x] Provider-safe function-name mapping for semantic capability names.
- [x] Function-call arguments → portable semantic intent.
- [x] Typed tool result → provider `function_call_output`.
- [x] Tool-call continuation before final response completion.
- [x] Cancellation translation.
- [x] Provider failure sanitization and response bounds.
- [x] Fake-WebSocket deterministic adapter tests.
- [x] **Bounded live paid OpenAI Realtime text-network canary passed.**
- [ ] Live provider function/tool-call canary through local approval.
- [ ] Automatic reconnect/resume after broken transport.
- [ ] Audio transport/turn UX.

## Short-lived Realtime credential broker

Production credential flow:

```text
Mac Keychain opaque agent session
        ↓
HTTPRealtimeCredentialClient
        ↓
POST /v1/realtime/credential
        ↓
backend agent_api.identity()
        ↓
server-side long-lived OpenAI key
        ↓
short-lived Realtime credential
        ↓
Mac OpenAIRealtimeProvider
```

Implemented:

- [x] Mac does not require or persist the long-lived OpenAI API key.
- [x] Backend derives internal principal from trusted opaque session only.
- [x] Invalid/expired/revoked sessions fail before upstream provider call.
- [x] Server-side provider request is bounded and sanitized.
- [x] Mac credential client uses HTTPS/loopback restrictions, no redirects/cookies/cache and bounded responses/timeouts.
- [x] Current Mac text UI checks Keychain agent session before enabling Send.
- [x] Real OpenAI client-secret mint + short-lived-credential WebSocket text session validated in the bounded CI canary.

Still open:

- [ ] Production backend endpoint deployment/configuration.
- [ ] Consumer login flow that creates the Keychain agent session in the shipping app.
- [ ] Shipping Mac Keychain session → deployed backend credential endpoint → Realtime network validation.

## Deterministic and live tests

- [x] Fake realtime provider drives user turn → semantic intent → orchestrator → executor → typed result → assistant response.
- [x] Provider event cannot choose authenticated principal.
- [x] Trusted realtime memory retrieval uses exact `TenantContext`.
- [x] Model cannot execute an unregistered/unadvertised capability.
- [x] Model cannot self-approve an action.
- [x] Approved native tool/arguments/device/session are immutable across prepare/execute.
- [x] Wrong-device/unadvertised capability fails closed.
- [x] Duplicate provider event does not duplicate committed action.
- [x] Mismatched replay ID fails closed.
- [x] Cancellation forwarding is tested.
- [x] Context/memory trust labels survive realtime compilation.
- [x] Actual MacRuntime read/action tool types are exercised behind the semantic loop.
- [x] Short-lived Realtime credential client/broker error cases are tested.
- [x] Backend embedded + native PostgreSQL gates passed on merged realtime head.
- [x] Portable AgentCore gate passed on merged realtime head.
- [x] Native macOS tests/app bundle passed on merged realtime head.
- [x] One real paid Realtime text-network canary passed on the production Swift adapter.
- [x] Successful live canary logs were audited for credential leakage.
- [x] PR #18 merge commit passed Backend, Portable Core, macOS, offline canary compile, and app-bundle verification on `main`.

## Definition of done for this first text/control slice

The first slice is considered implemented and live-provider text validated because:

1. a user text turn enters a provider-neutral realtime session;
2. the turn is bound to trusted `TenantContext`, session/interface and local device state;
3. the orchestrator compiles allowed context and opt-in memory;
4. a semantic tool intent is validated and resolved locally;
5. real native Mac read + action tool types execute end-to-end in deterministic/native integration tests;
6. write approval remains exact/single-use/replay-safe;
7. typed results return to the realtime session;
8. duplicate provider events cannot repeat a committed action;
9. provider/model payloads have no authority to select another principal;
10. portable/native/backend deterministic CI gates pass;
11. the Mac has a user-visible text interface using the same path;
12. long-lived model-provider credentials remain server-side in the production design;
13. the production Swift OpenAI adapter completed one bounded real text-network canary with short-lived credential minting and secret-safe logs.

This does **not** imply that live function calling, production deployment, reconnect/resume, or voice are complete.

---

# 5. Decision hierarchy and bounded decisions

Intended order:

```text
Can deterministic code decide?
        ↓ yes
     Use code
        ↓ no
Is this a bounded decision among explicit options?
        ↓ yes
Use bounded decision provider
        ↓ unresolved/open-ended
Use reasoning model
```

A bounded provider cannot approve actions, downgrade risk, grant permissions, invent tools, choose another tenant, or bypass deterministic policy.

Checklist:

- [x] Generic decision-provider interface.
- [x] Deterministic priority.
- [x] Reasoning fallback abstraction.
- [ ] Actual Jev adapter.
- [ ] Confidence/escalation tuning.
- [ ] Real workload comparison metrics.

---

# 6. Agent-level capabilities vs executor tools

Models reason primarily in semantic agent-level capabilities; native implementation names remain behind trusted local resolution.

Implemented first slice:

```text
computer.inspect  → ui.get_frontmost_app
computer.open_app → app.open
```

Future semantic examples:

```text
computer.interact
project.inspect
project.run
browser.inspect
browser.navigate
file.find
job.start
job.status
```

Native executor examples:

```text
ui.get_frontmost_app
ui.get_windows
ui.get_tree
ui.click
ui.type
app.open
file.read
process.list
shell.run
screen.capture
```

Checklist:

- [x] Agent-level capability schema for first slice.
- [x] Translation from semantic capability to native executor request.
- [x] Capability narrowing to the selected device per turn.
- [x] OS-specific implementation names stay out of portable provider contracts.
- [ ] Expand semantic capability catalog beyond inspect/open-app.
- [ ] Multi-step semantic capability planning.

---

# 7. Long-running jobs

Realtime interaction must remain responsive while longer work runs independently.

Future job lifecycle:

```text
job.start
job.status
job.result
job.cancel
```

Checklist:

- [ ] Persistent job IDs.
- [ ] Start/status/result/cancel contract.
- [ ] Cross-interface job visibility.
- [ ] User/tenant ownership.
- [ ] Cancellation semantics.
- [ ] Bounded artifact references.
- [ ] Progress events.

---

# 8. Context subsystem

Context is not one giant prompt/history.

Current architecture:

```text
Interfaces / Devices
        ↓
Context Service
        ↓
Agent Orchestrator
        ↓
Context Compiler
        ↓
Relevant context only
        ↓
Realtime / bounded decision / reasoning / jobs
```

Implemented:

- [x] Tenant-bound ContextItem.
- [x] Context Service contract.
- [x] Tenant-partitioned in-memory service.
- [x] Durable file-backed foundation.
- [x] Typed session/interface/device/task state.
- [x] Explicit scopes including project/workspace.
- [x] Freshness metadata.
- [x] Refresh coordinator foundation.
- [x] Context Compiler.
- [x] Model-specific policies.
- [x] Trust-label preservation.
- [x] Memory retrieval/injection with scope/provenance enforcement.
- [x] Realtime coordinator uses the authenticated compiler path.

Still open:

- [ ] Product-level durable cross-interface session context.
- [ ] Full live Mac device/application refresh adapters.
- [ ] Connected-service context through orchestrator.
- [ ] Session summarization.
- [ ] Artifact references.
- [ ] Broader token budgeting.

---

# 9. Context trust and prompt-injection boundary

Context is data unless explicitly trusted as an instruction source.

Trust classes:

```text
user_instruction
system_state
tool_result
external_content
memory
model_generated
```

Implemented:

- [x] Provenance/trust metadata.
- [x] Context Compiler preserves trust.
- [x] Bounded decisions default to curated state and exclude memory by default.
- [x] Memory-shaped prompt injection remains `memory`, not instruction.
- [x] Realtime semantic tool events have no approval/identity authority fields.
- [x] Local approval is issued only after trusted resolution/preparation of the native action.

Still required:

- [ ] End-to-end webpage/email/document prompt-injection tests through a live model path.
- [ ] Live-provider adversarial prompt-injection canary.

---

# 10. Long-term memory strategy

Use provider-neutral memory behind our own service.

```text
Context / Orchestrator
      ↓
Memory Service
      ↓
MemoryProvider
   ├── SupermemoryProvider
   ├── future provider
   └── local/provider-independent
```

Implemented:

- [x] MemoryProvider.
- [x] Memory Service.
- [x] Portable canonical ledger.
- [x] PostgreSQL canonical bridge.
- [x] Provider capability gates.
- [x] Supermemory read-only adapter foundation.
- [x] Revision-fenced mutation coordinator.
- [x] Live-canary harness + offline tests.
- [x] Selective Memory → Context Compiler integration.
- [x] Realtime compilation can consume memory through the same provider-neutral boundary.

Still open:

- [ ] Successful authenticated live Supermemory vendor canary from reachable network.
- [ ] Proven vendor lifecycle/deletion guarantees.
- [ ] Production provider mutations.
- [ ] Provider migration pipeline/dual-write/shadow-read.

A previously supplied chat credential must not be reused as a production secret.

---

# 11. Tenant/user isolation

There must be **no cross-user memory or execution leakage**.

Authoritative identity is derived from authenticated server/runtime state, never model output or request-body identity fields.

Implemented:

- [x] TenantContext.
- [x] Opaque session-derived identity.
- [x] DB FORCE RLS.
- [x] Separate auth/runtime/writer roles.
- [x] Native PostgreSQL isolation CI.
- [x] Remote canonical ledger exact-principal binding.
- [x] Context-store/compiler isolation.
- [x] Memory → Context cross-tenant canaries.
- [x] Backend cache isolation.
- [x] Realtime model tool-intent schema carries no tenant/user/account authority.
- [x] Realtime memory compilation test proves trusted principal is supplied by the invocation path.
- [x] Realtime credential broker derives identity from the opaque authenticated server session.

Still required:

- [ ] Live semantic/tool/provider-backed isolation canary.
- [ ] Tenant-scoped jobs.
- [ ] Tenant-scoped artifacts.
- [ ] Production logging/backup policy.

The successful text-only OpenAI canary did not carry a live tool call and therefore does not close the live semantic/tool isolation item.

---

# 12. Shared scopes

Future explicit sharing may include user, project, workspace, device, and team scopes.

Private remains default.

Checklist:

- [ ] Final shared ACL/principal model.
- [ ] Private-by-default sharing policy.
- [ ] Shared-workspace isolation tests.

---

# 13. Memory never authorizes actions

Memory may influence relevance/preferences, but it never grants authority.

Authorization comes from:

- authenticated identity;
- deterministic policy;
- current trusted user instruction;
- required approval;
- device/OS permissions.

Implemented foundation:

- [x] Memory is compiled with `memory` trust.
- [x] Bounded decision path stays memory-free.
- [x] Cross-tenant memory cannot enter another principal's context.
- [x] Realtime memory is injected only as `memory` context under trusted principal/scope.
- [x] Semantic tool intents cannot include or mint approval grants.
- [x] Native action risk comes from the local ToolDescriptor, not memory/model output.
- [x] Exact native action is frozen before local approval.

Still required:

- [ ] Live-model adversarial canary proving memory/external content cannot socially induce an unintended approval UI flow without current user intent.

---

# 14. Device routing

Rules:

- explicit trusted device reference wins;
- trusted active-device defaults may resolve simple contextual requests;
- ambiguous non-read actions must not be silently guessed;
- high-impact ambiguity should ask;
- capability routing is based on advertised capabilities, not OS assumptions.

Implemented:

- [x] Capability-based DeviceRouter.
- [x] Device/session request binding.
- [x] Unknown-device rejection.
- [x] Unadvertised-capability rejection.
- [x] Deterministic explicit-device path.
- [x] Realtime capability catalog narrows to selected device capabilities.
- [x] Local Mac active-device resolution in the first desktop slice.

Still open:

- [ ] Human-readable aliases.
- [ ] Presence/heartbeat.
- [ ] Multi-device ambiguity UX.
- [ ] Remote-device gateway.

---

# 15. Security and approvals

Existing approval design remains authoritative.

Implemented:

- [x] Exact tool/argument binding.
- [x] Device/session binding.
- [x] Expiry.
- [x] Single-use consumption.
- [x] Replay rejection.
- [x] Default deny-all approval behavior when no trusted provider exists.
- [x] Trusted local Mac `Allow Once` / `Deny` approval UI for realtime actions.
- [x] Realtime action cannot execute without a trusted grant.
- [x] Realtime duplicate event reuses the prior typed result rather than re-executing.
- [x] Mismatched replay fails closed.

Still open:

- [ ] Live provider function-call → local approval → native execution canary.
- [ ] Cross-interface approval UX.
- [ ] Semantic-effect risk escalation beyond native descriptor risk.
- [ ] Remote-device approval handoff.

---

# 16. Data minimization

Third-party providers receive the minimum data required for their role.

Rules:

- bounded decision providers receive explicit state/options/constraints;
- memory provider receives only approved memory data;
- reasoning/realtime providers receive only compiled relevant context;
- secrets and raw provider credentials never enter model context;
- native errors/logs are sanitized.

Implemented:

- [x] Explicit memory-context count/byte budgets.
- [x] Realtime text/tool argument/tool count/capability bounds.
- [x] Provider-facing realtime context omits tenant/user/account identity.
- [x] Native executor names are hidden behind semantic capability mapping.
- [x] Long-lived OpenAI API key remains server-side in the production Realtime credential design.
- [x] Realtime provider/client errors are sanitized for current paths.
- [x] Bounded live OpenAI canary log audit showed the long-lived key masked and no short-lived credential emitted.

Still open:

- [ ] Complete provider-specific minimization matrix for every future provider.
- [ ] General secret-redaction framework across all future tools/logs.
- [ ] Provider request audit metadata policy without raw secrets.
- [ ] Product privacy/retention policy.

---

# 17. Implementation order

Current status:

1. [x] TenantContext + ContextItem.
2. [x] Context Service.
3. [x] Typed session/interface/device/task context.
4. [x] Context Compiler + model-specific policies.
5. [x] Canonical Memory Ledger local + PostgreSQL bridge.
6. [x] MemoryProvider + Memory Service.
7. [~] Supermemory foundation; live lifecycle validation remains open.
8. [~] DB/cache isolation; live semantic/provider isolation remains open.
9. [x] Long-term memory retrieval into Context Compiler.
10. [x] Canonical/local deletion; live provider deletion verification remains open.
11. [x] Portable canonical v3 export.
12. [ ] Provider migration/dual-write/shadow read.
13. [ ] Shared workspace/ACL when required.
14. [x] **Realtime text session + semantic capability loop + first real Mac read/action slice.**
15. [x] **Bounded live OpenAI Realtime text-network canary.**
16. [ ] Realtime reconnect/resume hardening.
17. [ ] Live provider function/tool-call + local approval canary.
18. [ ] Job Manager.
19. [ ] Broader Mac capability surface (`windows/process/file/click/type/shell/screen`).
20. [ ] Production auth/backend deployment and consumer login UX.
21. [ ] Mobile/desktop interface expansion.
22. [ ] Voice/audio UX.
23. [ ] Future glasses integration.
24. [ ] Windows executor — deferred for current phase.

Security/validation milestones completed:

- [x] Provider-neutral authentication/session foundation.
- [x] Canonical PostgreSQL memory bridge.
- [x] Memory → Context Compiler integration.
- [x] Exact local realtime action approval/replay boundary for first Mac slice.
- [x] Secret-safe bounded real OpenAI Realtime text-network canary.

---

# 18. Definition of done for the overall plan

This document is **not complete** until required architecture items are implemented and tested.

Overall completion requires:

- [ ] all required checklist items are complete or explicitly superseded;
- [ ] cross-tenant isolation is proven through every production retrieval/execution path;
- [ ] provider replacement can occur without losing canonical memory;
- [ ] deletion cannot resurrect data through provider/migration/cache/index;
- [ ] context compilation remains selective/freshness/provenance aware across production paths;
- [ ] realtime, bounded, and reasoning models receive role-appropriate context;
- [ ] memory never becomes instruction/authority;
- [ ] one agent session can continue across desktop and mobile;
- [ ] jobs can be started on one interface and observed from another;
- [ ] phone-only mode works;
- [ ] direct desktop mode works with production auth/backend/model configuration;
- [ ] glasses act as another interface to the same agent;
- [ ] approval/security boundaries cannot be bypassed by models, memory, or external content;
- [ ] provider-specific dependencies remain replaceable;
- [ ] production identity/storage/runtime deployment is operationally hardened.

When all required items are truly implemented and verified, change the status at the top to:

```text
Status: DONE
```

Until then, this file remains the active architecture and implementation checklist.

---

# Dedicated implementation documents

- `docs/AUTHENTICATION.md` — external identity, internal principal mapping, opaque sessions, Keychain boundary.
- `docs/POSTGRES_MEMORY_BRIDGE.md` — PostgreSQL canonical v3 persistence and Swift remote ledger.
- `docs/MEMORY_LEDGER.md` — canonical memory semantics.
- `docs/MEMORY_SERVICE.md` — provider-neutral Memory Service.
- `docs/MEMORY_WRITE_SAFETY.md` — revision fencing, mutation journal, deletion safety.
- `docs/SUPERMEMORY_ADAPTER.md` — Supermemory adapter contract/capabilities.
- `docs/SUPERMEMORY_LIVE_VALIDATION.md` — bounded live-canary procedure.
- `docs/VALIDATION.md` — repository validation expectations/history.
- `docs/REALTIME_ORCHESTRATOR_MAC_CONTROL.md` — merged deterministic text-control milestone, live text-provider validation, and remaining tool/voice/deployment hardening.
- `docs/REALTIME_LIVE_CANARY.md` — bounded real OpenAI Realtime text-network canary procedure and successful validation record.
