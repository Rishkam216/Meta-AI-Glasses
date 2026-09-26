# OpenAI Realtime Live Canary

Status: **Second bounded invocation requested after repository secret configuration; live result pending**

Created: 2026-09-26

This document defines the first paid-network validation for the Realtime AI → Agent Orchestrator → macOS control milestone.

The canary exists to answer one narrow question:

> Can the production OpenAI Realtime adapter authenticate with a server-minted short-lived credential, complete the GA WebSocket handshake, send a bounded text turn, receive model text, and terminate cleanly on the real OpenAI network?

It is deliberately not a load test, voice test, tool-execution test, or production deployment test.

## Architecture under test

```text
standard OpenAI API key (CI secret only)
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

The long-lived OpenAI API key must never be embedded in source, committed to git, printed to logs, written to artifacts, or passed into the model-facing session object. It is used only to mint the short-lived credential.

## Bounded execution rules

The live canary must never run on ordinary push/PR CI. It may run only from an explicit `workflow_dispatch` invocation or from the dedicated canary branch when the triggering commit message contains the exact opt-in marker `[run-realtime-canary]`.

Required bounds:

- exactly one client-secret mint request;
- exactly one Realtime WebSocket session;
- exactly one user text turn;
- text output only;
- no Mac tool execution;
- no microphone, camera, screen capture, filesystem, shell, click, or type actions;
- no automatic retry;
- hard wall-clock timeout;
- bounded response/event processing;
- no secret/token logging;
- fail closed on malformed provider responses;
- fail immediately when `OPENAI_API_KEY` is absent.

## Invocation history

- 2026-09-26: first guarded invocation stopped at the repository-secret gate because `OPENAI_API_KEY` was absent; no OpenAI request was made and no API credit was used.
- 2026-09-26: repository owner reported `OPENAI_API_KEY` configured; one bounded rerun requested.

## Success criteria

The canary is successful only if all of the following are observed on the real network:

- [ ] OpenAI accepts the standard API key for `POST /v1/realtime/client_secrets`.
- [ ] A valid short-lived credential is returned without being logged.
- [ ] The actual `OpenAIRealtimeProvider` opens a WebSocket using that credential.
- [ ] The production adapter receives `session.created`.
- [ ] A bounded text-only turn is sent through the production adapter.
- [ ] At least one assistant text delta is received.
- [ ] The turn reaches a completed state.
- [ ] The final normalized response contains the canary marker.
- [ ] The session is closed cleanly.
- [ ] No API key or ephemeral credential appears in logs.

## Explicitly out of scope

This canary does not prove:

- production backend deployment;
- Supabase login;
- the Mac Keychain → deployed backend credential endpoint over the public internet;
- tool/function calling against a live model;
- local approval dialogs;
- actual Mac `app.open` execution;
- reconnect/resume behavior;
- audio or voice behavior;
- Meta glasses behavior.

Those require separate staged validations.

## Cost discipline

The prompt is intentionally tiny and asks for a deterministic short marker response. A canary invocation performs no retries. A successful invocation should consume only a minimal Realtime text turn plus one client-secret mint request.

## Secret handling

GitHub Actions must receive the standard API key only through the repository Actions secret named:

`OPENAI_API_KEY`

The workflow must never echo that environment variable. The executable must sanitize all provider errors and must not print response headers or raw credential-mint payloads.

## After a successful run

Only after a real successful network run should the master source-of-truth and `docs/REALTIME_ORCHESTRATOR_MAC_CONTROL.md` mark the paid OpenAI Realtime network canary complete.
