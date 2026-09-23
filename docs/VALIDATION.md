# Milestone 1 validation

Date: 2026-09-22.

## Executed here

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

The local toolchain was obtained from Swift.org. A missing ncurses dependency
was extracted locally from Ubuntu's official archive. These environment repairs
are not project dependencies and are not included in the repository.

## Not executed

- macOS type checking, linking, bundle signing, or launch.
- MacRuntime adapter tests (excluded from the Linux manifest).
- Real foreground-app lookup, permission prompt/grant/revocation, or menu UI.
- GitHub Actions run 35757635596 for commit c96705650c4860cf6553b132c651ed6645be61df
  was rejected before any steps started. On 2026-09-23, its annotation reported an
  account payment/spending-limit restriction. No macOS compilation or test ran.
  Resolve the account restriction and rerun the workflow, or execute the native
  checks below on a Mac. Do not change repository visibility to work around it.
  Run: https://github.com/Rishkam216/Meta-AI-Glasses/actions/runs/35757635596

## Repository delivery

The private repository https://github.com/Rishkam216/Meta-AI-Glasses was created
and all 18 initial project files were uploaded on 2026-09-22. The GitHub connection
has repository access; a personal access token is not required.

Therefore this milestone is **core-verified, native verification pending**.
Do not describe it as a working, fully verified Mac app yet.

## Gate before the next tool

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

Once these pass, implement and verify `ui.get_windows` as the next small change.
