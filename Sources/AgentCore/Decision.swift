import Foundation

public struct DecisionOption: Codable, Sendable, Equatable {
    public let id: String
    public let summary: String
    public let metadata: JSONValue

    public init(id: String, summary: String, metadata: JSONValue = .object([:])) {
        self.id = id
        self.summary = summary
        self.metadata = metadata
    }
}

public struct DecisionRequest: Codable, Sendable, Equatable {
    public let id: UUID
    public let objective: String
    public let state: JSONValue
    public let options: [DecisionOption]

    public init(id: UUID = UUID(), objective: String, state: JSONValue = .object([:]),
                options: [DecisionOption]) {
        self.id = id
        self.objective = objective
        self.state = state
        self.options = options
    }
}

public struct ProviderDecision: Codable, Sendable, Equatable {
    public let selectedOptionID: String
    public let confidence: Double
    public let scores: [String: Double]

    public init(selectedOptionID: String, confidence: Double,
                scores: [String: Double] = [:]) {
        self.selectedOptionID = selectedOptionID
        self.confidence = confidence
        self.scores = scores
    }
}

public protocol DecisionProvider: Sendable {
    var providerID: String { get }
    func decide(_ request: DecisionRequest) async throws -> ProviderDecision
}

public struct DecisionRule: Sendable {
    public let id: String
    private let evaluateBlock: @Sendable (DecisionRequest) -> ProviderDecision?

    public init(id: String,
                evaluate: @escaping @Sendable (DecisionRequest) -> ProviderDecision?) {
        self.id = id
        self.evaluateBlock = evaluate
    }

    func evaluate(_ request: DecisionRequest) -> ProviderDecision? {
        evaluateBlock(request)
    }
}

public enum DecisionSourceKind: String, Codable, Sendable {
    case rule
    case boundedProvider = "bounded_provider"
    case reasoningProvider = "reasoning_provider"
}

public struct DecisionSource: Codable, Sendable, Equatable {
    public let kind: DecisionSourceKind
    public let identifier: String

    public init(kind: DecisionSourceKind, identifier: String) {
        self.kind = kind
        self.identifier = identifier
    }
}

public struct DecisionOutcome: Codable, Sendable, Equatable {
    public let decision: ProviderDecision
    public let source: DecisionSource

    public init(decision: ProviderDecision, source: DecisionSource) {
        self.decision = decision
        self.source = source
    }
}

public enum DecisionError: Error, Sendable, Equatable {
    case noOptions
    case duplicateOptionID(String)
    case invalidSelection(String)
    case invalidConfidence(Double)
    case invalidScore(optionID: String, score: Double)
    case unknownScoreOption(String)
    case insufficientConfidence(required: Double, actual: Double)
}

/// Provider-neutral policy for small decisions inside the orchestrator.
/// Deterministic rules run first. Bounded providers (for example Jev) handle
/// constrained choices. A reasoning provider is used only when bounded output
/// is unavailable or below the configured confidence threshold.
public struct DecisionEngine: Sendable {
    private let rules: [DecisionRule]
    private let boundedProvider: any DecisionProvider
    private let reasoningProvider: (any DecisionProvider)?
    private let boundedConfidenceThreshold: Double

    public init(rules: [DecisionRule] = [],
                boundedProvider: any DecisionProvider,
                reasoningProvider: (any DecisionProvider)? = nil,
                boundedConfidenceThreshold: Double = 0.75) {
        self.rules = rules
        self.boundedProvider = boundedProvider
        self.reasoningProvider = reasoningProvider
        self.boundedConfidenceThreshold = boundedConfidenceThreshold
    }

    public func decide(_ request: DecisionRequest) async throws -> DecisionOutcome {
        try validateRequest(request)

        if request.options.count == 1 {
            let choice = ProviderDecision(selectedOptionID: request.options[0].id,
                                          confidence: 1.0,
                                          scores: [request.options[0].id: 1.0])
            return DecisionOutcome(decision: choice,
                                   source: DecisionSource(kind: .rule,
                                                          identifier: "single_option"))
        }

        for rule in rules {
            if let choice = rule.evaluate(request) {
                try validate(choice, for: request)
                return DecisionOutcome(decision: choice,
                                       source: DecisionSource(kind: .rule,
                                                              identifier: rule.id))
            }
        }

        do {
            let bounded = try await boundedProvider.decide(request)
            try validate(bounded, for: request)
            if bounded.confidence >= boundedConfidenceThreshold {
                return DecisionOutcome(
                    decision: bounded,
                    source: DecisionSource(kind: .boundedProvider,
                                           identifier: boundedProvider.providerID)
                )
            }
            guard let reasoningProvider else {
                throw DecisionError.insufficientConfidence(
                    required: boundedConfidenceThreshold,
                    actual: bounded.confidence
                )
            }
            return try await reasoningOutcome(for: request, using: reasoningProvider)
        } catch let error as DecisionError {
            if case .insufficientConfidence = error { throw error }
            guard let reasoningProvider else { throw error }
            return try await reasoningOutcome(for: request, using: reasoningProvider)
        } catch {
            guard let reasoningProvider else { throw error }
            return try await reasoningOutcome(for: request, using: reasoningProvider)
        }
    }

    private func reasoningOutcome(for request: DecisionRequest,
                                  using provider: any DecisionProvider) async throws -> DecisionOutcome {
        let choice = try await provider.decide(request)
        try validate(choice, for: request)
        return DecisionOutcome(
            decision: choice,
            source: DecisionSource(kind: .reasoningProvider,
                                   identifier: provider.providerID)
        )
    }

    private func validateRequest(_ request: DecisionRequest) throws {
        guard !request.options.isEmpty else { throw DecisionError.noOptions }
        var seen = Set<String>()
        for option in request.options {
            guard seen.insert(option.id).inserted else {
                throw DecisionError.duplicateOptionID(option.id)
            }
        }
    }

    private func validate(_ decision: ProviderDecision,
                          for request: DecisionRequest) throws {
        let optionIDs = Set(request.options.map(\.id))
        guard optionIDs.contains(decision.selectedOptionID) else {
            throw DecisionError.invalidSelection(decision.selectedOptionID)
        }
        guard decision.confidence.isFinite,
              (0.0...1.0).contains(decision.confidence) else {
            throw DecisionError.invalidConfidence(decision.confidence)
        }
        for (optionID, score) in decision.scores {
            guard optionIDs.contains(optionID) else {
                throw DecisionError.unknownScoreOption(optionID)
            }
            guard score.isFinite, (0.0...1.0).contains(score) else {
                throw DecisionError.invalidScore(optionID: optionID, score: score)
            }
        }
    }
}
