# Calculator execution validation

Status: **Implementation prepared; native CI and manual live Mac validation pending.**

This is one bounded milestone after PR #18, not a voice, login, deployment, or
general computer-control expansion. The baseline is `805c7f0`, whose Backend,
Portable core, and macOS workflows all passed on 2026-09-26.

## Automated test boundary

`Tests/MacRuntimeTests/RealtimeCalculatorExecutionTests.swift` joins previously
separate test seams:

OpenAI wire messages → production provider adapter → realtime coordinator →
orchestrator → local exact approval → actual `AppOpenTool` type → correlated
`function_call_output` → final assistant turn.

The network, human confirmation, and OS launch are deterministic substitutes.
The tests cover allow, deny, expiry using an injected clock, identical call replay,
and replay with changed application arguments. They check that execution has not
occurred during confirmation and that only the approved Calculator action runs.
These tests do **not** claim a real model call or native application launch.

## Manual live Mac gate

`MacControlCanary` uses the production provider, coordinator, approval store,
device router, and native `AppOpenTool`. Its only executable action is
`com.apple.calculator`. The trusted approval surface is the local terminal, not
the model and not the shipping app's menu-bar dialog.

Prerequisites:

- A Mac with an interactive logged-in desktop and Swift 6 / macOS 14 or later.
- A fresh short-lived OpenAI Realtime client secret for the configured model
  (`gpt-realtime-2.1`), obtained separately through an authorized credential broker.
  This diagnostic does not mint credentials or solve the pending login/deployment
  work. Do not retrieve secrets through CI logs or paste any credential in chat.
- Explicit willingness to spend a small amount of provider credit. Limits bound
  activity, not an exact rupee/dollar price; actual billing is not measured here.

From the repository on your Mac:

```bash
swift test --filter calculatorWire
swift build --product MacControlCanary
.build/debug/MacControlCanary --allow-live-calculator
```

The executable requires a controlling terminal. Type `START` to authorize the
network test, then paste the short-lived `ek_` credential into its hidden prompt.
Do not supply a standard API key, a shell argument, or a credential in a command
saved to shell history. The executable does not load production identity/memory;
its random diagnostic principal is limited to a fresh in-memory context store.

When the real model proposes the action, the terminal displays the exact native
tool and Calculator bundle identifier. Only typing `ALLOW CALCULATOR` approves it.
Any other response denies it. No prompt is auto-approved, and queued terminal
input is cleared before the approval prompt.

Expected results:

- `MAC_CONTROL_CANARY_OK`: native launch reported success, the correlated result
  was sent to the model, and the turn completed. Also visually verify Calculator.
- `MAC_CONTROL_CANARY_DENIED`: no native launch, denial returned, turn completed.
- `MAC_CONTROL_CANARY_STOPPED`: a guard, timeout, or failure stopped the run.
  This is not proof of rollback: Calculator can remain open if a later step failed.

Calculator may already be running; a successful open can activate it rather than
create a new process. Close it yourself beforehand if checking a cold launch.
No automatic retry or app termination is performed.

## Bounds and exclusions

- One provider session and one user turn; at most one tool result/continuation.
- One permitted semantic intent with exact Calculator arguments.
- At most one native launch attempt, independently enforced after approval.
- At most 32 surfaced provider events and 2,048 bytes of assistant text.
- 90-second turn deadline, including cancellable terminal approval; connection
  separately uses the production handshake limits.
- Fixed diagnostic messages only; no model text, credentials, or provider errors
  are printed. Audit metadata is ephemeral, not a durable production audit trail.
- Ordinary CI compiles the executable only. No live workflow or paid trigger is
  added, and the existing text-canary workflow is unchanged.

The terminal gate does not validate the shipping app's approval dialog, Keychain
login, backend deployment, reconnect/resume, or voice. Those remain separate work.

## Session checkpoint

- Local existing offline canary suite: **22 passed**.
- Local backend suite: **54 passed, 0 failed, 3 native-only skipped**.
- New Swift tests and both canary builds: pending macOS CI.
- Live network calls made during this implementation session: **none**.
- Real model → local human approval → native Calculator launch: **not yet run**.

Stop this milestone after CI and handoff. Do not start voice, new device adapters,
or production deployment as part of this change. Record the exact validated
commit and real Mac result before marking the live action checkbox complete.
