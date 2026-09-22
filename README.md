# Meta AI Glasses — Personal Agent

Native Mac runtime for a provider-, device-, and interface-neutral personal agent.
The user's handoff is authoritative; see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## First milestone

- Swift 6 package, macOS 14+ native menu-bar app; no third-party dependencies.
- Typed tool protocol, JSON result/error contract, runtime capability catalog.
- Read-only policy; all non-read tools are refused until approval handling exists.
- Permission preflight, explicit user-initiated Accessibility request.
- Metadata-only JSONL audit log; failed initial audit prevents execution.
- One real tool: `ui.get_frontmost_app`, using `NSWorkspace`.

No model, voice, shell, file editing, network listener, cloud gateway, or glasses
integration is implemented. Unimplemented tools are absent from the catalog.
This is milestone 1 of v0.1, not the full MVP.

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

`swift test` on Linux compiles/tests **AgentCore only**. macOS targets are
deliberately excluded on Linux; passing there does not validate native APIs.

On a Mac with an interactive desktop, also run:

```bash
RUN_MAC_GUI_TESTS=1 swift test
```

See [docs/VALIDATION.md](docs/VALIDATION.md) for actual results and the remaining
native checks. Do not add the next tool until the native app compiles and the
foreground-app smoke test passes.
