# Meta AI Glasses — Personal Agent

Native Mac runtime for a provider-, device-, and interface-neutral personal agent.
The user's handoff is authoritative; see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Current milestone

The realtime text/control slice and bounded live text canary are merged through
PR #18. The Mac app now wires a local exact-action approval UI, native `app.open`,
and the OpenAI Realtime adapter through the provider-neutral coordinator.
PostgreSQL canonical memory and the authentication foundation are also integrated.
Production login/deployment, voice, and live model-driven Mac execution are not
yet validated. See the [master checkpoint](docs/FINALIZED_PRODUCT_CONTEXT_MEMORY_PLAN.md)
and [Calculator validation runbook](docs/CALCULATOR_EXECUTION_VALIDATION.md).

The sections below describe the original runtime foundation and diagnostic build
flow; their historical test counts are not the current suite totals.

## Original runtime foundation

- Swift 6 package, macOS 14+ native menu-bar app; no third-party dependencies.
- Typed tool protocol, JSON result/error contract, runtime capability catalog.
- Ephemeral approval foundation for future mutating tools: exact tool/arguments,
  device + session binding, short expiry, one-time use, and replay rejection.
- Capability-based `DeviceRouter` plus `RuntimeDeviceExecutor`; routing is by
  explicit device ID and advertised tools, never hard-coded OS pairings.
- Provider-neutral `DecisionEngine`: deterministic rules first, bounded provider
  second (future Jev adapter), optional reasoning-provider escalation last.
- `AgentOrchestrator` binds tool intents to sessions and devices. Ambiguous
  bounded AI device selection is opt-in and read-only; ambiguous non-read actions
  require deterministic device context before approval/execution.
- The runtime factory defaults to `DenyAllApprovals`; the realtime app composition
  explicitly supplies its trusted local approval store and UI.
- Permission preflight, explicit user-initiated Accessibility request.
- Metadata-only JSONL audit log; failed initial audit prevents execution.
- One real native tool: `ui.get_frontmost_app`, using `NSWorkspace`.

No Jev adapter, voice, shell, file editing, or glasses integration is implemented.
Unimplemented tools are absent from the catalog. The device router is in-memory
only; encrypted remote device transport comes later.

## Build on your Mac

Use Xcode 16+ / Swift 6+ and macOS 14+. From the repository directory:

```bash
swift test
bash scripts/build-app.sh
open dist/MetaAIGlasses.app
```

An **Agent** menu appears in the menu bar. Choose **Inspect frontmost app in
3 seconds**, then bring Safari or another app forward. The result window shows
the app's name, bundle identifier, PID, and request ID. The delay allows you to
select another app before the diagnostic window opens.

To open the package in Xcode: `open Package.swift`.
Use the bundled `.app` for permission testing, not an Xcode-launched executable;
the responsible process and TCC identity can differ.

Accessibility is unnecessary for the first tool. For later UI tools, choose
**Request Accessibility permission…** and grant it under System Settings →
Privacy & Security → Accessibility. Reopen the menu to refresh the status.
The app does not request permissions on launch or on model/tool calls.

The build script ad-hoc signs for local development. This is not notarized for
distribution. Rebuilding an ad-hoc app can invalidate its Accessibility grant.
Use a consistent bundle path and a real signing identity for reliable ongoing
TCC testing; the script accepts `MAC_AGENT_SIGNING_IDENTITY`.

Audit location:
`~/Library/Application Support/MetaAIGlasses/audit.jsonl`.
The menu includes **Show audit folder**. Logs exclude tool arguments and results.
They are private local metadata, not tamper-proof evidence. Rotation is not yet
implemented; this milestone only generates logs on manual diagnostic calls.

## Verification

`swift test` on Linux compiles/tests **AgentCore only**. The current stacked core
suite has **36 passing tests** covering runtime/audit contracts, approvals, device
routing, decision escalation/output validation, and orchestrator routing safety.
macOS targets are deliberately excluded on Linux; passing here does not validate
AppKit, Accessibility, CoreGraphics, signing, TCC, or real desktop behavior.

On a Mac with an interactive desktop, also run:

```bash
RUN_MAC_GUI_TESTS=1 swift test
```

See [docs/VALIDATION.md](docs/VALIDATION.md) for actual results and the remaining
native checks. See [docs/ORCHESTRATOR.md](docs/ORCHESTRATOR.md) for the decision
and routing contract. Every additional mutating native tool must preserve the
macOS build gate and trusted exact-action approval boundary.

## Backend isolation

The PostgreSQL-backed memory storage API, opaque-session authentication boundary, forced row-level security and scoped lexical cache are implemented under [backend](backend/README.md). Run its independent database/HTTP isolation suite with `cd backend && npm ci --ignore-scripts && npm test`. The Swift canonical-ledger bridge is merged; production deployment remains open. The master checkpoint specifies the remaining gates.
