# Memory → Context Compiler Integration

Status: implementation on `core/memory-context-integration`; merge only after exact-head CI is green.

This document describes how long-term memory enters model context without becoming identity, instruction, authorization, or a provider-specific dependency.

The master architecture/checklist remains `docs/FINALIZED_PRODUCT_CONTEXT_MEMORY_PLAN.md`.

---

## 1. Goal

Long-term memory must be usable by the agent through the existing authenticated Context Compiler / orchestrator path.

The intended path is:

```text
Authenticated AgentInvocationContext
        ↓ exact TenantContext
AgentOrchestrator.compileContext(...)
        ↓
ContextCompiler
        ↓ scope intersection before retrieval
MemoryContextRetrieving
        ↓
MemoryContextRetriever
        ↓ infrastructure-fixed retrieval strategy
MemoryService
        ↓
Canonical Memory Ledger
        └── optional provider-backed ranking
        ↓ canonical re-resolution
ContextItem(trust = memory)
        ↓
ContextCompiler policy + item/byte budgets
        ↓
CompiledContext
```

The orchestrator/model layer never calls Supermemory directly.

---

## 2. Security invariants

### Identity is not query data

`TenantContext` is passed separately by authenticated infrastructure.

`MemoryContextQuery` contains only semantic retrieval information:

- query text;
- requested memory scopes;
- result limit;
- source byte budget.

It does **not** contain tenant ID, user ID, account ID, provider ID, credentials, or session authority.

### Provider selection is infrastructure configuration

`MemoryContextRetrievalStrategy` is configured on `MemoryContextRetriever`.

It is not a field in `MemoryContextQuery`, so a model-facing semantic request cannot choose a memory provider or deployment.

The current safe default is canonical retrieval.

### Compiler scope wins before retrieval

A memory query cannot widen context access.

Before calling the memory retriever, `ContextCompiler` converts its already-authorized context scopes into the corresponding long-term-memory scopes and intersects them with the semantic memory query.

Only these long-term scopes participate:

- user;
- project;
- workspace.

Session, interface, device, task, application and connected-service scopes do not implicitly grant long-term-memory access.

If the intersection is empty, no memory lookup occurs. This prevents a query from probing whether a disallowed project/workspace contains a matching memory by observing result counts.

### Memory is context, never instruction

Memory-derived `ContextItem`s always use:

```text
trust  = memory
origin = memory_service
key    = memory
```

Prompt-like text inside a memory remains `.memory`. It cannot become `user_instruction` merely because it says things such as “ignore the user”, “approve this”, “downgrade risk”, or “delete files”.

### Bounded decisions do not receive live memory

A `ContextCompilationRequest` that contains a live `memoryQuery` is rejected for `bounded_decision` consumers.

The existing device-selection/Jev-style path continues to compile only curated system/tool state with:

```text
includeMemory = false
includeExternalContent = false
includeModelGenerated = false
```

Memory therefore cannot select a different tenant, grant an approval, or downgrade deterministic risk policy through the bounded-decision channel.

---

## 3. Canonical retrieval

`MemoryService.retrieveForContext(...)` supports a canonical strategy that does not require an external memory provider.

For each already-authorized requested memory scope it:

1. queries the canonical ledger with `includeSuperseded = false`;
2. inspects at most 100 active canonical records per scope;
3. verifies exact principal and exact requested scope again;
4. performs deterministic bounded lexical ranking;
5. orders by score, then update time, then canonical UUID;
6. returns at most the query result limit.

The fallback ranker is intentionally simple. It exists so the product has a safe provider-independent retrieval path before semantic/vector retrieval is production-ready.

It is not presented as a replacement for future semantic retrieval quality.

---

## 4. Provider-backed retrieval

`MemoryContextRetriever` may be composed with an infrastructure-fixed `.provider(providerID)` strategy.

Provider-backed search still goes through `MemoryService.search(...)`.

Provider hits are not treated as canonical truth. The service re-resolves hits against a single canonical snapshot and accepts only records that are:

- mapped to the expected provider memory ID;
- owned by the exact authenticated principal;
- active;
- in an allowed requested memory scope.

This prevents provider results from reintroducing forgotten, historical, wrong-scope or foreign-principal canonical records.

Provider-backed production use still depends on provider lifecycle/isolation guarantees documented elsewhere. This integration does not promote Supermemory mutations to production readiness.

---

## 5. Memory → Context conversion

Each retrieved canonical memory becomes one `ContextItem` with:

- `id` = canonical memory UUID;
- exact authenticated `TenantContext` internally;
- mapped user/project/workspace context scope;
- `key = "memory"`;
- `trust = .memory`;
- `origin = .memoryService`;
- provenance reference `memory:<canonical UUID>`;
- `freshness = .longTerm`;
- observed time = canonical memory `updatedAt`;
- created time = canonical memory `createdAt`.

The model-facing value may include:

- canonical memory ID;
- canonical content;
- memory kind;
- confidence;
- retrieval score;
- source **types**;
- derived-from canonical memory IDs.

It deliberately does **not** include:

- raw source references/paths;
- tenant ID;
- user ID;
- account ID;
- provider credentials;
- provider deployment identity.

---

## 6. Deduplication and collisions

The memory adapter rejects duplicate canonical IDs in one retrieval response.

The compiler merges stored context and live memory by UUID.

If a live memory item collides with an already-stored Context Service item, the existing stored context wins. Live memory cannot overwrite an existing item and change its trust/source classification.

---

## 7. Budgets

There are independent bounds at multiple layers.

### Memory query bounds

- query text: non-empty, max 4,096 UTF-8 bytes;
- scopes: 1...16;
- result limit: 1...32;
- memory-source encoded byte budget: 256...262,144 bytes.

### Canonical fallback bound

- max 100 active records inspected per requested scope before ranking.

### Context Compiler bounds

Existing compiler limits continue to apply after memory retrieval:

- max compiled items;
- max encoded bytes;
- model-specific trust policy;
- requested key filter.

If `requestedKeys` is present and excludes the reserved key `memory`, the compiler skips the live memory lookup entirely.

---

## 8. Failure behavior

Memory personalization is optional; identity and authorization are not.

Therefore:

- cancellation propagates;
- principal mismatch fails closed;
- a foreign-principal memory returned by an adapter fails closed;
- same-principal provider/storage/validation failures degrade to no live memory;
- failure details are not copied into model-facing compiled context;
- an empty/disallowed scope intersection performs no memory lookup;
- no failure can widen scopes, change tenant identity, grant approval, or alter deterministic risk policy.

`CompiledContext` carries a bounded `MemoryRetrievalSummary` with counts and a failure boolean. Because retrieval is intersected with compiler-authorized memory scopes before I/O, these counts cannot be used to probe disallowed project/workspace memory.

---

## 9. Orchestrator boundary

`AgentOrchestrator.compileContext(...)` is the authenticated entry point for future realtime/reasoning adapters.

It requires `AgentInvocationContext`, whose principal is supplied separately from model-generated intent.

This keeps the intended layering:

```text
Realtime / Reasoning adapter
        ↓
AgentOrchestrator
        ↓
ContextCompiler
        ↓
MemoryContextRetriever
        ↓
MemoryService
```

A future model adapter should not instantiate its own provider client or query a memory vendor directly.

---

## 10. Test coverage added by this milestone

The integration test matrix covers:

- explicit opt-in before live memory retrieval;
- user/project/workspace scope mapping;
- pre-retrieval scope intersection so disallowed scopes cannot be probed;
- cross-principal canaries with identical canonical UUIDs;
- malicious retriever returning another principal's memory;
- superseded-memory exclusion;
- deleted-memory exclusion;
- prompt-injection-shaped memory remaining trust `.memory`;
- bounded-decision rejection of live memory retrieval;
- rejection of memory query without `includeMemory`;
- omission of raw source references and tenant/user/account IDs from compiled payload;
- trusted stored context winning UUID collisions;
- sanitized degradation when optional memory retrieval fails;
- memory-source byte budget;
- global compiler item budget independently from retrieval limit;
- `requestedKeys` lookup avoidance;
- authenticated orchestrator integration;
- canonical ranking across the full bounded 100-record scope page rather than an early result-count-derived prefilter.

Existing Memory Service tests continue to cover canonical re-resolution of provider hits, including historical/deleted/wrong-scope/unmapped results.

---

## 11. Explicit non-goals / remaining work

This milestone does not claim completion of:

- semantic/vector retrieval in our backend;
- successful live Supermemory lifecycle/isolation validation;
- production Supermemory mutations;
- live Supabase project/login configuration;
- realtime model integration;
- a conversational Mac UI;
- broader Mac click/type/window/file/shell executor surface;
- Job Manager;
- mobile client;
- Windows client/runtime;
- glasses integration.

The next user-visible product path after this integration is:

```text
Realtime AI
    ↓
Agent Orchestrator
    ↓
Context Compiler + Memory
    ↓
Device Router
    ↓
Mac Executor
```

Windows remains deferred during the current Mac-first phase.
