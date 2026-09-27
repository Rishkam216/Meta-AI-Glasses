# Realtime response bounds

This slice adds per-turn receive and accumulation limits to the realtime path.
Its baseline is PR #20 merge `807522f`. It does not make paid provider calls.

Validated implementation: PR #21, `2bd05fa041a90b74516ab073167a1b092af52ba3`.
Native workflow `36309434676` passed **270 Swift tests**, both canary builds and
native app verification. Portable `36309434705` and backend `36309434665` passed.
Source changes received independent cross-review. No paid calls were made.

## Limits

| Boundary | Per-turn maximum | Accounting |
| --- | --- | --- |
| Coordinator provider events | 256 | Includes duplicates and completion |
| Accepted assistant text | 64 KiB UTF-8 | Sum of unique assistant deltas |
| OpenAI incoming wire frames | 512 | Includes ignored frames and duplicates |
| OpenAI incoming wire text | 4 MiB UTF-8 | Includes JSON framing and ignored data |

The existing 1 MiB individual wire-message and eight unique tool-call limits
remain in force. Tool-result continuations do not reset a turn's receive budget.
A genuinely new user turn starts a new budget. Provider event/call mappings are
per-turn state and must not grow across completed turns.

On response-budget exhaustion, close the provider session and return a bounded
error. Do not execute a subsequent tool, send another continuation, truncate the
response and claim success, or automatically retry. The caller must establish a
fresh provider session for later work.

Duplicates still count against event/frame budgets even when text is deduplicated.
Text sizes are bytes, not characters, so non-ASCII output cannot bypass the limit.
Completion must fit within the event/frame budget. Reaching a text budget exactly
is allowed when completion arrives within the remaining event/frame budget.

## What this does not guarantee

These are local resource/receive limits, not a provider token limit or a precise
money cap. Closing a connection cannot reverse charges already incurred or undo
an action already dispatched. A silent connection still requires cancellation or
a caller-owned deadline; count/byte limits are not an idle timeout. The separate
manual Calculator diagnostic retains its tighter one-action and 90-second turn
bounds. No reconnect, voice, new native capabilities, or production deployment is
included here.

## Validation gate

Deterministic tests cover exact boundaries, multi-byte text overflow, duplicate
floods, ignored wire messages, continuations, and clean budgets for subsequent
turns. No test requires real model output, API credit, or a desktop action.

Before merging, require the full portable/native Swift, backend, offline canary,
both canary builds, and native app-bundle CI gates. The PR records the exact tested
commit and results. The live Mac approval/launch gate remains open in
`CALCULATOR_EXECUTION_VALIDATION.md`.
