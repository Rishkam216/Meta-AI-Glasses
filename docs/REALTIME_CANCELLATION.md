# Realtime cancellation and connection cleanup

Status: **Implementation, independent source review, and CI passed.**
Baseline: PR #19 merge `5310f7f`. No paid calls are required for this milestone.

PR #20 implementation commit: `f5f6a76620040bc2d35b4a1b599735177844eb1c`.
Native workflow `36293794592`: **257 Swift tests passed**, both canary executables
compiled, native app built and verified. Portable `36293794741` and backend
`36293794672` also passed. The added suite has seven portable cancellation tests
and seven provider lifecycle tests (eight parameterized cases).

## Problem

`RealtimeCoordinator.cancel` previously forwarded a cancellation message to the
provider without cancelling local execution. If a user approval was suspended,
it could later return approval and still dispatch the native action. A cancelled
runtime could also return a typed error which the coordinator sent back to the
provider, starting another response. Separately, failed provider startup did not
reliably close its transport, and a handshake timeout could wait on a receive
operation that ignored task cancellation.

## Implemented behavior

- The coordinator owns the execution task for an active provider session/turn.
  Coordinator value copies share lifecycle state. Independent coordinators are
  not a global session lock; keep one coordinator owner for a provider session.
- Register before starting work, reject overlapping turns on one session, and
  clean up only the matching generation. Keep no completed-turn history.
- Explicit cancellation marks the matching local task cancelled before waiting
  on provider cancellation. Caller task cancellation propagates to owned work.
- Close a cancelled provider session to release pending network reads. Await its
  close during lifecycle cleanup before admitting a replacement turn.
- Check cancellation after local confirmation and before issuing an approval,
  and after runtime work before sending another model continuation.
- Close transport on failed/cancelled startup. Handshake cleanup closes transport
  before leaving the task group, so a receive can be released before group exit.

## Scope of the guarantee

Cancellation is cooperative. It prevents execution after a suspended approval
returns to a cancelled task, and prevents a cancelled runtime result from starting
another model response. It cannot undo a native action that has already begun,
and is not an atomic rollback transaction with macOS. Never automatically retry
an uncertain side effect.

A custom approval implementation that never returns can delay `runTurn`'s return;
the coordinator does not forcibly dismiss native UI. A custom transport must
release pending reads when closed. The production app's Stop button and automatic
approval-dialog dismissal are separate work. This milestone adds neither.

Use a fresh provider session after cancellation. No automatic reconnect/resume,
tool replay across sessions, provider retries, voice, or authentication changes
are introduced.

## Verification

Deterministic continuation gates exercise suspended approval and provider reads;
tests must not depend on wall-clock sleeps or live provider calls. Required cases
include explicit and caller cancellation, correct session/turn binding, delayed
approval, overlapping-turn rejection, cleanup, cancelled result suppression, and
failed/cancelled provider startup transport cleanup.

Native/portable Swift, backend (embedded and native PostgreSQL), offline canary,
canary-build, and app-bundle checks passed on the implementation commit above.
No live provider, real Mac action, or native approval dialog was exercised by
these deterministic tests. No paid calls were made in this milestone.

The real Calculator approval/launch gate from
`CALCULATOR_EXECUTION_VALIDATION.md` is still pending on the user's Mac.
