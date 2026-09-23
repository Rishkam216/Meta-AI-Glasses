# Orchestrator and decision-engine contract

This layer coordinates intent, session context, bounded decisions, and device
routing. It does not implement a model provider, network transport, or native
computer-control capability.

## Separation of responsibilities

```text
Interface / realtime adapter
        ↓
AgentOrchestrator
        ├── DecisionEngine
        │     ├── deterministic DecisionRule
        │     ├── bounded DecisionProvider (future Jev adapter)
        │     └── reasoning DecisionProvider (future GPT/Claude adapter)
        └── DeviceRouter
                ↓
          DeviceExecuting
                ↓
           ToolRuntime
```

Provider SDKs stay outside `AgentCore`. `DecisionProvider` is the only contract
needed for a future Jev or reasoning-model adapter. The decision engine never
executes a tool itself.

## Decision order

1. Validate that the option set is non-empty and contains unique IDs.
2. If there is only one option, choose it deterministically.
3. Evaluate deterministic rules in order.
4. Ask the bounded provider for one of the supplied options.
5. Validate that the provider selected a real option and returned finite 0...1
   confidence/scores.
6. If bounded confidence meets the threshold, accept it.
7. Otherwise use the optional reasoning provider. If none exists, fail closed.

A provider cannot invent an action outside the option set. Decisions are advisory
or routing choices; permissions, risk, approval, and execution remain enforced by
normal application code.

## Session and device selection

`AgentSession` currently carries a session ID, an optional active device, and an
explicit opt-in for bounded automatic selection among multiple read-only devices.
The active device must come from trusted session/UI state, not from an arbitrary
model response.

`ToolIntent` can name an explicit device. Selection order is:

1. explicit device from the intent;
2. trusted active device from the session;
3. the only capable device, when exactly one exists;
4. bounded decision among multiple candidates only when the capability is
   consistently classified as `read` and the session explicitly allows it;
5. otherwise return `deviceSelectionRequired`.

If two devices advertise the same canonical capability with different risk
levels, orchestration fails closed with `inconsistentCapabilityRisk`.

For non-read actions, bounded AI device selection is not allowed. The final
`ToolRequest` is always bound to the chosen device and session, so a future local
approval can be issued for that exact context and exact arguments.

## Data boundary

`DecisionRequest.state` is intentionally provider-neutral JSON. A future adapter
must curate what is sent to an external decision provider. Do not dump raw screen
contents, credentials, file contents, tokens, or unrelated conversation history
into bounded decision state. Send only the minimum structured facts needed for the
choice.

## Jev

Jev is a future implementation of `DecisionProvider`, not a dependency of
`AgentCore` and not the orchestrator itself. It is intended for bounded choices
such as next-step selection, specialist/model routing, retry/stop/escalate, and
low-risk candidate ranking. Deterministic rules remain preferred when code can
answer exactly; open-ended reasoning remains a separate provider path.

## Not implemented yet

- Jev API adapter or credentials
- OpenAI/Claude reasoning adapter
- model router
- realtime conversation loop
- long-running job manager
- persisted sessions
- remote device transport/pairing/heartbeat
- local approval UI

Those should be added as separate increments against these contracts.
