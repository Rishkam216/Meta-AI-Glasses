# Realtime AI → Agent Orchestrator → Mac Executor

Status: **FIRST TEXT/CONTROL SLICE MERGED; LIVE OPENAI TEXT CANARY PASSED**  
Original implementation branch: `core/realtime-orchestrator-mac-control`  
Merged through: PR #17  
Merged `main`: `8496fd7ef707653c71224ec18bd6ef2483a63cfb`  
Validated feature head: `dc46ad1179c06eced8b7cab7292377eec60715bd`  
Live-canary branch: `core/realtime-live-canary`  
Successful live-canary commit: `f1c12c59a21143b8109ca0a127fd41056c2185ba`  
Implementation/live checkpoint: 2026-09-26

This document records the first user-visible conversational Mac-control slice and its first real OpenAI Realtime text-network validation. The master architecture remains `docs/FINALIZED_PRODUCT_CONTEXT_MEMORY_PLAN.md`.

The milestone remains deliberately text/control-first. Voice/audio UX, automatic reconnect/resume, live function/tool execution, and production cloud deployment are **not** claimed as complete.

---

## 1. Implemented end-to-end shape

```text
Mac text interface
        ↓
provider-neutral RealtimeModelSession
        ↓
OpenAI Realtime adapter (MacRuntime only)
        ↓
RealtimeCoordinator
        ↓
AgentOrchestrator
        ↓
ContextCompiler + opt-in MemoryContextQuery
        ↓
semantic capability intent
        ↓
DeviceRouter
        ↓
prepare exact native operation
        ↓
local approval when non-read
        ↓
MacRuntime executor
        ↓
typed semantic tool result
        ↓
Realtime session
        ↓
assistant text
```

The model never becomes the security authority. Tenant identity, trusted device/session state, registered native tools, risk classification, approval issuance, OS permission checks, and native execution remain local/trusted responsibilities.

---

## 2. Provider-neutral realtime contracts — COMPLETE

AgentCore contains provider-neutral realtime contracts and does not import OpenAI wire types.

Implemented portable concepts include:

- bounded user text turns;
- stable turn/event correlation IDs;
- assistant text events;
- semantic tool-intent events;
- typed tool-result events;
- turn completion/failure;
- session cancellation/close;
- provider/session abstraction;
- bounded tool arguments and per-turn tool-call count.

Authoritative tenant/user/account identity is intentionally absent from model-controlled tool intents.

---

## 3. Realtime coordinator — COMPLETE FOR FIRST SLICE

`RealtimeCoordinator`:

1. receives trusted `AgentInvocationContext`;
2. derives the trusted device from explicit application state or the active session device;
3. compiles realtime context through `ContextCompiler`;
4. optionally requests long-term memory only through `MemoryContextQuery`;
5. advertises only semantic capabilities that the selected device can actually satisfy;
6. validates provider tool intents against the semantic registry;
7. resolves semantic capabilities to native executor tools locally;
8. freezes the exact native tool, canonical arguments, device, session and request ID before approval;
9. asks a trusted local approval provider only for non-read operations;
10. executes through `AgentOrchestrator`/`DeviceRouter`;
11. returns a typed result under the semantic capability name;
12. rejects/replays duplicate provider events without re-executing a committed action.

Unknown or unadvertised capabilities fail closed before device execution.

---

## 4. Semantic capability layer — COMPLETE FOR FIRST SLICE

The provider sees semantic names, not native macOS implementation names.

Implemented mapping:

```text
computer.inspect
    → ui.get_frontmost_app

computer.open_app
    → app.open
```

Capability schemas are bounded and validated locally. Capability exposure is narrowed to the tools advertised by the trusted selected device.

The provider does **not** see or select raw native names such as `ui.get_frontmost_app` or `app.open`.

Future capability expansion remains separate work.

---

## 5. First native Mac executor slice — COMPLETE

### Read

`ui.get_frontmost_app` executes through the real `FrontmostAppTool` behind semantic `computer.inspect`.

### Action

`app.open` executes through the real `AppOpenTool` behind semantic `computer.open_app`.

`app.open` is classified as a reversible write and therefore requires a fresh trusted approval.

A dedicated native integration test composes the actual MacRuntime tool types with the real realtime coordinator and proves both paths.

Not included in this milestone:

- window inventory;
- process listing;
- file read;
- click/type;
- shell execution;
- screen capture.

Those are the next Mac capability expansion, not silently marked complete here.

---

## 6. Approval and replay boundary — COMPLETE FOR FIRST SLICE

The realtime model cannot mint or carry an approval ID.

For non-read actions:

```text
semantic intent
→ local semantic resolution
→ AgentOrchestrator.prepare
→ immutable native descriptor/arguments/device/session/request ID
→ LocalApprovalBroker
→ exact single-use ApprovalStore grant
→ AgentOrchestrator.execute
```

Validated behavior:

- no approval provider → action does not reach executor;
- user declines → action does not reach executor;
- user allows once → exact prepared operation executes once;
- duplicate provider event → prior result is re-sent without native re-execution;
- mismatched duplicate event ID → fails closed;
- consumed approval is never reused to execute a duplicate action.

The menu-bar app presents a local `Allow Once` / `Deny` dialog showing the resolved native tool and arguments.

A live-model function-call/approval canary has **not** yet been run; the approval path above is deterministically/native-tested.

---

## 7. Context and memory boundary — COMPLETE FOR REALTIME COMPILATION

Realtime turns compile through the existing authenticated Context Compiler path.

Memory remains explicit opt-in. When a trusted application/orchestrator request includes a `MemoryContextQuery`:

- the query cannot choose tenant/user/account identity;
- the compiler calls the configured memory retriever with trusted `TenantContext`;
- project/workspace/user scope is intersected with allowed context scopes before retrieval;
- returned items must belong to the same principal;
- returned memory must retain `origin = memoryService` and `trust = memory`;
- memory cannot overwrite a stored context item with different trust/provenance;
- retrieval failure degrades to no-memory context without changing identity or authorization;
- bounded decisions remain memory-free.

`RealtimeMemoryContextTests` proves the realtime coordinator sends opt-in memory compiled under the trusted principal and preserves the memory trust class.

Memory remains context, never action authority.

---

## 8. OpenAI Realtime adapter — LIVE TEXT NETWORK VALIDATED

Provider-specific code is confined to MacRuntime.

Implemented:

- native `URLSessionWebSocketTask` transport;
- bearer authentication supplied through a trusted credential closure;
- `session.created` handshake gate;
- text user-item creation;
- text response creation;
- provider-safe function-name mapping for semantic capabilities;
- function-call argument translation to portable semantic intents;
- `function_call_output` result return;
- continuation after a tool-call response;
- assistant text deltas;
- completion/failure translation;
- `response.cancel` cancellation;
- provider error sanitization;
- credential/response size validation;
- no API key in AgentCore, model context, test fixtures, or audit output.

Fake-WebSocket tests validate exact translation without network cost.

### Real paid network canary — PASSED

A deliberately bounded real OpenAI Realtime canary passed on 2026-09-26:

- successful commit: `f1c12c59a21143b8109ca0a127fd41056c2185ba`;
- GitHub Actions run: `36239995353` (`Realtime live canary` run #3);
- repository Actions secret gate passed;
- release `RealtimeLiveCanary` executable built successfully;
- one client-secret mint + one WebSocket session + one tiny text turn completed successfully;
- production `OpenAIRealtimeProvider` and `URLSessionOpenAIRealtimeTransport` were exercised;
- normalized success marker `REALTIME_LIVE_CANARY_OK` was returned;
- GitHub masked the long-lived API key as `***`;
- no ephemeral credential appeared in the audited logs;
- no tool/action execution occurred;
- no automatic retry occurred.

Details: `docs/REALTIME_LIVE_CANARY.md`.

### Still not claimed

- automatic reconnect/resume after a broken network transport;
- live provider function/tool calling through local approval;
- audio input/output;
- production deployed Mac → backend → OpenAI credential path.

---

## 9. Production Realtime credential boundary — IMPLEMENTED LOCALLY, DEPLOYMENT OPEN

The production design does not require the Mac app to accept or persist a long-lived OpenAI API key.

Implemented path:

```text
Keychain opaque agent session
        ↓
Mac HTTPRealtimeCredentialClient
        ↓
POST /v1/realtime/credential
        ↓
backend derives principal from opaque session
        ↓
server-side OpenAI API key
        ↓
short-lived Realtime credential
        ↓
Mac OpenAIRealtimeProvider
```

Backend behavior:

- derives identity through the existing authenticated DB session boundary;
- expired/revoked/invalid agent sessions fail as sanitized `401 unauthenticated`;
- long-lived OpenAI key remains server-side;
- provider failure is sanitized to `realtime_unavailable`/bounded errors;
- provider response and credential sizes are bounded;
- a private HMAC-derived safety identifier is generated from authenticated internal identity without exposing raw tenant/user/account IDs.

Mac behavior:

- opaque agent session remains in Keychain;
- short-lived Realtime credential is fetched just in time;
- no standard OpenAI API key is accepted by the current app UI;
- HTTP credential endpoint has HTTPS/loopback rules, no redirects, no cookies/cache, bounded timeouts and response validation.

The menu-bar text UI checks for a valid Keychain agent session before enabling Send.

The successful GitHub canary proved the real OpenAI client-secret/WebSocket text boundary, but it did **not** prove the shipping Mac app against a publicly deployed backend. Production Supabase configuration/login UX and backend deployment remain separate tasks.

---

## 10. User-visible Mac text interface — IMPLEMENTED

The menu-bar app includes `Open Agent…` with:

- a text command field;
- assistant response display;
- persistent provider session while valid;
- authenticated Keychain-session check;
- backend-minted Realtime credential path;
- local approval dialog for non-read actions;
- current tool-call count/status;
- sanitized user-facing errors.

Examples the first slice is designed to handle once production backend/auth configuration is live:

- `What app is active?`
- `Open TextEdit`

This is not yet the polished consumer UX and does not include signup/login screens.

---

## 11. Validation coverage

Portable/core coverage includes:

- text turn through fake realtime session;
- semantic capability routing through AgentOrchestrator;
- unadvertised/unknown capability rejection;
- trusted explicit-device routing;
- duplicate event idempotency;
- mismatched replay rejection;
- typed tool-result return;
- cancellation forwarding;
- payload bounds;
- exact approval behavior;
- trusted-principal realtime memory compilation.

Native Mac coverage includes:

- `AppOpenTool` validation;
- actual `FrontmostAppTool`/`AppOpenTool` types in the semantic realtime loop;
- local approval boundary;
- OpenAI Realtime wire translation with fake WebSocket transport;
- short-lived backend credential client validation;
- native app compile and bundle verification.

Backend coverage includes:

- authenticated short-lived credential mint path;
- invalid/expired/revoked session rejection before OpenAI is called;
- embedded PostgreSQL;
- native PostgreSQL.

Live provider coverage now includes:

- [x] standard-key → Realtime client-secret mint on the real network;
- [x] short-lived credential → production Swift WebSocket adapter;
- [x] real `session.created` gated text session;
- [x] one bounded text response completed successfully;
- [x] clean result/close path;
- [x] job-log secret audit.

The live canary intentionally did not expose any Mac tool to the model.

---

## 12. Milestone completion criteria

- [x] provider-neutral realtime contract exists and is integrated;
- [x] deterministic fake realtime provider drives the real orchestrator path;
- [x] authenticated context/memory compiles for realtime turns;
- [x] model-facing capability schema is bounded/validated;
- [x] tool intent cannot set authoritative principal/device identity;
- [x] at least one native Mac read capability executes end-to-end;
- [x] at least one native Mac action capability executes end-to-end;
- [x] non-read action preserves exact approval binding;
- [x] duplicate/replayed action intent does not execute twice;
- [x] typed tool result returns to realtime session;
- [x] cancellation semantics are tested at the session/coordinator boundary;
- [x] portable + native + backend CI was green on the merged feature head;
- [x] user-visible Mac text interface exists;
- [x] bounded paid OpenAI Realtime text-network canary passed;
- [x] provider credentials remained out of logs/model context in that canary;
- [x] implementation documents distinguish completed vs deferred behavior.

---

## 13. Explicitly deferred / not proven yet

- automatic transport reconnect/resume hardening;
- live provider function/tool execution through the local approval boundary;
- voice/audio-device management;
- polished login/signup UI;
- production Supabase project configuration;
- production backend/cloud deployment;
- end-to-end shipping Mac Keychain session → deployed backend → OpenAI credential path;
- additional Mac tools (`ui.get_windows`, `ui.click`, `ui.type`, `file.read`, `process.list`, `shell.run`, screen capture);
- mobile app;
- Windows executor;
- Meta glasses integration;
- long-running job manager;
- broad browser automation;
- live Supermemory mutation enablement.

These are intentionally separate milestones. They must not be inferred from the completed text-control slice or the successful bounded text-network canary.
