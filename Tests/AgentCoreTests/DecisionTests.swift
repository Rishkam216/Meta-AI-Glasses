import Foundation
import Testing
@testable import AgentCore

private enum StubDecisionError: Error, Sendable { case failure }

private actor StubDecisionProvider: DecisionProvider {
    nonisolated let providerID: String
    private let response: ProviderDecision
    private let shouldFail: Bool
    private(set) var requests: [DecisionRequest] = []

    init(id: String, response: ProviderDecision, shouldFail: Bool = false) {
        providerID = id
        self.response = response
        self.shouldFail = shouldFail
    }

    func decide(_ request: DecisionRequest) throws -> ProviderDecision {
        requests.append(request)
        if shouldFail { throw StubDecisionError.failure }
        return response
    }

    var callCount: Int { requests.count }
}

private func decisionRequest() -> DecisionRequest {
    DecisionRequest(
        objective: "Choose next action",
        state: .object(["status": .string("ready")]),
        options: [
            DecisionOption(id: "inspect", summary: "Inspect logs"),
            DecisionOption(id: "retry", summary: "Retry operation")
        ]
    )
}

@Test func singleOptionUsesDeterministicRuleWithoutProvider() async throws {
    let bounded = StubDecisionProvider(id: "bounded",
        response: ProviderDecision(selectedOptionID: "only", confidence: 0.9))
    let engine = DecisionEngine(boundedProvider: bounded)
    let request = DecisionRequest(objective: "Only choice",
                                  options: [DecisionOption(id: "only", summary: "Only")])

    let outcome = try await engine.decide(request)
    #expect(outcome.decision.selectedOptionID == "only")
    #expect(outcome.source == DecisionSource(kind: .rule, identifier: "single_option"))
    #expect(await bounded.callCount == 0)
}

@Test func deterministicRuleRunsBeforeBoundedProvider() async throws {
    let bounded = StubDecisionProvider(id: "jev",
        response: ProviderDecision(selectedOptionID: "retry", confidence: 0.99))
    let rule = DecisionRule(id: "known_status") { request in
        guard request.state == .object(["status": .string("ready")]) else { return nil }
        return ProviderDecision(selectedOptionID: "inspect", confidence: 1.0)
    }
    let engine = DecisionEngine(rules: [rule], boundedProvider: bounded)

    let outcome = try await engine.decide(decisionRequest())
    #expect(outcome.decision.selectedOptionID == "inspect")
    #expect(outcome.source == DecisionSource(kind: .rule, identifier: "known_status"))
    #expect(await bounded.callCount == 0)
}

@Test func confidentBoundedDecisionAvoidsReasoningProvider() async throws {
    let bounded = StubDecisionProvider(id: "jev",
        response: ProviderDecision(selectedOptionID: "inspect", confidence: 0.91,
                                   scores: ["inspect": 0.91, "retry": 0.09]))
    let reasoning = StubDecisionProvider(id: "reasoning",
        response: ProviderDecision(selectedOptionID: "retry", confidence: 0.8))
    let engine = DecisionEngine(boundedProvider: bounded, reasoningProvider: reasoning,
                                boundedConfidenceThreshold: 0.75)

    let outcome = try await engine.decide(decisionRequest())
    #expect(outcome.decision.selectedOptionID == "inspect")
    #expect(outcome.source == DecisionSource(kind: .boundedProvider, identifier: "jev"))
    #expect(await bounded.callCount == 1)
    #expect(await reasoning.callCount == 0)
}

@Test func lowConfidenceBoundedDecisionEscalatesToReasoning() async throws {
    let bounded = StubDecisionProvider(id: "jev",
        response: ProviderDecision(selectedOptionID: "inspect", confidence: 0.55))
    let reasoning = StubDecisionProvider(id: "reasoning",
        response: ProviderDecision(selectedOptionID: "retry", confidence: 0.88))
    let engine = DecisionEngine(boundedProvider: bounded, reasoningProvider: reasoning,
                                boundedConfidenceThreshold: 0.75)

    let outcome = try await engine.decide(decisionRequest())
    #expect(outcome.decision.selectedOptionID == "retry")
    #expect(outcome.source == DecisionSource(kind: .reasoningProvider,
                                             identifier: "reasoning"))
    #expect(await bounded.callCount == 1)
    #expect(await reasoning.callCount == 1)
}

@Test func boundedProviderFailureEscalatesToReasoning() async throws {
    let bounded = StubDecisionProvider(id: "jev",
        response: ProviderDecision(selectedOptionID: "inspect", confidence: 0.9),
        shouldFail: true)
    let reasoning = StubDecisionProvider(id: "reasoning",
        response: ProviderDecision(selectedOptionID: "retry", confidence: 0.8))
    let engine = DecisionEngine(boundedProvider: bounded, reasoningProvider: reasoning)

    let outcome = try await engine.decide(decisionRequest())
    #expect(outcome.decision.selectedOptionID == "retry")
    #expect(await bounded.callCount == 1)
    #expect(await reasoning.callCount == 1)
}

@Test func providerCannotInventAnOption() async throws {
    let bounded = StubDecisionProvider(id: "jev",
        response: ProviderDecision(selectedOptionID: "delete_everything", confidence: 0.99))
    let engine = DecisionEngine(boundedProvider: bounded)

    do {
        _ = try await engine.decide(decisionRequest())
        Issue.record("Provider invented an option")
    } catch let error as DecisionError {
        #expect(error == .invalidSelection("delete_everything"))
    }
}

@Test func lowConfidenceWithoutFallbackFailsClosed() async throws {
    let bounded = StubDecisionProvider(id: "jev",
        response: ProviderDecision(selectedOptionID: "inspect", confidence: 0.40))
    let engine = DecisionEngine(boundedProvider: bounded,
                                boundedConfidenceThreshold: 0.75)

    do {
        _ = try await engine.decide(decisionRequest())
        Issue.record("Low-confidence bounded decision was accepted")
    } catch let error as DecisionError {
        #expect(error == .insufficientConfidence(required: 0.75, actual: 0.40))
    }
}
