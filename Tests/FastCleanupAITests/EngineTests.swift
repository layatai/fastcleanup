import XCTest
import FastCleanupCore
@testable import FastCleanupAI

private func snapshot() -> ScanSnapshot {
    ScanSnapshot(id: UUID(), candidates: [CleanupCandidate(id: "c0", url: URL(fileURLWithPath: "/Users/fixture/Library/Caches/a"),
        categoryID: "app-caches", kind: .cache, allocatedBytes: 100, evidence: [.cacheLocation, .activityUnknown], stamp: FileStamp(entries: []))])
}
private enum StubError: Error { case refused }
private actor Provider: LocalRecommendationProvider {
    enum Behavior: Sendable { case success, forged, refused, slow, unavailable }
    let behavior: Behavior
    var calls = 0
    init(_ behavior: Behavior) { self.behavior = behavior }
    func availability() async -> ModelAvailability { behavior == .unavailable ? .unavailable("not ready") : .available }
    func recommend(_ request: RecommendationRequest) async throws -> ModelAdvice {
        calls += 1
        if behavior == .refused { throw StubError.refused }
        if behavior == .slow { try await Task.sleep(nanoseconds: 60_000_000_000) }
        return ModelAdvice(snapshotID: request.snapshotID, items: [.init(candidateID: behavior == .forged ? "forged" : "c0", disposition: .review, reason: .cacheReview)])
    }
}
final class EngineTests: XCTestCase {
    func testUnavailableDoesNotCallModel() async throws {
        let provider = Provider(.unavailable)
        let ownEngine = RecommendationEngine(provider: provider)
        let result = try await ownEngine.analyze(snapshot())
        let calls = await provider.calls
        XCTAssertEqual(calls, 0); XCTAssertFalse(result.recommendations[0].appleRanked)
    }
    func testValidAdviceIsAppleRanked() async throws {
        let result = try await RecommendationEngine(provider: Provider(.success)).analyze(snapshot())
        XCTAssertTrue(result.recommendations[0].appleRanked)
    }
    func testForgedAdviceAndRefusalFallBack() async throws {
        for behavior in [Provider.Behavior.forged, .refused] {
            let result = try await RecommendationEngine(provider: Provider(behavior)).analyze(snapshot())
            XCTAssertFalse(result.recommendations[0].appleRanked)
            XCTAssertTrue(result.message.contains("rules-based"))
        }
    }
    func testTimeoutFallsBackAndCancelsCooperativeProvider() async throws {
        let result = try await RecommendationEngine(provider: Provider(.slow), timeoutNanoseconds: 1_000_000).analyze(snapshot())
        XCTAssertTrue(result.message.contains("timed out")); XCTAssertFalse(result.recommendations[0].appleRanked)
    }
    func testCancellationIsNotPublishedAsSuccess() async throws {
        let engine = RecommendationEngine(provider: Provider(.slow))
        let task = Task { try await engine.analyze(snapshot()) }
        try await Task.sleep(nanoseconds: 1_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("cancellation ignored") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testAppleAdapterUnavailableOnUnsupportedBuild() async throws {
        #if !canImport(FoundationModels) || FASTCLEANUP_DISABLE_APPLE_AI
        let provider = AppleModelProvider()
        let state = await provider.availability(); XCTAssertFalse(state.isAvailable)
        do { _ = try await provider.recommend(RecommendationRequest(snapshot: snapshot())); XCTFail() } catch { }
        #endif
    }
}
