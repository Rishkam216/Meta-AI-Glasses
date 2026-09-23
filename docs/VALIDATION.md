# Validation record

## Device routing foundation — 2026-09-23

Environment: Swift 6.2.1 on Linux x86_64.

- Added `DeviceIdentity`, `DeviceExecuting`, `RuntimeDeviceExecutor`, `DeviceRouter`, and structured routing errors.
- Ran `swift test -j 2` against the approval + routing branch.
- **21 tests passed with zero failures**: 10 original runtime/audit/contract tests, 5 approval tests, and 6 device-routing tests.
- Routing tests verify capability-based candidate selection independent of platform metadata, exact device/session context construction, approval forwarding, unknown-device rejection, unadvertised-capability rejection, duplicate-device rejection, and routing through a real `ToolRuntime` adapter.
- `snapshots()` copies the registered executor collection before awaiting capability calls so actor reentrancy cannot mutate the dictionary mid-iteration.

This validates portable AgentCore behavior only. It does not validate AppKit, Accessibility, CoreGraphics, codesigning, TCC, or interactive macOS behavior.

## Core approval foundation — 2026-09-23

- **15 tests passed with zero failures**: the original 10 runtime/audit/contract tests plus 5 approval tests.
- Approval tests verify exact binding, one-time execution, replay rejection, argument tamper rejection, device/session binding, expiry, bounded TTL, and refusal to issue approval for read-only tools.
- Existing tests still verify default refusal of all non-read actions when no trusted approval issuer is supplied.
- The current Mac composition root still uses the default `DenyAllApprovals`, so this branch does not enable mutations.

## Milestone 1 — 2026-09-22

- Swift 6.1.2 on Ubuntu 24.04, strict Swift 6 language mode.
- `swift test -j 2`: AgentCore compiled and linked; **10 tests passed**, including
  parameterized cases for all three non-read risks, malformed inputs, and both
  initial/completion audit failure. Zero failures.
- Verified successful output and correlation, metadata-only audit, denied
  permissions, unknown tools, invalid arguments, refusal before execution,
  failure after execution, duplicate registration, error redaction, JSON types
  and large integers, audit append behavior, 0600 permissions and symlink refusal.
- `bash -n scripts/build-app.sh`: passed.
- Info.plist parsed; bundle executable and menu-bar metadata checked.
- Native Swift sources parsed successfully with `swiftc -frontend -parse`.
  This checks syntax only, not Apple API availability or actor annotations.

## Native validation still pending

- macOS type checking, linking, bundle signing, or launch.
- MacRuntime adapter tests (excluded from the Linux manifest).
- Real foreground-app lookup, permission prompt/grant/revocation, or menu UI.
- GitHub Actions run 35757635596 has repeatedly failed before any workflow step
  starts because the account-side macOS hosted-runner restriction remains active.
  No Swift build failure has been observed from that workflow.

Therefore the project is **core-verified, native verification pending**.
Do not describe it as a working, fully verified Mac app yet.

## Native gate

1. On macOS 14+ with Swift 6+, run `swift test`.
2. Run `bash scripts/build-app.sh`; verify successful codesign checks.
3. `open dist/MetaAIGlasses.app`; ensure one Agent menu appears.
4. Leave Accessibility disabled. Inspect Safari after the 3-second delay.
   Expect a success result identifying Safari, with a positive PID.
5. Repeat with another app and confirm the identity changes.
6. Check that each request has started/completed audit events sharing its ID,
   without application names, arguments or result data in the audit file.
7. Choose Request Accessibility permission. Confirm nothing is auto-granted;
   grant/revoke in System Settings and reopen the menu to verify status changes.
8. Run `RUN_MAC_GUI_TESTS=1 swift test` from the interactive Mac session.
9. Quit and relaunch the app. Confirm log appends and the first tool still works.

After this gate passes, `ui.get_windows` remains the next native read-only tool.
Before the first mutating tool, wire a trusted local approval UI to `ApprovalStore`.
