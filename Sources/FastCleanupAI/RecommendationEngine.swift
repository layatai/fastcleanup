import Foundation
import FastCleanupCore

public struct RecommendationResult: Sendable {
    public let recommendations: [Recommendation]
    public let message: String
}
private enum InferenceFailure: Error { case timedOut }

public actor RecommendationEngine {
    private var inFlight = false
    private let provider: any LocalRecommendationProvider
    private let timeoutNanoseconds: UInt64
    public init(provider: any LocalRecommendationProvider = AppleModelProvider(), timeoutNanoseconds: UInt64 = 20_000_000_000) {
        self.provider = provider; self.timeoutNanoseconds = timeoutNanoseconds
    }

    /// Only call after the user explicitly asks for Apple analysis. Availability checks do not generate.
    public func analyze(_ snapshot: ScanSnapshot) async throws -> RecommendationResult {
        try Task.checkCancellation()
        let baseline = RulesPlanner.recommendations(for: snapshot)
        guard !inFlight else { return RecommendationResult(recommendations: baseline, message: "The previous Apple analysis is finishing. Showing rules-based results.") }
        guard !snapshot.candidates.isEmpty else { return RecommendationResult(recommendations: [], message: "No supported candidates to analyze.") }
        inFlight = true
        defer { inFlight = false }
        let availability = await provider.availability()
        try Task.checkCancellation()
        guard availability.isAvailable else { return RecommendationResult(recommendations: baseline, message: availability.message) }
        let request = RecommendationRequest(snapshot: snapshot)
        do {
            _ = try request.prompt() // Enforce the payload bound for every provider, including test doubles.
            let provider = self.provider, timeout = timeoutNanoseconds
            let advice = try await withThrowingTaskGroup(of: ModelAdvice.self) { group in
                group.addTask { try await provider.recommend(request) }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeout)
                    throw InferenceFailure.timedOut
                }
                defer { group.cancelAll() }
                guard let value = try await group.next() else { throw InferenceFailure.timedOut }
                return value
            }
            try Task.checkCancellation()
            let rows = try AdviceValidator.validate(advice, request: request, snapshot: snapshot)
            return RecommendationResult(recommendations: rows, message: "Apple ranked up to eight candidates on this Mac. All items still require manual review.")
        } catch {
            try Task.checkCancellation()
            // Never log prompts, paths, transcripts, or potentially sensitive framework error payloads.
            let message = error is InferenceFailure ? "Apple analysis timed out. Showing rules-based results." :
                "Apple analysis could not produce validated advice. Showing rules-based results."
            return RecommendationResult(recommendations: baseline, message: message)
        }
    }
}
