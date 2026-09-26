# OpenAI Realtime Live Canary

Status: **COMPLETE — REAL PAID NETWORK CANARY PASSED**

Created: 2026-09-26  
Validated: 2026-09-26  
Successful canary commit: `f1c12c59a21143b8109ca0a127fd41056c2185ba`  
GitHub Actions run: `36239995353` (`Realtime live canary` run #3)

This document records the first paid-network validation for the Realtime AI → Agent Orchestrator → macOS control milestone.

The canary answered one narrow question:

> Can the production OpenAI Realtime adapter authenticate with a server-minted short-lived credential, complete the GA WebSocket handshake, send a bounded text turn, receive model text, and terminate cleanly on the real OpenAI network?

**Yes.** The bounded live run completed successfully and emitted the expected normalized marker `REALTIME_LIVE_CANARY_OK`.

It was deliberately not a load test, voice test, tool-execution test, or production deployment test.

## Architecture under test

```text
standard OpenAI API key (GitHub Actions secret only)
        ↓
POST /v1/realtime/client_secrets
        ↓
short-lived Realtime credential
        ↓
OpenAIRealtimeProvider
        ↓
URLSessionOpenAIRealtimeTransport
        ↓
wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1
        ↓
session.created
        ↓
small text-only response turn
        ↓
response.output_text.delta / response.done
```

The long-lived OpenAI API key was not embedded in source, committed to git, printed to logs, written to artifacts, or passed into the model-facing session object. It was used only from the GitHub Actions secret environment to mint the short-lived credential.

## Bounded execution rules

The live canary must never run on ordinary push/PR CI. It may run only from an explicit `workflow_dispatch` invocation or from the dedicated canary branch when the triggering commit message contains the exact opt-in marker `[run-realtime-canary]`.

The successful run preserved these bounds:

- exactly one client-secret mint request;
- exactly one Realtime WebSocket session;
- exactly one user text turn;
- text output only;
- no Mac tool execution;
- no microphone, camera, screen capture, filesystem, shell, click, or type actions;
- no automatic retry;
- hard workflow timeout;
- bounded response/event processing;
- no secret/token logging;
- fail closed on malformed provider responses;
- fail immediately when `OPENAI_API_KEY` is absent.

## Invocation history

- 2026-09-26: first guarded invocation stopped at the repository-secret gate because `OPENAI_API_KEY` was absent. No OpenAI request was made and no API credit was used.
- 2026-09-26: repository owner configured `OPENAI_API_KEY` as a GitHub Actions secret.
- 2026-09-26: second guarded invocation on commit `f1c12c59a21143b8109ca0a127fd41056c2185ba` passed. The secret gate, release build, and one bounded Realtime network turn all completed successfully.

## Success criteria

The canary succeeded against the real network:

- [x] OpenAI accepted the standard API key for `POST /v1/realtime/client_secrets`.
- [x] A valid short-lived credential was returned without being logged.
- [x] The actual `OpenAIRealtimeProvider` opened a WebSocket using that credential.
- [x] The production adapter completed its `session.created` handshake gate.
- [x] A bounded text-only turn was sent through the production adapter.
- [x] Assistant text was received through the production adapter.
- [x] The turn reached a completed state.
- [x] The final normalized response contained the expected canary marker.
- [x] The session terminated cleanly.
- [x] No API key or ephemeral credential appeared in the audited job logs.

The job log showed the repository secret only as GitHub's masked value `***` and the canary executable printed only the success marker `REALTIME_LIVE_CANARY_OK` for the live result.

## What this proves

This live validation proves the real provider-network boundary for the current text-first adapter:

```text
GitHub Actions secret
→ OpenAI client-secret mint
→ short-lived Realtime credential
→ production Swift Realtime provider
→ native WebSocket transport
→ live Realtime text turn
→ normalized assistant result
→ clean close
```

It also proves that the canary executable and workflow can perform this path without exposing the long-lived API key or minted short-lived credential in the job output.

## Explicitly out of scope / still open

This canary does **not** prove:

- production backend deployment;
- Supabase login;
- the Mac Keychain → deployed backend credential endpoint over the public internet;
- tool/function calling against a live model;
- local approval dialogs against a live model call;
- actual live-model-driven Mac `app.open` execution;
- reconnect/resume behavior after a broken transport;
- audio or voice behavior;
- Meta glasses behavior.

Those remain separate staged validations.

## Cost discipline

The successful invocation used only one deliberately tiny text turn and one client-secret mint, with no retry. The exact provider cost was not measured by this test and is therefore not recorded here.

## Secret handling

The standard API key is supplied only through the repository Actions secret named:

`OPENAI_API_KEY`

The workflow does not echo that environment variable. The executable sanitizes provider errors and does not print response headers or raw credential-mint payloads.

## Follow-on work

After this canary, the next Realtime hardening/work items remain:

1. automatic reconnect/resume behavior;
2. production backend deployment and real Keychain-session → backend credential flow;
3. bounded live function/tool-call validation with local approval;
4. broader native Mac capability surface;
5. voice/audio transport and UX.
