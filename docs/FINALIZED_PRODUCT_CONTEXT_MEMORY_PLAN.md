# Finalized Product, Context, Memory, and Orchestration Plan

Status: **Design locked. Implementation is active. Follow this document unless an explicit later architecture decision supersedes it.**

Originally finalized: 2026-09-23  
Current implementation checkpoint: **2026-09-26**

This document is the implementation checklist and source of truth for the Personal Agent / Glasses Agent architecture.

Do **not** mark an item `[x]` because a type, interface, placeholder, mock, or partial path exists. Mark an item complete only when the intended behavior is implemented, integrated, and covered by tests appropriate to the layer.

The purpose of this document is to prevent shallow implementations that technically satisfy a name while missing the intended product behavior, isolation, migration, security, or recovery guarantees.

---

# 0. Current implementation checkpoint

## Current `main`

The authenticated canonical-memory foundation is merged to `main`.

Latest merged authentication milestone:

- PR #15: **Add provider-neutral Supabase authentication foundation**.
- Merged `main` commit: `27d6d24f845cfc47dd22a2d33d7e8b6bc96b6eb4`.
- Authentication foundation head validated before merge: `0f16a872b29e9d14d4e095d9ea9087489097ed98`.

The immediately preceding canonical-memory milestone is also on `main`:

- PR #14: PostgreSQL canonical Memory Service bridge.
- Swift `MemoryService` / `MemoryServiceLedger` remains the semantic authority for canonical memory lifecycle.
- PostgreSQL provides durable authenticated persistence, FORCE RLS, exact-principal isolation, compare-and-swap revisions, and rejection of foreign embedded identities.
- macOS has a bounded authenticated HTTP snapshot transport.

## Post-merge validation state

The exact merged `main` authentication commit was validated after merge by all repository CI lanes:

- [x] Backend isolation — embedded PostgreSQL.
- [x] Backend isolation — native PostgreSQL.
- [x] Portable AgentCore.
- [x] Offline Supermemory canary harness.
- [x] macOS AgentCore/MacRuntime compile and tests.
- [x] Native macOS `.app` bundle build and verification.

The earlier GitHub Actions billing/runner failure notes are historical and no longer describe the current validation state.

## Authentication architecture now implemented

External authentication is provider-neutral at the agent boundary. Supabase Auth is the initial provider adapter, not the canonical identity system.

```text
Supabase Auth
    ↓ verifies external user
(provider, issuer, subject)
    ↓
Isolated Agent Auth Service
    ↓
Our stable tenant_id / user_id
    ↓
Our opaque short-lived agent session
    ↓
Memory / Context / Jobs / Devices / Approvals
```

Implemented guarantees:

- [x] Private external-identity mapping `(provider, issuer, subject) -> internal principal`.
- [x] Stable internal tenant/user identity independent of Supabase identifiers.
- [x] Concurrent first-login serialization so one external identity resolves to one internal principal.
- [x] Production auth role cannot choose arbitrary internal principal IDs.
- [x] `/v1/auth/exchange` verifies the external access token and mints our opaque session.
- [x] `/v1/auth/logout` revokes our opaque session.
- [x] Downstream memory APIs consume our opaque agent session, not a Supabase JWT.
- [x] macOS stores only our opaque agent session in Keychain.
- [x] The Supabase access token is not persisted by the Mac auth-exchange layer.
- [x] Runtime/writer database roles cannot invoke external session issuance.
- [x] Repeated-login, concurrent-login, different-user isolation, revoked-session, HTTP exchange/logout and privilege-regression tests.

Explicitly not complete:

- [ ] Production Supabase project configuration.
- [ ] Live end-to-end Supabase login against production configuration.
- [ ] Consumer email/password login UI.
- [ ] Google/Apple login UI.
- [ ] Password recovery UX.
- [ ] MFA/passkeys.
- [ ] Account/provider linking UX and policy.
- [ ] Refresh-token lifecycle/session-management UI.
- [ ] Production reverse-proxy/rate-limit deployment.

Authentication details live in `docs/AUTHENTICATION.md`.

## Canonical memory persistence now implemented

The provider is not the source of truth. Canonical memory is owned by our provider-independent Swift memory contract and persisted in infrastructure we control.

```text
MemoryService
    ↓
RemoteMemoryServiceLedger
    ↓
MemoryLedgerState
    ↓ validated PortableMemoryExport v3
CanonicalMemorySnapshotStore
    ↓ compare-and-swap
HTTPMemorySnapshotStore
    ↓ authenticated request
PostgreSQL
    ↓
agent_canonical.snapshots + FORCE RLS
```

Implemented guarantees:

- [x] Stable canonical memory IDs.
- [x] Source and derived provenance.
- [x] Supersession/history.
- [x] Deletion families and persistent tombstones.
- [x] Provider-ID mappings retained in canonical state.
- [x] Provider synchronization inventory and revision-fenced work.
- [x] Portable v3 canonical snapshot/export.
- [x] PostgreSQL durable persistence of complete canonical state.
- [x] FORCE RLS exact-principal database isolation.
- [x] Embedded foreign tenant/user/account identity rejection.
- [x] CAS concurrency protection and bounded conflict retry.
- [x] Restart persistence and deletion persistence tests.
- [x] Atomic canonical-memory + provider-work persistence.
- [x] Authenticated macOS transport connected to Keychain-backed agent sessions.

Canonical bridge details live in `docs/POSTGRES_MEMORY_BRIDGE.md`.

## Supermemory state

Supermemory remains a replaceable memory processor/index candidate, not the source of truth.

Implemented:

- [x] Provider-neutral `MemoryProvider` contract.
- [x] Provider-neutral `MemoryService`.
- [x] Read-only Supermemory search/transport foundation.
- [x] Explicit enable/capability gates.
- [x] Namespace/container/scope validation on the adapter boundary.
- [x] Durable revision-fenced mutation coordinator and recovery journal against a lifecycle-contract driver.
- [x] Permanent deletion/revision fences preventing stale local replay/resurrection.
- [x] Opt-in bounded live canary harness.
- [x] Offline canary-harness tests.

Still not claimed:

- [ ] Successful authenticated live vendor canary from a network that can reach the vendor.
- [ ] Proven Supermemory delayed-processing settlement semantics.
- [ ] Proven complete vendor deletion of all derived/replicated copies.
- [ ] Production Supermemory mutations.

A previously supplied chat credential must not be reused as a production secret. Live testing remains bounded and must not burn API credit unnecessarily.

## Immediate next milestone: Memory → Context Compiler

This is the active milestone on branch `core/memory-context-integration`.

The goal is **not** merely to add another interface. The goal is to make long-term memory an actual, tenant-safe, selective input to the existing Context Service / Context Compiler / orchestrator path without allowing memory to become instruction or authority.

Target flow:

```text
Authenticated Agent Session
        ↓
Backend-derived TenantContext
        ↓
Agent Orchestrator
        ↓
Memory retrieval request
        ↓
Memory Service
        ↓
Canonical active memories / optional provider-backed ranking
        ↓
Memory-to-Context adapter
        ↓
ContextItem(trust = memory, provenance preserved)
        ↓
Context Service
        ↓
Context Compiler
        ↓
Role-appropriate model context
```

### Required implementation behavior

- [ ] Add a provider-neutral memory-retrieval boundary consumable by the context/orchestrator layer.
- [ ] Require exact `TenantContext` on every memory retrieval path.
- [ ] The model may supply semantic query/task information, but never authoritative tenant/user/account identity.
- [ ] Retrieve only active canonical memories; deleted and superseded memories must not be injected.
- [ ] Respect memory scope before candidate results are exposed to the compiler.
- [ ] Preserve canonical memory ID, source/derived provenance, trust classification and timestamps in the context representation.
- [ ] Convert memory into context with trust/source classification `memory`; memory is data, never an instruction.
- [ ] Deduplicate canonical memories and cap result count/size before context compilation.
- [ ] Make memory retrieval opt-in/selective according to the target model/context policy; do not inject all memory into every call.
- [ ] Bounded/Jev-style decision context must continue to exclude memory unless an explicit bounded policy allows the exact memory fields required for that decision.
- [ ] Reasoning/realtime context policies may receive relevant memories only within their configured budgets.
- [ ] Preserve Context Compiler trust labels after memory injection.
- [ ] Orchestrator must consume memory through the Memory Service boundary, never by calling Supermemory directly.
- [ ] Memory retrieval failure must fail safely: absence of memory may reduce personalization, but must not bypass authorization or change tenant identity.
- [ ] Deletion/tombstone state must win over stale provider results or cached references.
- [ ] Add deterministic cross-tenant canaries through the complete Memory → Context Compiler path.
- [ ] Add tests proving another principal's canonical memory cannot enter compiled context even with adversarial query text, provider references, or duplicate canonical IDs.
- [ ] Add tests proving memory cannot grant approval, downgrade risk, select another tenant, or become a user instruction.
- [ ] Add tests for superseded/deleted memory exclusion, scope filtering, ordering/deduplication, and bounded result size.
- [ ] Integrate retrieval into the existing orchestrator path used for model-context compilation rather than leaving the adapter unused.
- [ ] Update this document and dedicated implementation documentation with exact completed behavior and validation before merge.

### Definition of done for this milestone

Do **not** mark Memory → Context complete merely because a `MemoryContextRetriever` type exists.

The milestone is complete only when:

1. an authenticated principal can trigger selective long-term-memory retrieval through the orchestrator/context path;
2. canonical memory is resolved under the exact principal before compilation;
3. compiled context contains only allowed, active, scope-matching memories;
4. provenance/trust labels survive compilation;
5. bounded-provider policies remain minimal and fail closed;
6. deletion/supersession prevents stale memory injection;
7. cross-tenant canary tests exercise the end-to-end retrieval-to-compiler path;
8. portable Swift tests pass;
9. native macOS tests/app build pass if native code changes;
10. backend/native PostgreSQL tests pass if backend code changes;
11. the exact branch head passes required GitHub Actions before merge.

After this milestone, the product path returns to:

```text
Realtime AI
    ↓
Agent Orchestrator
    ↓
Context Compiler + Memory
    ↓
Device Router
    ↓
Mac Executor
```

The next user-visible objective remains conversational Mac control. Windows work stays deferred for now.

---

# 1. Product identity

The product is a **personal agent platform**, not a Meta-glasses-only application.

The agent is the product. Interfaces and devices are adapters around that agent.

A user should have one internal agent identity that can eventually be accessed from multiple authorized interfaces and can operate multiple authorized devices and cloud services.

Intended interfaces include:

- iOS app;
- Android app;
- macOS app;
- Windows app;
- Meta glasses through a phone companion when the platform permits it;
- future web interface if useful;
- future interfaces such as earbuds, other glasses, or conversational surfaces.

The same account should preserve:

- agent identity;
- session continuity;
- long-running jobs;
- device inventory;
- approvals;
- context;
- long-term memory;
- connected-service context when relevant.

A task started on one interface should eventually be visible and queryable from another authorized interface.

## Required product modes

### Phone only

A user without glasses and without a connected computer must still have a useful product.

The mobile app should support, where authorized:

- text chat;
- realtime voice;
- camera input;
- connected-service actions and retrieval;
- cloud research;
- cloud browser / cloud work in future;
- file analysis;
- long-running jobs;
- notifications;
- approvals;
- task/job history.

The mobile app must not be treated only as a companion to glasses.

### Phone + computer

The mobile app acts as a remote conversational control surface for connected computers.

```text
Phone
  ↓
Agent Session
  ↓
Orchestrator
  ↓
Device Router
  ↓
Mac / Windows Executor
```

The phone should show progress, job state, results and approvals when necessary.

### Direct desktop use

The Mac/Windows app is both:

1. a first-class agent interface; and
2. a local device executor.

A user sitting at their computer should not need a phone or glasses.

The desktop app should eventually support text, voice, command/overlay UI, job status, approvals, notifications, local context awareness and local execution.

When a request originates on a desktop, that desktop may become the default active device when the command is contextual and no explicit device was named.

### Glasses

Meta glasses are an optional hands-free interface, not a separate agent product.

```text
Meta Glasses
    ↓
Phone Companion
    ↓
Same Agent Session
    ↓
Same Orchestrator
    ↓
Same Devices / Cloud Services
```

## Implementation checklist

- [ ] First-class interface-adapter contract.
- [ ] One agent identity proven across at least two real interfaces.
- [ ] Cross-interface session continuation.
- [ ] Cross-interface job visibility.
- [ ] Interface-origin metadata on every user request.
- [ ] Explicit-device instructions override defaults end-to-end.
- [ ] Trusted active-device resolution.
- [x] Provider-neutral external-auth boundary and stable internal identity mapping foundation.
- [x] Opaque internal agent-session issuance/revocation foundation.

---

# 2. Interface layer vs device executor layer

An **interface** is where the user communicates with the agent.

A **device executor** is where capabilities execute.

The same app may implement both roles.

## Mobile app

The mobile app should primarily act as interface client, realtime voice/camera surface, approval/notification surface, job viewer, device selector and a limited mobile executor only where platform APIs permit it.

Do not architect the product around arbitrary autonomous control of every iOS or Android app.

## Desktop app

The desktop app should provide an interface role and an executor role.

Potential executor capabilities include:

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

All remain subject to permissions, approval/risk handling and native OS restrictions.

## Implementation checklist

- [ ] Mobile interface client.
- [ ] Desktop conversational interface client.
- [ ] Mobile executor boundary.
- [x] Native macOS executor/runtime boundary foundation.
- [ ] Windows executor boundary — explicitly deferred for current phase.
- [ ] Future glasses companion boundary.

---

# 3. The orchestrator is the agent

Central rule:

> **The orchestrator is the agent. Models are components used by the orchestrator.**

The realtime model must not become the whole agent. The device runtime must not know which model produced a request.

## Realtime model responsibilities

The realtime model should primarily handle speech-to-speech interaction, turn-taking, immediate intent interpretation, clarifying questions, conversational continuity, presentation of results and structured handoff of user goals.

It is not the authority for permissions, approvals, risk enforcement, device identity, tool authorization, OS-native execution or cross-tenant access.

## Orchestrator responsibilities

The orchestrator owns:

- agent session state;
- task state;
- device resolution;
- capability selection;
- workflow progression;
- decision escalation;
- approval integration;
- long-running job delegation;
- stopping conditions;
- correlation IDs;
- observability;
- Context Service interaction;
- Memory Service interaction;
- model/provider routing.

## Existing implementation foundation

- [x] Provider-neutral decision-provider abstraction.
- [x] Deterministic-rule-first decision engine.
- [x] Reasoning fallback abstraction.
- [x] Provider-neutral agent-orchestrator foundation.
- [x] Capability-based device routing foundation.
- [x] Exact single-use approval foundation.
- [x] Context-compiler integration foundation for bounded decisions.
- [ ] Long-term memory retrieval integrated into compiled orchestrator context — active milestone.
- [ ] Realtime model adapter integrated with orchestrator.

These foundations are not completion of the product architecture.

---

# 4. Decision hierarchy and Jev

Intended order:

```text
Can deterministic code decide?
        ↓ yes
     Use code
        ↓ no
Is this a bounded decision among explicit options?
        ↓ yes
Use bounded decision provider (future Jev adapter)
        ↓ low confidence / unresolved / open-ended
Use reasoning model
```

A bounded decision provider is not a conversational model and not a security authority.

It may choose among explicit candidates, but it must not approve actions, downgrade risk, grant permissions, invent tool names, choose outside explicit options, bypass deterministic policy or become the source of tenant identity.

## Implementation checklist

- [x] Generic decision-provider interface.
- [x] Deterministic-rule priority.
- [x] Reasoning fallback abstraction.
- [ ] Actual Jev provider adapter.
- [ ] Confidence/escalation tuning on real workloads.
- [ ] Metrics comparing bounded-provider vs reasoning-provider decisions.

---

# 5. Agent-level capabilities vs executor-level tools

Do not expose hundreds of low-level OS-specific tools directly to conversational models.

Use two layers.

## Agent-level capabilities

Examples:

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

## Executor-level tools

Examples:

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
```

Models should reason primarily in terms of semantic agent-level capabilities. The orchestrator translates these into executor-level actions. OS-specific implementation names remain inside device adapters.

## Implementation checklist

- [ ] Agent-level capability schema.
- [ ] Translation layer from semantic capability to executor steps.
- [ ] Capability narrowing so models see only relevant capabilities.
- [ ] No OS-specific implementation names in model-facing contracts.

---

# 6. Long-running jobs

Realtime interaction must remain responsive while longer work runs independently.

Examples include repository analysis, coding, debugging, builds, research, browser crawls and extended data analysis.

```text
Realtime Session
      ↓
Orchestrator
   ├── immediate action path
   └── Job Manager
           ↓
        Workers
```

Jobs should have persistent IDs and lifecycle operations such as `job.start`, `job.status`, `job.result`, and `job.cancel`.

## Implementation checklist

- [ ] Job model with persistent ID.
- [ ] Start/status/result/cancel contract.
- [ ] Cross-interface job visibility.
- [ ] Job-to-session relationship.
- [ ] Job-to-user/tenant ownership enforcement.
- [ ] Cancellation semantics.
- [ ] Bounded output/artifact references.
- [ ] Progress events suitable for mobile/desktop notifications.

---

# 7. Context is a first-class subsystem

Do not treat context as one giant prompt or one giant conversation history.

The system may store rich context, but each model call should receive only the smallest relevant context required for its task.

The Context Service is separate from long-term memory.

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

## Context layers

### User context

Long-lived user-level information such as preferred language, usual devices, recurring workflows, project aliases and preferences. Retrieve selectively.

### Session context

Current interaction state such as session ID, recent conversation, goal, task, pending approval, active jobs and latest relevant result.

### Interface context

Where the request originated: `mac_desktop`, `windows_desktop`, `ios_app`, `android_app`, `meta_glasses_via_phone`, `web`, etc. This informs defaults but never overrides explicit user instructions.

### Device context

Live/near-live device state such as device ID, presence, capabilities, frontmost app, focused window, active project, working directory, running jobs, selected file and browser tab.

Detailed UI trees/screenshots/heavy state should be collected on demand, not continuously uploaded by default.

### Task/job context

Task context is structured separately from conversation and should contain compact goal/known-state/actions/next-candidates information.

### Application context

Prefer structured app/browser integrations, then Accessibility/UI Automation, then vision, then coordinates.

### Long-term memory

Persistent facts/preferences belong in Memory Service and are retrieved into context only when relevant.

### Connected-service context

Gmail, Calendar, Drive, GitHub, Slack and similar systems should be retrieved only when needed by the task. Never dump an entire service account into model context by default.

## Implementation checklist

- [x] Tenant-bound ContextItem schema.
- [x] Context Service contract.
- [x] Tenant-partitioned in-memory Context Service.
- [x] Durable file-backed Context Service foundation.
- [x] Typed session/interface/device/task state contracts and validation.
- [x] Explicit context scopes.
- [x] Stale-context refresh coordinator foundation.
- [ ] Product-level durable cross-interface session context.
- [ ] Live device/application refresh adapters for the full Mac executor surface.
- [ ] Application-context adapter contract integrated with real apps.
- [ ] Connected-service context retrieval boundary integrated with orchestrator.
- [ ] Long-term Memory Service retrieval integrated into Context Service/Compiler — active milestone.

---

# 8. Context Compiler

The Context Compiler builds actual model input from the larger context store.

Different model types receive different context.

## Realtime model should generally receive

- recent conversation;
- compact session summary;
- current goal/task;
- latest relevant tool result;
- basic active-device state;
- only the context required for a natural response.

## Bounded/Jev-style provider should receive

- highly structured state;
- explicit options;
- constraints;
- minimal facts necessary to choose.

Do not send unnecessary conversation history, private files, raw logs or broad long-term memory to a bounded decision provider.

## Reasoning model may receive

- current goal;
- task history;
- relevant file/log excerpts;
- relevant tool results;
- selectively retrieved memories;
- relevant connected-service data;
- available agent-level capabilities.

## Context compression and artifacts

Older history should be summarized. Large data should remain outside model context whenever possible and be represented through bounded artifact references.

## Implementation checklist

- [x] Context Compiler.
- [x] Model-specific context policies.
- [x] Trust-label preservation.
- [x] Compiler tenant-isolation tests.
- [ ] Long-term memory retrieval/injection with trust/provenance preservation — active milestone.
- [ ] Session summarization.
- [ ] Artifact reference model.
- [ ] Bounded artifact reads.
- [ ] Context token/size budgeting beyond per-source caps.

---

# 9. Context freshness

Context items must carry freshness metadata because live computer state becomes stale quickly.

Each context item should carry source, observed time, device ID where relevant and freshness class.

Suggested classes:

- ephemeral — seconds/minutes;
- session — minutes/hours;
- project — days/months;
- long-term — months/years until superseded.

The orchestrator/compiler should refresh stale ephemeral context rather than trust it blindly.

## Implementation checklist

- [x] Freshness metadata on context items.
- [x] Expiry/staleness policy.
- [x] Refresh-coordinator/adaptor foundation with bounded refresh behavior.
- [ ] Complete live automatic refresh coverage for real Mac application/device sources.

---

# 10. Context trust and prompt-injection boundaries

Context is not equivalent to instruction.

A webpage, email, document, terminal output, memory or model-generated summary may contain adversarial instructions.

Every context item must preserve a trust/source classification such as:

```text
user_instruction
system_state
tool_result
external_content
memory
model_generated
```

External content and memory must never become authoritative user instructions merely because they appear in retrieved context.

## Implementation checklist

- [x] Provenance/trust metadata on context.
- [x] Context Compiler preserves trust labels.
- [x] Bounded decision context defaults to curated system/tool state and makes user/memory/external/model-generated context opt-in.
- [ ] Prompt-injection tests using webpage/email/document content across the full model path.
- [ ] End-to-end test that external content cannot grant permissions/approvals.
- [ ] End-to-end test that memory cannot grant permissions/approvals — active milestone coverage.

---

# 11. Long-term memory strategy

Do **not** build a full memory-intelligence engine from scratch initially.

Use a first-class memory provider behind our own interface. Initial candidate: Supermemory. Other providers may include Zep, Mem0, future systems or a local provider.

```text
Context / Orchestrator
      ↓
Memory Service
      ↓
MemoryProvider
   ├── SupermemoryProvider
   ├── future provider
   └── local/provider-independent implementations
```

The orchestrator must never call Supermemory-specific APIs directly.

## Implementation checklist

- [x] MemoryProvider contract.
- [x] Memory Service.
- [x] Provider-independent tests.
- [x] Provider capability reporting.
- [x] Supermemory read-only search/transport foundation with capability gate.
- [x] Durable revision-fenced mutation coordination foundation.
- [x] Bounded live-canary harness and offline harness tests.
- [ ] Successful authenticated canary run with resolved cleanup.
- [ ] Proven live Supermemory lifecycle guarantees for production mutation use.
- [ ] Production Supermemory mutation activation.
- [ ] Memory retrieval integrated into Context Compiler — active milestone.

---

# 12. Our canonical Memory Ledger is the source of truth

The memory provider must **not** become the only place user memory exists.

Provider IDs are mappings, not canonical identity.

Canonical records preserve enough portable information to recreate memory in another provider, including our memory ID, exact tenant/user/account ownership, scope, source type/reference/time, content/fact, creation/update time, supersession, confidence, provenance and future visibility/ACL fields.

Retain source evidence and derived memory when practical.

## Implementation checklist

- [x] Canonical Memory Ledger contract.
- [x] Durable local/offline ledger.
- [x] Durable PostgreSQL-backed canonical persistence through PR #14.
- [x] Stable canonical memory IDs.
- [x] Source provenance.
- [x] Derived-memory provenance.
- [x] Supersession/history model.
- [x] Permanent deletion tombstones.
- [x] Provider-ID mappings durably retained in canonical state.
- [x] Provider synchronization inventory/work retained in canonical state.
- [x] Portable v3 export/snapshot.
- [x] Exact-principal binding and database FORCE RLS.
- [x] CAS conflict handling for concurrent clients.
- [x] Native macOS authenticated canonical snapshot transport.
- [ ] Production cloud deployment/operations for the canonical PostgreSQL service.

---

# 13. Provider migration without memory loss

Changing memory providers must not mean the user's agent forgets everything.

A future migration may use:

```text
Canonical Memory Ledger
       +
Current Provider Export
       ↓
Migration Pipeline
       ↓
New Provider
       ↓
Re-index / re-embed / rebuild graph
       ↓
Shadow comparison
       ↓
Switch reads
```

Safe migration may use dual write, shadow read, then cutover while keeping canonical IDs stable.

Migration tests must verify counts, important facts, history, isolation, deletion preservation, stable canonical IDs and acceptable retrieval quality.

## Implementation checklist

- [ ] Provider migration pipeline.
- [ ] Dual-write provider migration mode.
- [ ] Shadow-read comparison.
- [x] Provider-independent portable canonical snapshot/export format.
- [ ] Migration verification suite.

---

# 14. Forget/delete semantics

User deletion must propagate from the canonical source of truth outward.

```text
MemoryService.forget(...)
        ↓
Canonical Memory Ledger
        ↓
Active provider
        ↓
Indexes / caches / replicas / derived stores
```

Deleted memory must not be resurrected by migration, re-indexing, stale cache or another provider copy.

## Implementation checklist

- [x] Canonical forget/delete operation and deletion-family semantics.
- [x] Local lineage/derivation cleanup and persistent tombstones.
- [x] Restart/reinsertion tests proving deleted IDs cannot reappear locally.
- [x] PostgreSQL canonical deletion/tombstone persistence.
- [x] Durable provider-work deletion fencing/recovery foundation.
- [ ] Proven production provider deletion propagation against a live provider.
- [x] Backend lexical cache invalidation/deletion coordination.
- [ ] Migration verification that deletions remain deleted.
- [ ] End-to-end Memory → Context test proving deleted memory is never compiled — active milestone.

---

# 15. Tenant and user isolation is a security boundary

There must be **no cross-user memory leakage**.

A request authenticated as User A must be technically unable to retrieve User B's private memory even if there is a bug in a prompt, model output, retrieval query, cache key or provider call.

Never use:

```text
Search all memories
      ↓
Filter by user afterwards
```

Authoritative tenant/user/account identity is derived from authenticated server state, never from model output or a request body field.

Isolation must exist at the canonical database, memory provider boundary, retrieval namespace/filter, cache, jobs, files/artifacts, logs, backups and analytics layers.

## Implementation checklist

- [x] TenantContext type/contract.
- [x] Tenant context required by memory APIs.
- [x] PostgreSQL FORCE RLS canonical/backend isolation.
- [x] Opaque session-derived backend identity.
- [x] Separate auth/runtime/writer roles and privilege tests.
- [x] Native PostgreSQL login/concurrency CI gate.
- [x] Complete Swift remote canonical-ledger integration.
- [x] Provider-neutral external-auth foundation with Supabase verifier adapter.
- [ ] Production live identity-provider configuration/enrollment.
- [ ] Proven live provider namespace isolation for production provider reads/writes.
- [ ] Tenant-scoped semantic/vector retrieval implementation.
- [x] Principal/scope/query/limit-partitioned backend lexical cache.
- [ ] Tenant-scoped jobs.
- [ ] Tenant-scoped artifact service.
- [ ] Production safe-logging policy and enforcement.
- [ ] Backup isolation/encryption policy.

---

# 16. Cross-tenant isolation tests

Use deterministic canary secrets and test every supported path.

Examples:

```text
User A: ALPHA-PINEAPPLE-7834
User B: BETA-ZEBRA-9911
```

Authenticated as A, every supported path for B's canary must return nothing, and vice versa.

Run tests across direct retrieval, semantic retrieval, context compilation, summaries, jobs, provider adapters, model prompts, caches, artifacts, exports, deletion, migrations and future shared-workspace logic.

## Implementation checklist

- [x] Deterministic multi-principal backend canary fixtures.
- [x] PostgreSQL/HTTP canary suite across tenant, user, account, absent-account and scope differences.
- [x] Direct backend lexical-search isolation tests.
- [ ] Semantic/provider-backed live-search isolation tests.
- [x] Context-compiler isolation tests for context-store inputs.
- [x] Backend cache isolation, poisoned-ID re-resolution, deletion invalidation, expiry/revocation and bounded eviction tests.
- [x] Cached-candidate query/limit revalidation and auxiliary-table RLS tests.
- [x] Canonical export/tombstone exact-principal isolation tests.
- [ ] End-to-end Memory Service → Context Compiler cross-tenant canary tests — active milestone.
- [ ] Job isolation tests.
- [ ] Migration isolation tests.

---

# 17. Shared memory and future team/workspace scopes

The architecture must allow future explicit sharing without weakening private isolation.

Possible scopes include private user memory, shared workspace memory, project memory, device-scoped context and team-scoped knowledge.

Shared functionality must be explicit. Private memory must never become shared by default.

## Implementation checklist

- [ ] Final scope/visibility model for shared workspaces.
- [ ] ACL/principal model.
- [ ] Private-by-default sharing behavior.
- [ ] Shared-workspace isolation tests.

---

# 18. Memory provider must not authorize actions

Long-term memory may influence relevance and defaults, but it must never grant authority.

A memory like `User normally deploys on Fridays` is not permission to deploy.

Authorization comes from authenticated identity, deterministic policy, current user instruction, required approval and device permissions.

## Implementation checklist

- [ ] End-to-end proof that memory cannot grant approval — active milestone coverage.
- [ ] End-to-end proof that memory cannot change tenant identity — active milestone coverage.
- [ ] End-to-end proof that memory cannot silently downgrade action risk — active milestone coverage.
- [ ] Tests proving remembered preferences do not bypass authorization.

---

# 19. Device routing and context

Multiple devices may exist simultaneously.

Rules:

- explicit device reference wins;
- trusted active-device defaults may resolve simple contextual requests;
- ambiguous non-read actions must not be silently guessed;
- ambiguous high-impact actions should ask the user;
- capability routing is based on advertised capabilities, not OS assumptions.

## Existing foundation

- [x] Capability-based DeviceRouter.
- [x] Device/session request binding.
- [x] Unknown-device rejection.
- [x] Unadvertised-capability rejection.
- [x] Deterministic explicit-device selection path in orchestrator foundation.

## Remaining checklist

- [ ] Trusted active-device state integrated end-to-end.
- [ ] Human-readable device aliases.
- [ ] Device-presence/heartbeat layer.
- [ ] Multi-device ambiguity UX.
- [ ] Rich context-aware device resolution using live device/application state.

---

# 20. Security and approval boundary

The approval design remains authoritative.

Non-read actions require policy/approval handling appropriate to risk.

Approval grants remain bound to exact tool/action, immutable arguments, device and session; short-lived; single-use; and fail-closed.

A model confidence score, bounded-decision provider, memory, webpage text or connected-service content never substitutes for approval.

## Existing foundation

- [x] Exact tool/argument binding.
- [x] Device/session binding.
- [x] Expiry.
- [x] Single-use consumption.
- [x] Replay rejection.
- [x] Default deny-all approvals in current Mac composition root.

## Remaining checklist

- [ ] Trusted local approval UI.
- [ ] Approval UX across phone/desktop where securely permitted.
- [ ] Risk escalation for semantic effects.
- [ ] Audit correlation across orchestrator/device/job layers.
- [ ] Memory-context tests proving approval boundary cannot be bypassed — active milestone coverage.

---

# 21. Data minimization and provider boundaries

Third-party model/memory providers should receive the minimum data needed for their role.

A bounded-decision provider should receive structured state, bounded options and constraints, not whole conversation history or unrelated personal data.

A long-term-memory provider receives only data approved for memory processing.

A reasoning model receives relevant retrieved context, not the user's entire data estate.

## Implementation checklist

- [ ] Provider-specific data-minimization policy.
- [ ] Context redaction/secrets policy.
- [ ] Provider request audit metadata without raw secret logging.
- [ ] Privacy/retention policy integrated with memory/context deletion.
- [ ] Explicit memory-context size/result budgets — active milestone.

---

# 22. Implementation order

Implement incrementally, not as one giant change.

Current status against the original sequence:

1. [x] Context item schema and TenantContext foundation.
2. [x] Context Service boundary and local durable foundation.
3. [x] Typed session/interface/device/task context foundation.
4. [x] Context Compiler and model-specific policies.
5. [x] Canonical Memory Ledger contract + durable local + PostgreSQL bridge.
6. [x] MemoryProvider abstraction + Memory Service.
7. [~] Supermemory adapter foundation implemented; live production lifecycle validation remains open.
8. [~] Database/cache isolation implemented and validated; live provider/semantic isolation remains open.
9. [ ] **Long-term memory retrieval into Context Compiler — current active milestone.**
10. [~] Canonical/local deletion complete; live provider/migration deletion verification remains open.
11. [x] Portable canonical v3 export/snapshot.
12. [ ] Provider migration/dual-write/shadow-read infrastructure.
13. [ ] Shared workspace/ACL scopes when product requirements demand it.
14. [ ] Agent-level capability layer.
15. [ ] Job Manager.
16. [ ] Realtime/model adapter integration.
17. [ ] Mobile/desktop interface expansion.
18. [ ] Future glasses integration.

Additional security milestone completed between steps 8 and 9:

- [x] Provider-neutral authentication/session foundation with initial Supabase verifier adapter and macOS Keychain-backed agent session.

Native macOS tool development continues under the native validation gate. Windows implementation remains deferred during the current Mac-first phase.

---

# 23. Definition of done for this document

This document is **not complete** until all required architecture items are implemented and tested.

Do not mark the document complete merely because the main classes exist.

The plan is done only when:

- [ ] all required checklist items are complete or explicitly superseded by a documented architecture decision;
- [ ] cross-tenant memory isolation is tested end-to-end through every production retrieval/compilation path;
- [ ] memory-provider replacement can be demonstrated without losing canonical user memory;
- [ ] deletion cannot resurrect data through provider, migration, indexing or cache paths;
- [ ] context compilation is selective, freshness-aware and provenance-aware;
- [ ] realtime, bounded-decision and reasoning models receive role-appropriate context;
- [ ] memory is selectively retrieved into context without becoming instruction or authority;
- [ ] one agent session can continue across at least desktop and mobile interfaces;
- [ ] jobs can be started on one interface and observed from another;
- [ ] mobile-only usage works without a desktop or glasses;
- [ ] direct desktop usage works without a phone or glasses;
- [ ] glasses, when supported, act as another interface to the same agent rather than a separate agent;
- [ ] security approvals remain deterministic and cannot be bypassed by models, memory or external content;
- [ ] provider-specific dependencies remain behind replaceable adapters;
- [ ] production identity, canonical storage and runtime deployment boundaries have operational hardening appropriate for release.

When all required items are truly implemented and verified, change the status at the top to:

```text
Status: DONE
```

Until then, this file remains the active architecture and implementation checklist.

---

# Dedicated implementation documents

Use these for exact implementation/security details while this file remains the master checklist:

- `docs/AUTHENTICATION.md` — external identity verification, internal principal mapping, opaque sessions and macOS Keychain boundary.
- `docs/POSTGRES_MEMORY_BRIDGE.md` — PostgreSQL canonical v3 memory persistence and Swift remote ledger bridge.
- `docs/MEMORY_LEDGER.md` — canonical-memory semantics and local durable ledger.
- `docs/MEMORY_SERVICE.md` — provider-neutral Memory Service/provider contract.
- `docs/MEMORY_WRITE_SAFETY.md` — revision fencing, mutation journal and deletion safety.
- `docs/SUPERMEMORY_ADAPTER.md` — Supermemory read-only adapter contract and capability limits.
- `docs/SUPERMEMORY_LIVE_VALIDATION.md` — bounded live-canary procedure and vendor questions.
- `docs/VALIDATION.md` — validation expectations and historical test coverage.
