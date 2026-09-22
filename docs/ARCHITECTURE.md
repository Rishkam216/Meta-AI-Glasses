# Architecture and milestone boundary

The user's handoff dated 2026-09-22 is the source of truth. This document applies
it to the first implementation increment; it does not change the product scope.

## Product constraints

The agent is the product. Glasses are one eventual input/output adapter.
Phone/glasses/future interfaces connect to realtime conversation, orchestration,
provider selection, platform-owned tools, and device executors.

- Initial realtime provider: OpenAI. Later specialized/long-running work may use
  OpenAI, Claude, other hosted providers, or local models. Keep all provider SDKs
  outside the device executor. No model router is implemented in this milestone.
- Native Swift Mac application; no Electron. No Rust until it materially helps.
- Future Windows/Linux agents implement the same logical capabilities using
  native APIs. Route by registered capabilities, not by a hard-coded OS pairing.
- Prefer APIs → structured browser/application APIs → Accessibility → vision →
  coordinates. Browser automation eventually gets its own structured adapter.
- Coding tasks use repository search, direct file edits, tests, and Git tools;
  use visual desktop control only for actual GUI interaction.
- Keep realtime interaction responsive while separate jobs do research/coding.
- Future transport: per-device identity, encrypted outbound connection to a
  gateway. No inbound exposed ports. No network transport in this increment.
- Future glasses audio/video flows through an iOS or Android phone companion.
  Support Android + Windows, iPhone + Windows, Android + Mac, and multiple
  computers per account. Do not assume iPhone + Mac.

## Repository

```text
Package.swift
Sources/
  AgentCore/           # Foundation-only tool and policy contracts, audit/runtime
  MacRuntime/          # AppKit/Accessibility implementations and permissions
  MacAgent/            # Native menu-bar application; local composition root
Tests/
  AgentCoreTests/      # Permission/policy/audit/contract behavior
  MacRuntimeTests/     # Adapter tests and opt-in real desktop smoke test
Resources/Info.plist   # Stable bundle identity
scripts/build-app.sh  # Release build, bundle, local signing and verification
docs/                 # Decisions, contract, validation and next milestone
.github/workflows/    # Compile/test on a real macOS runner when pushed
```

No empty provider, gateway, Windows, or glasses projects. Add modules only when
implementing their first working behavior. AgentCore is currently portable Swift;
the future interoperable boundary is JSON, not a requirement that Windows or
Android use Swift.

## Internal tool protocol

```swift
public protocol Tool: Sendable {
    associatedtype Input: Codable & Sendable
    associatedtype Output: Codable & Sendable
    var descriptor: ToolDescriptor { get }
    func execute(_ input: Input) async throws -> Output
}
```

The descriptor declares the canonical capability name, description, JSON Schema
input contract, risk level, and required OS permissions. Typed decoding enforces
input shape; schemas describe it to future model adapters. Each future tool
must validate unknown keys, bounds, paths, and semantic constraints in its input
type; a JSON Schema declaration alone is not an enforcement mechanism.

`ToolRuntime` erases the generic type only at registration and the JSON boundary.
`catalog()` advertises actual registered tools. Duplicate names fail registration.
Use `ui.get_frontmost_app` as the canonical v0.1 name from the handoff; do not
maintain duplicate `computer.*` aliases. IDs are request correlation IDs, not
authorization grants or a replay/idempotency mechanism.

Flow: request → initial audit → registered tool lookup → risk policy → permission
preflight → typed decode → native execution → completion audit → structured result.
Missing capability, denied permission, decoding errors, cancellation, and runtime
errors do not return fake success. There is no synchronous network or shell work
on the main thread. Native foreground lookup runs on MainActor; audit I/O runs
on its own actor. Runtime actors can reenter at suspension points; do not rely on
them to serialize future GUI mutations. Add a dedicated GUI action queue before
the first mutating tool and explicit process/job IDs before long-running shell.

## Result contract, version 1

Success (illustrative data):

```json
{
  "protocolVersion": 1,
  "requestID": "82E5BA4E-008B-430C-9FCE-3C03DF13EDE4",
  "tool": "ui.get_frontmost_app",
  "status": "success",
  "data": {"processID": 1234, "bundleIdentifier": "com.apple.Safari", "name": "Safari"}
}
```

Error (illustrative future Accessibility tool):

```json
{
  "protocolVersion": 1,
  "requestID": "82E5BA4E-008B-430C-9FCE-3C03DF13EDE4",
  "tool": "ui.get_windows",
  "status": "error",
  "error": {
    "code": "permission_required",
    "message": "Grant the required permission in the Mac app, then retry.",
    "retryable": false,
    "details": {"permission": "accessibility"}
  }
}
```

Exactly one of `data` and `error` is encoded. Missing app name or bundle ID is
omitted rather than invented. No foreground app produces `unavailable`.
Error codes: `unknown_tool`, `invalid_arguments`, `permission_required`,
`approval_required`, `unavailable`, `cancelled`, `execution_failed`,
`audit_unavailable`. Retryable describes whether a retry may help; it never
authorizes an automatic retry of a write. Completion-audit failure reports
`may_have_executed: true`; do not retry automatically.

## Permissions and safety

`NSWorkspace.frontmostApplication` returns app metadata. The first tool does
not need Accessibility. `MacPermissions` checks Accessibility with
`AXIsProcessTrusted()` and screen recording with `CGPreflightScreenCaptureAccess()`.
Screen capture is not implemented or requested yet.

Only a local menu click invokes `AXIsProcessTrustedWithOptions` with its prompt
flag. Its return is the current trust state; the prompt is asynchronous and does
not grant access. Recheck trust before every Accessibility tool call. Revocation
during execution must also become a structured error from the future AX adapter.
Never continuously prompt or automatically retry a denied permission.

All non-read risks currently return `approval_required`; no approval bypass
exists. Native method calls within the trusted executable can of course bypass
the router; the security boundary is that only the runtime is exposed to future
untrusted callers. Before adding mutations, implement local human approval bound
to device/session, exact tool and immutable arguments, short expiry, and one use.
Risk must consider action semantics: a click can send money, and typing can
submit a command. Never downgrade these solely because they use a UI tool.
Shell commands default to high risk; never use naive substring matching as a
shell sandbox or claim an allowlist can safely interpret arbitrary shell.

Audit start/completion events contain only time, request ID, tool name, risk,
phase, status and error code. File permissions are 0600; the directory is 0700.
The log refuses a symlink file target and non-regular files. It is not protected
from the same OS user or root, and directory ancestry is not a hardened sandbox.
Before a public transport, add authentication, input bounds, path containment,
replay protection, log retention, and rate limits. Keychain becomes relevant
when credentials/device keys exist; there are no credentials in this milestone.

## Increment order

1. Current: contract + first foreground-app tool + native app; pass macOS build
   and real desktop check before proceeding.
2. `ui.get_windows`, then bounded `ui.get_tree`, with opaque expiring element
   handles, AX timeout handling, stale-element errors, and permission tests.
3. Native local approval UI; then `ui.click` and `ui.type` with semantic risk
   escalation and a serialized GUI action queue.
4. ScreenCaptureKit capture, explicitly separate screen-recording consent.
5. Workspace-scoped file read/write; process list; approved shell execution with
   persistent job IDs, bounded output, status, cancellation, exit codes and
   process-tree cleanup.
6. Provider adapter and realtime/text orchestration on a local trusted transport.
   Keep long-running workers independent of the conversational session.

App opening is needed for the acceptance workflow; add `app.open` using
NSWorkspace when it is the next tested increment. The eventual acceptance test:
"Open Safari, inspect what's on screen, open a project, run its backend,
determine whether it started successfully, and explain any error."
No manual computer control during that workflow except explicit security approval.
This milestone does not yet pass that end-to-end test.

References consulted:
- https://developer.apple.com/documentation/appkit/nsworkspace/frontmostapplication
- https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions
- https://developer.apple.com/documentation/coregraphics/cgpreflightscreencaptureaccess()
- https://www.swift.org/install/linux/ubuntu/24_04/
