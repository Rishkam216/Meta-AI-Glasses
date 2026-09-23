import Foundation
import Testing
@testable import AgentCore

private func makeCompilerItem(
    tenant: TenantContext,
    key: String,
    trust: ContextTrustClass,
    origin: ContextOrigin,
    observedAt: Date,
    value: JSONValue = .string("value"),
    scope: ContextScope = .user
) throws -> ContextItem {
    try ContextItem(
        tenant: tenant,
        scope: scope,
        key: key,
        value: value,
        provenance: ContextProvenance(origin: origin, trust: trust, sourceReference: "test:\(key)"),
        freshness: ContextFreshness(classification: .longTerm, observedAt: observedAt),
        createdAt: observedAt
    )
}

private func makeCompilerService() throws -> ContextService {
    ContextService(freshnessPolicy: try ContextFreshnessPolicy())
}

@Test func compiledPayloadOmitsTenantAndUserIdentifiers() async throws {
    let service = try makeCompilerService()
    let compiler = ContextCompiler(service: service)
    let tenant = TenantContext(tenantID: UUID(), userID: UUID(), accountID: UUID())
    let now = Date(timeIntervalSince1970: 1_000)
    try await service.store(
        makeCompilerItem(tenant: tenant, key: "preference", trust: .systemState, origin: .system, observedAt: now),
        for: tenant
    )

    let request = try ContextCompilationRequest(
        role: .realtime,
        includeUserScope: true,
        budget: ContextCompilationBudget()
    )
    let compiled = try await compiler.compile(request, for: tenant, at: now)
    let encoded = String(decoding: try JSONEncoder().encode(compiled), as: UTF8.self)

    #expect(compiled.items.count == 1)
    #expect(!encoded.contains(tenant.tenantID.uuidString))
    #expect(!encoded.contains(tenant.userID.uuidString))
    #expect(!encoded.contains(tenant.accountID!.uuidString))
}

@Test func boundedDecisionReceivesOnlySystemAndToolEvidence() async throws {
    let service = try makeCompilerService()
    let compiler = ContextCompiler(service: service)
    let principal = TenantContext(tenantID: UUID(), userID: UUID())
    let now = Date(timeIntervalSince1970: 1_000)
    let fixtures: [(String, ContextTrustClass, ContextOrigin)] = [
        ("user", .userInstruction, .user),
        ("system", .systemState, .system),
        ("tool", .toolResult, .tool),
        ("external", .externalContent, .externalService),
        ("memory", .memory, .memoryProvider),
        ("model", .modelGenerated, .model)
    ]
    for (offset, fixture) in fixtures.enumerated() {
        try await service.store(
            makeCompilerItem(
                tenant: principal,
                key: fixture.0,
                trust: fixture.1,
                origin: fixture.2,
                observedAt: now.addingTimeInterval(Double(offset))
            ),
            for: principal
        )
    }

    let request = try ContextCompilationRequest(
        role: .boundedDecision,
        includeUserScope: true,
        includeExternalContent: true,
        includeMemory: true,
        includeModelGenerated: true,
        budget: ContextCompilationBudget()
    )
    let compiled = try await compiler.compile(request, for: principal, at: now.addingTimeInterval(10))

    #expect(Set(compiled.items.map(\.trust)) == Set([.systemState, .toolResult]))
    #expect(compiled.stats.considered == 6)
    #expect(compiled.stats.excludedByPolicy == 4)
}

@Test func realtimeRequiresExplicitOptInForExternalAndMemoryAndNeverTakesModelGenerated() async throws {
    let service = try makeCompilerService()
    let compiler = ContextCompiler(service: service)
    let principal = TenantContext(tenantID: UUID(), userID: UUID())
    let now = Date(timeIntervalSince1970: 1_000)
    for (key, trust, origin) in [
        ("instruction", ContextTrustClass.userInstruction, ContextOrigin.user),
        ("external", .externalContent, .externalService),
        ("memory", .memory, .memoryProvider),
        ("model", .modelGenerated, .model)
    ] {
        try await service.store(
            makeCompilerItem(tenant: principal, key: key, trust: trust, origin: origin, observedAt: now),
            for: principal
        )
    }

    let defaultRequest = try ContextCompilationRequest(
        role: .realtime,
        includeUserScope: true,
        budget: ContextCompilationBudget()
    )
    let defaultCompiled = try await compiler.compile(defaultRequest, for: principal, at: now)
    #expect(Set(defaultCompiled.items.map(\.trust)) == Set([.userInstruction]))

    let optIn = try ContextCompilationRequest(
        role: .realtime,
        includeUserScope: true,
        includeExternalContent: true,
        includeMemory: true,
        includeModelGenerated: true,
        budget: ContextCompilationBudget()
    )
    let optedCompiled = try await compiler.compile(optIn, for: principal, at: now)
    #expect(Set(optedCompiled.items.map(\.trust)) == Set([.userInstruction, .externalContent, .memory]))
    #expect(!optedCompiled.items.contains { $0.trust == .modelGenerated })
}

@Test func reasoningCanExplicitlyIncludeAllTrustClassesAndPreservesLabels() async throws {
    let service = try makeCompilerService()
    let compiler = ContextCompiler(service: service)
    let principal = TenantContext(tenantID: UUID(), userID: UUID())
    let now = Date(timeIntervalSince1970: 1_000)
    let fixtures: [(String, ContextTrustClass, ContextOrigin)] = [
        ("u", .userInstruction, .user),
        ("s", .systemState, .system),
        ("t", .toolResult, .tool),
        ("e", .externalContent, .externalService),
        ("m", .memory, .memoryProvider),
        ("g", .modelGenerated, .model)
    ]
    for fixture in fixtures {
        try await service.store(
            makeCompilerItem(tenant: principal, key: fixture.0, trust: fixture.1, origin: fixture.2, observedAt: now),
            for: principal
        )
    }

    let request = try ContextCompilationRequest(
        role: .reasoning,
        includeUserScope: true,
        includeExternalContent: true,
        includeMemory: true,
        includeModelGenerated: true,
        budget: ContextCompilationBudget()
    )
    let compiled = try await compiler.compile(request, for: principal, at: now)
    #expect(Set(compiled.items.map(\.trust)) == Set(fixtures.map { $0.1 }))
    #expect(Set(compiled.items.map(\.origin)) == Set(fixtures.map { $0.2 }))
}

@Test func allowedKeysAndItemBudgetAreAppliedAfterPolicyWithNewestFirstOrdering() async throws {
    let service = try makeCompilerService()
    let compiler = ContextCompiler(service: service)
    let principal = TenantContext(tenantID: UUID(), userID: UUID())
    let base = Date(timeIntervalSince1970: 1_000)
    for index in 0..<4 {
        try await service.store(
            makeCompilerItem(
                tenant: principal,
                key: index == 0 ? "ignored" : "event",
                trust: .systemState,
                origin: .system,
                observedAt: base.addingTimeInterval(Double(index)),
                value: .integer(Int64(index))
            ),
            for: principal
        )
    }

    let request = try ContextCompilationRequest(
        role: .realtime,
        includeUserScope: true,
        allowedKeys: ["event"],
        budget: ContextCompilationBudget(maxItems: 2, maxEncodedBytes: 64 * 1024)
    )
    let compiled = try await compiler.compile(request, for: principal, at: base.addingTimeInterval(10))

    #expect(compiled.items.map(\.value) == [.integer(3), .integer(2)])
    #expect(compiled.stats.considered == 4)
    #expect(compiled.stats.excludedByPolicy == 1)
    #expect(compiled.stats.excludedByBudget == 1)
}

@Test func byteBudgetDropsOversizedItemsWithoutLeakingPartialValues() async throws {
    let service = try makeCompilerService()
    let compiler = ContextCompiler(service: service)
    let principal = TenantContext(tenantID: UUID(), userID: UUID())
    let now = Date(timeIntervalSince1970: 1_000)
    try await service.store(
        makeCompilerItem(
            tenant: principal,
            key: "huge",
            trust: .systemState,
            origin: .system,
            observedAt: now,
            value: .string(String(repeating: "x", count: 10_000))
        ),
        for: principal
    )

    let request = try ContextCompilationRequest(
        role: .realtime,
        includeUserScope: true,
        budget: ContextCompilationBudget(maxItems: 10, maxEncodedBytes: 256)
    )
    let compiled = try await compiler.compile(request, for: principal, at: now)
    #expect(compiled.items.isEmpty)
    #expect(compiled.stats.excludedByBudget == 1)
    #expect(compiled.stats.estimatedEncodedBytes == 0)
}

@Test func compilerCannotCrossPrincipalPartitions() async throws {
    let service = try makeCompilerService()
    let compiler = ContextCompiler(service: service)
    let a = TenantContext(tenantID: UUID(), userID: UUID())
    let b = TenantContext(tenantID: UUID(), userID: UUID())
    let now = Date(timeIntervalSince1970: 1_000)
    try await service.store(
        makeCompilerItem(tenant: a, key: "canary", trust: .systemState, origin: .system, observedAt: now, value: .string("ALPHA-PINEAPPLE-7834")),
        for: a
    )
    try await service.store(
        makeCompilerItem(tenant: b, key: "canary", trust: .systemState, origin: .system, observedAt: now, value: .string("BETA-ZEBRA-9911")),
        for: b
    )
    let request = try ContextCompilationRequest(role: .realtime, includeUserScope: true, budget: ContextCompilationBudget())
    let aCompiled = try await compiler.compile(request, for: a, at: now)
    let bCompiled = try await compiler.compile(request, for: b, at: now)
    #expect(aCompiled.items.map(\.value) == [.string("ALPHA-PINEAPPLE-7834")])
    #expect(bCompiled.items.map(\.value) == [.string("BETA-ZEBRA-9911")])
}

@Test func compilationBoundsRejectInvalidConfiguration() throws {
    #expect(throws: ContextCompilationError.invalidMaxItems) {
        _ = try ContextCompilationBudget(maxItems: 0)
    }
    #expect(throws: ContextCompilationError.invalidMaxItems) {
        _ = try ContextCompilationBudget(maxItems: 101)
    }
    #expect(throws: ContextCompilationError.invalidByteBudget) {
        _ = try ContextCompilationBudget(maxEncodedBytes: 255)
    }
    #expect(throws: ContextCompilationError.invalidAllowedKey) {
        _ = try ContextCompilationRequest(
            role: .realtime,
            allowedKeys: ["   "],
            budget: ContextCompilationBudget()
        )
    }
}
