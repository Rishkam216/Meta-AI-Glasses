# Approval foundation

The approval layer is intentionally provider-neutral and platform-neutral. It exists so future mutating tools can require an explicit, trusted local authorization without letting a model fabricate or replay approval.

## Binding

Each grant is bound to:

- one tool name
- that tool's declared risk level
- the exact immutable JSON arguments
- one device ID
- one session ID
- a short expiry time

A presented grant is consumed whether it succeeds or fails binding checks. This prevents replay and makes probing a grant destructive rather than informative.

## Default behavior

`ToolRuntime` accepts an `ApprovalAuthorizing` implementation. The default is `DenyAllApprovals`, which returns `approval_required` for every non-read tool.

The current Mac composition root uses that default. Therefore adding this core infrastructure does **not** enable clicks, typing, shell commands, file writes, network side effects, or any other mutating behavior.

`ApprovalStore` is an in-memory implementation intended to be owned by trusted local application code. It can issue one-time grants with a bounded TTL. It does not expose a model-facing issuance API.

## Required before first mutating native tool

The Mac app still needs a local approval UI that:

1. displays the exact proposed action and relevant arguments,
2. requires a human action on the local device,
3. issues the grant only after confirmation,
4. binds it to the current device/session,
5. submits the immutable approved request exactly once,
6. treats expiry, mismatch, cancellation, permission failure, and replay as denial.

Risk classification remains semantic. A UI click or keystroke can create an external effect, so native method names must not be used to downgrade risk.

## Tests

The AgentCore suite verifies:

- exact matching grant executes once,
- replay is rejected,
- changed arguments are rejected and consume the grant,
- device/session mismatch is rejected,
- expired grants are rejected,
- TTL is bounded,
- read-only tools cannot receive approval grants,
- the default runtime still refuses non-read tools without an issuer.
