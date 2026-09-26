# Realtime AI → Agent Orchestrator → Mac Executor

Status: **ACTIVE**  
Branch: `core/realtime-orchestrator-mac-control`  
Started: 2026-09-26

This document is the detailed implementation plan for the first user-visible conversational Mac-control loop.

The master architecture remains `docs/FINALIZED_PRODUCT_CONTEXT_MEMORY_PLAN.md`.

---

## 1. Goal

Build a provider-neutral realtime session that can accept a user turn, compile authenticated context/memory through the Agent Orchestrator, accept a structured model capability/tool intent, route it through existing device/security/approval boundaries, execute a real Mac capability, and return a typed result back to the session.

This is not a websocket-only milestone and not a demo that lets a model call native APIs directly.

Target loop:

```text
User text / future audio
        ↓
RealtimeSession
        ↓
RealtimeModelProvider adapter
        ↓
AgentOrchestrator
        ↓
ContextCompiler + selective Memory
        ↓
validated capability/tool intent
        ↓
DeviceRouter
        ↓
Policy / approval
        ↓
MacRuntime executor
        ↓
typed result
        ↓
AgentOrchestrator
        ↓
RealtimeSession
        ↓
Assistant response
```

---

## 2. Non-negotiable boundaries

### Orchestrator remains the agent

The realtime model handles conversation and structured intent. It is not the security authority and does not own:

- tenant identity;
- user/account identity;
- device authorization;
- tool registration;
- risk classification;
- approval issuance;
- OS permissions;
- native execution.

### Provider neutrality

Portable AgentCore contracts must not import or expose OpenAI-specific event names/types.

The initial provider adapter may target OpenAI Realtime, but the following remain vendor-independent:

- realtime session identity;
- turn/correlation identity;
- user input event;
- assistant response event;
- tool/capability intent;
- tool result;
- interruption/cancellation;
- context handoff.

### Authenticated identity only

Authoritative `TenantContext` and trusted device/session identity come from application/runtime state. Provider/model payloads cannot supply or override them.

### Existing approval semantics remain authoritative

No provider/model event may:

- self-approve;
- mint an approval;
- alter approved arguments;
- replay a consumed approval;
- lower action risk.

### Mac first

Windows remains deferred. The first real executor slice is macOS only.

---

## 3. Phase A — portable realtime contracts

Add to AgentCore:

- `RealtimeSessionID` / typed session identity if useful beyond UUID aliases;
- `RealtimeTurnID` / correlation identity;
- `RealtimeInterfaceOrigin` or reuse trusted interface context type;
- `RealtimeUserInput`;
- `RealtimeAssistantOutput`;
- `RealtimeToolIntent`;
- `RealtimeToolResult`;
- `RealtimeEvent`;
- `RealtimeModelProvider` protocol;
- session lifecycle/cancellation contract.

Requirements:

- bounded text/event payloads;
- no tenant/user/account fields in model-controlled tool intent;
- optional requested device reference is treated as a hint/explicit user-derived request only after orchestrator validation;
- arguments are canonicalized before approval/execution;
- event IDs support idempotency/replay rejection;
- portable fake provider can drive tests without network/audio.

---

## 4. Phase B — orchestrator realtime turn loop

Add an orchestrator entry point that receives:

- trusted `AgentInvocationContext`;
- trusted interface/session state;
- user turn content;
- optional memory query policy derived by application/orchestrator, not by provider identity fields.

The orchestrator must:

1. compile context using `ContextCompiler`;
2. expose only allowed model-facing capabilities;
3. send user turn + compiled context to realtime provider session;
4. validate any returned tool/capability intent;
5. route to device through `DeviceRouter`;
6. apply policy/approval boundary;
7. execute through device executor;
8. return typed result to provider session;
9. continue until assistant response, cancellation, error, or stopping condition.

The bounded decision path remains minimal and memory-free.

---

## 5. Phase C — capability/tool contract

Avoid exposing a large raw native tool registry to the model.

For the first slice, define a small semantic surface sufficient for testing and direct Mac usefulness.

Suggested semantic capabilities:

```text
computer.inspect
computer.open_app
computer.type_text
computer.click
file.read
process.inspect
shell.run
```

Portable capability descriptions must contain:

- capability name;
- description;
- bounded argument schema/validation;
- read/action classification;
- risk/approval requirement metadata;
- required device capability.

Native executor tools remain implementation details.

Unknown capabilities or invalid arguments fail closed before device execution.

---

## 6. Phase D — first native Mac executor slice

Prefer integrating existing MacRuntime tools rather than creating duplicates.

### Read tools

Target initial set:

- `ui.get_frontmost_app`;
- bounded window inventory;
- bounded `process.list`;
- bounded `file.read`.

### Action tools

Target initial set:

- `app.open`;
- `ui.click` using Accessibility element identity/geometry where safely available;
- `ui.type`;
- `shell.run` only with explicit risk/approval and strict timeout/output limits.

At least one real read tool and one real action tool must execute end-to-end before milestone completion.

---

## 7. Native macOS security requirements

- Accessibility permission remains explicit.
- Screen-recording permission is only required for tools that actually need pixels.
- Deterministic text/control tests require no microphone/camera permission.
- Non-read actions use exact single-use approval semantics.
- Approved tool name + immutable canonical arguments + device + session must match execution.
- Replay of consumed approvals fails.
- Shell execution has timeout, output, and process-lifecycle bounds.
- File reads have byte limits and policy/path constraints.
- Native errors are sanitized before entering model context.
- Audit records carry correlation IDs and action/result metadata.
- Secrets are not written into audit logs or model context.

---

## 8. Phase E — OpenAI Realtime adapter

Provider-specific code stays outside AgentCore.

Responsibilities:

- establish provider realtime transport;
- authenticate from trusted local configuration;
- translate provider wire events → portable `RealtimeEvent`;
- translate portable tool results → provider wire events;
- support text first;
- expose audio boundaries for later voice work;
- handle disconnect/reconnect without duplicating committed actions;
- preserve provider event IDs needed for idempotency.

Do not put API keys in source, test fixtures, model context, or logs.

Live API testing is optional until the deterministic loop is green and must be explicitly bounded for cost.

---

## 9. Idempotency and replay safety

Provider transports may retry/replay events. Therefore:

- every tool intent needs a stable provider/event/request ID;
- orchestrator/runtime records completion state for action intents;
- duplicate read requests may be safely re-evaluated only where policy allows;
- duplicate action intents must not execute twice;
- a consumed approval cannot be reused by a duplicate provider event;
- reconnect must resume from known state rather than blindly replaying actions.

---

## 10. Cancellation and interruption

Realtime sessions need explicit cancellation semantics.

Requirements:

- cancellation can stop a pending model turn;
- pending not-yet-started execution can be dropped;
- already-started native operations are cancelled only where the tool supports safe cancellation;
- completed actions are never rolled back implicitly;
- interrupted assistant speech/text does not alter committed tool state;
- cancellation does not make approval reusable.

---

## 11. Context and memory policy

Realtime/reasoning context may include selective memory only through the existing authenticated compiler path.

Rules:

- memory retrieval remains opt-in;
- only active canonical memory is eligible;
- project/workspace/user scope must match;
- memory keeps `memory` trust;
- external content keeps its own lower trust class;
- neither memory nor external content can authorize an action;
- provider-specific system prompts must explain trust labels without reclassifying them.

---

## 12. Testing matrix

### Portable tests

- user turn → fake provider → assistant response;
- user turn → fake provider tool intent → fake device executor → tool result → assistant response;
- invalid/unknown capability rejected;
- malformed args rejected;
- provider event cannot set another principal;
- provider event cannot self-approve;
- memory-shaped prompt injection cannot approve;
- wrong device rejected;
- unadvertised capability rejected;
- duplicate action intent executes once;
- cancellation before execution prevents action;
- tool error returns sanitized failure event;
- context/memory trust labels preserved.

### Native Mac tests

- actual frontmost-app read where deterministic test harness permits;
- app-open action through approval/policy boundary;
- Accessibility permission failure is explicit and sanitized;
- type/click tool argument validation;
- bounded file/process/shell output;
- `.app` bundle still builds and verifies.

### CI gates

Before merge:

- Portable Core green;
- macOS runtime green;
- native app bundle green;
- Backend isolation green if unchanged, and mandatory if backend touched;
- exact branch head green;
- PR-triggered gates green;
- post-merge `main` green.

---

## 13. Milestone completion criteria

This milestone is complete only when all of these are true:

- [ ] provider-neutral realtime contract exists and is integrated;
- [ ] deterministic fake realtime provider drives the real orchestrator path;
- [ ] authenticated context/memory compiles for realtime turns;
- [ ] model-facing capability schema is bounded/validated;
- [ ] tool intent cannot set authoritative principal/device identity;
- [ ] at least one native Mac read capability executes end-to-end;
- [ ] at least one native Mac action capability executes end-to-end;
- [ ] non-read action preserves exact approval binding;
- [ ] duplicate/replayed action intent does not execute twice;
- [ ] typed tool result returns to realtime session;
- [ ] cancellation semantics are tested;
- [ ] portable + native CI is green;
- [ ] master plan and this document are updated with exact completed behavior before merge.

---

## 14. Explicitly deferred from this milestone

- polished login/signup UI;
- full voice UX/audio-device management;
- mobile app;
- Windows executor;
- Meta glasses integration;
- long-running job manager;
- broad browser automation;
- dozens of Mac tools;
- production cloud deployment;
- live Supermemory mutation enablement.

These remain future milestones unless an implementation dependency requires a small foundation earlier.
