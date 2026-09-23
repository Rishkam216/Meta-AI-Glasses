# Context Compiler validation

Date: 2026-09-23

Environment: Swift 6.2.1 on Linux x86_64.

## Implemented

- Added role-aware `ContextCompiler` for `realtime`, `bounded_decision`, and `reasoning` consumers.
- Added explicit item-count and encoded-byte budgets.
- Added explicit scope selection, user-scope opt-in, and optional key allowlisting.
- Model-bound `CompiledContextItem` deliberately omits `TenantContext`; tenant/user/account identifiers remain backend-side authorization context.
- Stale context is excluded through the `ContextServing` layer before compilation.
- Trust/provenance labels are preserved in compiled output.
- Bounded-decision consumers receive only `system_state` and `tool_result` context, even if callers attempt to opt into external content, memory, or model-generated material.
- Realtime consumers receive user instructions, system state, and tool results by default; external content and memory require explicit opt-in; model-generated context is excluded.
- Reasoning consumers use the same safe defaults and may explicitly opt into external content, memory, and model-generated context.
- Policy filtering happens before budgets. Items are ordered newest-first and then admitted atomically under the item/byte budget; oversized values are omitted rather than partially leaked.
- Compilation remains partitioned through the authenticated `TenantContext` supplied separately from the model-facing request.

## Validation

Ran a focused Swift package containing the production context schema, Context Service, typed context layers, Context Compiler, and their tests with `swift test -j 2`.

**32 tests passed with zero failures.**

Compiler tests verify:

- tenant/user/account identifiers do not appear in encoded model-bound compiled context;
- bounded-decision role sees only system/tool evidence;
- realtime requires explicit opt-in for external content and memory and never includes model-generated context;
- reasoning can explicitly include all trust classes while preserving labels;
- key allowlisting and item budgets apply after policy filtering;
- byte budgets drop oversized items whole;
- compilation cannot cross principal partitions, using deterministic cross-tenant canaries;
- invalid item counts, byte budgets, and key policies are rejected.

## Not yet implemented

This milestone does not claim completion of:

- session summarization;
- artifact references or bounded artifact reads;
- automatic refresh of stale ephemeral state;
- application-context adapters;
- connected-service context adapters;
- durable context persistence or database-level RLS;
- Memory Service / MemoryProvider integration;
- provider-specific redaction or secret-detection policies;
- actual realtime/Jev/reasoning provider adapters.

The repository-wide native macOS validation gate remains separate and pending.