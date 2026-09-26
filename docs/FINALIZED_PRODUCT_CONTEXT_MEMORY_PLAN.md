# Finalized Product, Context, Memory, and Orchestration Plan

Status: **Design locked. Implementation is active. Follow this document unless an explicit later architecture decision supersedes it.**

Originally finalized: 2026-09-23  
Current implementation checkpoint: **2026-09-26**

This document is the master implementation checklist and source of truth for the Personal Agent / Glasses Agent architecture.

Do **not** mark an item `[x]` because a type, interface, mock, placeholder, or partial path exists. Mark an item complete only when the intended behavior is implemented, integrated, and covered by tests appropriate to the layer.

The product is a personal agent platform. The agent is the product; models, interfaces, devices, memory providers, and identity providers are replaceable components around it.

---

# 0. Current implementation checkpoint

## Current `main`

Latest merged milestone:

- PR #16: **Integrate canonical memory into context compilation**.
- Merged `main` commit: `9474e362eab56cd77135eef540f8e1b537d41d3a`.
- Validated feature head: `e93f756daa4d5d71556849718e34e0b7748937af`.

Immediately preceding merged milestones:

- PR #15: provider-neutral Supabase authentication foundation.
- PR #14: PostgreSQL canonical Memory Service bridge.

## Post-merge validation

The exact merged `main` commit for PR #16 is green on all repository CI lanes:

- [x] Backend isolation — embedded PostgreSQL.
- [x] Backend isolation — native PostgreSQL.
- [x] Portable AgentCore.
- [x] Offline Supermemory canary harness.
- [x] macOS AgentCore/MacRuntime compile and tests.
- [x] Native macOS `.app` bundle build and verification.

Historical GitHub Actions billing/runner failures no longer describe the current validation state.

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
Memory / Context / Jobs / Devices / Approvals
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

Target path now exists:

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

- [ ] First-class interface-adapter contract.
- [ ] One agent identity proven across at least two real interfaces.
- [ ] Cross-interface session continuation.
- [ ] Cross-interface job visibility.
- [ ] Interface-origin metadata on every user request.
- [ ] Explicit-device instruction override end-to-end.
- [ ] Trusted active-device resolution.
- [x] Provider-neutral external-auth foundation.
- [x] Opaque internal agent-session foundation.

---

# 2. Interface layer vs device executor layer

An **interface** is where the user communicates with the agent.  
A **device executor** is where capabilities execute.

The desktop app eventually implements both roles.

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
- [ ] Desktop conversational interface client.
- [ ] Mobile executor boundary.
- [x] Native macOS executor/runtime boundary foundation.
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
- [ ] Realtime session/provider adapter integrated with orchestrator — **active milestone**.
- [ ] Real Mac executor capabilities invoked through orchestrator — **active milestone**.

---

# 4. Immediate active milestone: Realtime AI → Orchestrator → Mac Executor

Active branch:

`core/realtime-orchestrator-mac-control`

This milestone is the first user-visible control loop. It must not bypass the architecture already built.

Target flow:

```text
Mac conversational interface
        ↓
RealtimeSession
        ↓
RealtimeModelProvider
        ↓ structured user/model events
Agent Orchestrator
        ↓
Context Compiler + selective Memory
        ↓
Agent-level capability / tool intent
        ↓
Device Router
        ↓
Policy + approval boundary
        ↓
Mac Executor
        ↓
typed tool result
        ↓
Agent Orchestrator
        ↓
RealtimeSession
        ↓
response to user
```

## Architecture decisions

### Provider neutrality

Realtime transport must sit behind a provider-neutral contract.

Initial provider may be OpenAI Realtime, but:

- AgentCore must not import provider-specific event types.
- Orchestrator must not know websocket/event names from a vendor.
- Provider-specific session/auth/audio handling stays in an adapter.
- Future Claude/other realtime or text providers must be replaceable without changing tool/executor contracts.

### Realtime model is not a direct tool executor

The model may propose a structured capability/tool request. It does not call native Mac APIs itself.

Every action must pass through:

```text
authenticated invocation
→ orchestrator
→ device routing
→ policy/risk
→ approval when required
→ executor
→ audit/result
```

### Mac-first scope

Windows remains deferred. This milestone targets the local authenticated Mac runtime first.

### Text/control path before voice polish

The architecture must support realtime voice, but correctness of the event/session/tool loop comes before UI/voice polish. A deterministic text/event harness must be able to test the same orchestrator path without microphone/audio dependencies.

### No model-supplied identity

Tenant/user/account/device authority comes from trusted session/runtime state. Provider/model event payloads cannot choose another principal or silently redirect execution to an unauthorized device.

### No model-supplied approval

Tool intents cannot grant their own approval or lower risk. Existing approval semantics remain authoritative.

## Required implementation behavior

### Realtime session layer

- [ ] Add provider-neutral `RealtimeSession` / `RealtimeModelProvider` contract.
- [ ] Define typed input/output event model independent of vendor wire format.
- [ ] Carry stable session ID, correlation/turn ID, interface origin, and authenticated invocation context.
- [ ] Support user text input in the deterministic harness.
- [ ] Define audio input/output event boundaries without making audio required for core tests.
- [ ] Support assistant text/transcript events.
- [ ] Support structured capability/tool-intent events.
- [ ] Support structured tool-result return to provider/session.
- [ ] Support cancellation/interruption.
- [ ] Bound event payload sizes and reject malformed events.
- [ ] Ensure provider adapter cannot authoritatively set tenant/user/account identity.

### Orchestrator loop

- [ ] Realtime requests enter through AgentOrchestrator, not directly through MacRuntime.
- [ ] Orchestrator compiles role-appropriate context for the turn.
- [ ] Relevant long-term memory may be selectively requested for reasoning/realtime context.
- [ ] Bounded decision provider continues to receive minimal/memory-free context.
- [ ] Structured model tool intent is validated against registered agent capabilities/tools.
- [ ] Unknown/unadvertised tools fail closed.
- [ ] Explicit device selection wins.
- [ ] Default local-device routing uses trusted runtime state, not model claims.
- [ ] Tool execution produces typed result/error back into the session.
- [ ] Every turn/action carries correlation IDs through audit/result path.

### Mac executor: first real capability slice

Implement a small useful vertical slice rather than dozens of shallow tools.

Initial read-only tools:

- [ ] `ui.get_frontmost_app`.
- [ ] `ui.get_windows` or equivalent bounded window inventory.
- [ ] `process.list` with bounded output.
- [ ] `file.read` with path/size policy.

Initial action tools:

- [ ] `app.open`.
- [ ] `ui.click` using accessibility element targeting where possible.
- [ ] `ui.type`.
- [ ] `shell.run` only behind explicit policy/approval and bounded execution constraints.

If an existing tool already implements part of this safely, integrate it instead of creating a parallel implementation.

### Native security requirements

- [ ] Accessibility permission checks remain explicit.
- [ ] Screen-recording permission is requested only for capabilities that require it.
- [ ] No camera/microphone permission is needed for deterministic control-loop tests.
- [ ] Non-read actions preserve existing exact single-use approval semantics.
- [ ] Tool arguments are immutable across approval/execution.
- [ ] Approval cannot be replayed.
- [ ] Shell/process execution has command/timeout/output bounds.
- [ ] File reads are bounded and reject unsafe/unapproved scope when policy requires it.
- [ ] Native executor errors are sanitized before being returned to model context.
- [ ] Audit logs preserve action/result metadata without logging secrets unnecessarily.

### OpenAI Realtime adapter

- [ ] Add provider-specific adapter outside AgentCore.
- [ ] Do not hard-code OpenAI into orchestrator/tool contracts.
- [ ] Secrets come from trusted configuration/Keychain/environment boundary, never model context.
- [ ] Adapter translates provider events into our typed realtime events.
- [ ] Adapter translates tool results back to provider events.
- [ ] Transport disconnect/reconnect does not duplicate committed actions.
- [ ] Interrupted turns cannot replay already-consumed approval grants.
- [ ] Live API testing must be explicitly bounded to avoid unnecessary credit spend.

### Testing

- [ ] Deterministic fake realtime provider drives a full user-turn → tool-intent → orchestrator → Mac executor/fake executor → tool-result → assistant-response loop.
- [ ] Cross-tenant/provider event cannot change authenticated principal.
- [ ] Model cannot execute unregistered capability.
- [ ] Model cannot self-approve an action.
- [ ] Model cannot change immutable arguments after approval.
- [ ] Wrong-device/unadvertised-capability requests fail closed.
- [ ] Duplicate provider event does not duplicate a committed action.
- [ ] Cancellation stops pending execution where safe.
- [ ] Context/memory trust labels survive realtime compilation.
- [ ] Prompt-injection-shaped memory/external content cannot become approval.
- [ ] Portable AgentCore CI passes.
- [ ] Native macOS tests/app bundle pass.
- [ ] Backend CI remains green if backend code is untouched; any backend changes require embedded + native PostgreSQL validation.

## Definition of done

Do **not** mark this milestone complete because a websocket connects or because a model can emit a function call.

It is complete only when:

1. a deterministic user turn enters a provider-neutral realtime session;
2. the turn is bound to authenticated `TenantContext` and trusted interface/device state;
3. the orchestrator compiles allowed context/memory;
4. a structured tool intent is validated and routed through the existing policy/device boundary;
5. at least one real native Mac read capability and one real native Mac action capability execute end-to-end;
6. action approval semantics remain exact, single-use, and replay-safe;
7. typed tool results return to the realtime session;
8. duplicate/replayed provider events do not duplicate committed actions;
9. cross-tenant/device canaries fail closed;
10. portable tests pass;
11. native macOS tests and app bundle pass;
12. exact branch-head CI is green before merge;
13. this source-of-truth and dedicated implementation doc are updated before merge.

After this milestone, expand the Mac capability surface and add voice/audio UX without changing the security/orchestration boundary.

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

Models should reason primarily in semantic agent-level capabilities, while native implementation details remain in device adapters.

Agent-level examples:

```text
computer.inspect
computer.interact
project.inspect
project.run
browser.inspect
browser.navigate
file.find
job.start
job.status
```

Executor examples:

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

- [ ] Agent-level capability schema — active milestone begins this layer.
- [ ] Translation from semantic capability to executor steps.
- [ ] Capability narrowing per turn.
- [ ] Keep OS-specific implementation names out of portable provider contracts.

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

Still open:

- [ ] Product-level durable cross-interface session context.
- [ ] Full live Mac device/application refresh adapters.
- [ ] Connected-service context through orchestrator.
- [ ] Session summarization.
- [ ] Artifact references.
- [ ] Broader token budgeting.

---

# 9. Context trust and prompt-injection boundary

Context is data unless it is explicitly trusted as an instruction source.

Trust classes include:

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

Still required:

- [ ] End-to-end webpage/email/document prompt-injection tests through a live model path.
- [ ] Prove external content cannot grant approval.
- [ ] Prove realtime provider events cannot grant approval.

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

Still open:

- [ ] Successful authenticated live vendor canary from reachable network.
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

Still required:

- [ ] Live semantic/provider-backed isolation.
- [ ] Tenant-scoped jobs.
- [ ] Tenant-scoped artifacts.
- [ ] Production logging/backup policy.
- [ ] Realtime/tool-event cross-tenant isolation — active milestone.

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

Active milestone must prove:

- [ ] Memory cannot approve a Mac action.
- [ ] Memory cannot change tool/device identity.
- [ ] Memory cannot lower action risk.
- [ ] Provider/model event cannot reinterpret memory as approval.

---

# 14. Device routing

Rules:

- explicit device reference wins;
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

Still open:

- [ ] Trusted active-device state end-to-end — active milestone for local Mac.
- [ ] Human-readable aliases.
- [ ] Presence/heartbeat.
- [ ] Multi-device ambiguity UX.

---

# 15. Security and approvals

Existing approval design remains authoritative.

Implemented:

- [x] Exact tool/argument binding.
- [x] Device/session binding.
- [x] Expiry.
- [x] Single-use consumption.
- [x] Replay rejection.
- [x] Default deny-all approvals in current Mac composition root.

Still open:

- [ ] Trusted local approval UI.
- [ ] Cross-interface approval UX.
- [ ] Semantic-effect risk escalation.
- [ ] Correlation across realtime/orchestrator/device/audit — active milestone.
- [ ] End-to-end realtime test proving model cannot bypass approval — active milestone.

---

# 16. Data minimization

Third-party providers receive the minimum data required for their role.

Rules:

- bounded decision providers receive explicit state/options/constraints;
- memory provider receives only approved memory data;
- reasoning/realtime providers receive only compiled relevant context;
- secrets and raw provider credentials never enter model context;
- native errors/logs are sanitized.

Checklist:

- [ ] Provider-specific minimization policy.
- [ ] Secret redaction policy.
- [ ] Provider request audit metadata without raw secrets.
- [ ] Privacy/retention policy.
- [x] Explicit memory-context count/byte budgets.
- [ ] Realtime event/context payload budgets — active milestone.

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
14. [ ] **Realtime session + agent-level capability/tool loop + first real Mac executor slice — current active milestone.**
15. [ ] Job Manager.
16. [ ] Broader Mac capability surface.
17. [ ] Mobile/desktop interface expansion.
18. [ ] Voice/audio polish.
19. [ ] Future glasses integration.
20. [ ] Windows executor — deferred for current phase.

Security milestones already completed:

- [x] Provider-neutral authentication/session foundation.
- [x] Canonical PostgreSQL memory bridge.
- [x] Memory → Context Compiler integration.

---

# 18. Definition of done for the overall plan

This document is **not complete** until required architecture items are implemented and tested.

Overall completion requires:

- [ ] all required checklist items are complete or explicitly superseded;
- [ ] cross-tenant isolation is proven through every production retrieval/execution path;
- [ ] provider replacement can occur without losing canonical memory;
- [ ] deletion cannot resurrect data through provider/migration/cache/index;
- [ ] context compilation remains selective/freshness/provenance aware;
- [ ] realtime, bounded, and reasoning models receive role-appropriate context;
- [ ] memory never becomes instruction/authority;
- [ ] one agent session can continue across desktop and mobile;
- [ ] jobs can be started on one interface and observed from another;
- [ ] phone-only mode works;
- [ ] direct desktop mode works;
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
- `docs/REALTIME_ORCHESTRATOR_MAC_CONTROL.md` — active realtime/orchestrator/Mac-control milestone.
