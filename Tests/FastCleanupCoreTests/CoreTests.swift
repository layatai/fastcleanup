import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import FastCleanupCore

private let home = URL(fileURLWithPath: "/Users/fixture")
private func stamp(_ version: Int64 = 1, child: String = "") -> FileStamp {
    FileStamp(entries: [.init(relativePath: child, device: 1, inode: UInt64(version), mode: 0, size: 1,
        modifiedSeconds: version, modifiedNanos: 0, changedSeconds: version, changedNanos: 0)])
}
private func candidate(_ id: String = "c0", path: String = "Library/Caches/example", version: Int64 = 1,
                       kind: CandidateKind = .cache, evidence: [Evidence] = [.cacheLocation, .activityUnknown]) -> CleanupCandidate {
    CleanupCandidate(id: id, url: home.appendingPathComponent(path), categoryID: "app-caches", kind: kind,
                     allocatedBytes: 100, evidence: evidence, stamp: stamp(version))
}

final class PolicyTests: XCTestCase {
    func testComponentBoundaries() {
        XCTAssertFalse(PathRules.contains(home, URL(fileURLWithPath: "/Users/fixture-other/cache")))
        XCTAssertTrue(PathRules.contains(home, home.appendingPathComponent("Library/Caches/x")))
    }
    func testProtectedModelsAndAncestors() {
        let policy = PathProtection(home: home)
        for path in [".cache/huggingface", ".cache", "Library/CloudStorage/cache", ".ssh", "Library/Application Support/FastCleanup"] {
            XCTAssertFalse(policy.allows(home.appendingPathComponent(path)), path)
        }
        XCTAssertFalse(policy.allows(home))
        XCTAssertFalse(policy.allows(URL(fileURLWithPath: "/System/cache")))
        XCTAssertTrue(policy.allows(home.appendingPathComponent("Library/Caches/example")))
    }
    func testExclusionsProtectAncestorsAndCaseVariants() {
        let policy = PathProtection(home: home, excluded: [home.appendingPathComponent("projects/Keep/build")])
        XCTAssertFalse(policy.allows(home.appendingPathComponent("projects/keep")))
        XCTAssertFalse(policy.allows(home.appendingPathComponent("projects/KEEP/build/sub")))
        XCTAssertTrue(policy.allows(home.appendingPathComponent("projects/keep-other")))
    }
    func testProtectedDescendantCannotBeHidden() {
        XCTAssertThrowsError(try PathProtection(home: home).validate(home.appendingPathComponent("projects/cache"), stamp: stamp(child: ".git")))
    }
    func testAmbiguousOverlapsAreNotExecutableTogether() {
        let items = [candidate("a", path: "project/node_modules"), candidate("b", path: "project/node_modules/dist"), candidate("c", path: "Library/Caches/other")]
        XCTAssertEqual(CandidateNormalizer.disjoint(items).map(\.id), ["c"])
    }
    func testExactDuplicateIsCountedOnce() {
        XCTAssertEqual(CandidateNormalizer.disjoint([candidate("a"), candidate("b")]).count, 1)
    }
}

final class AdviceTests: XCTestCase {
    func testPayloadHasNoPathsOrNamesAndIsBounded() throws {
        let items = (0..<30).map { candidate("c\($0)", path: "private-secret-ignore-instructions-\($0)") }
        let request = RecommendationRequest(snapshot: ScanSnapshot(id: UUID(), candidates: items))
        let text = try request.prompt()
        XCTAssertEqual(request.items.count, 8)
        XCTAssertLessThanOrEqual(text.utf8.count, RecommendationRequest.maximumPromptBytes)
        XCTAssertFalse(text.contains("private-secret")); XCTAssertFalse(text.contains("/Users"))
    }
    func testUnknownCandidateRejected() {
        let snapshot = ScanSnapshot(id: UUID(), candidates: [candidate()])
        XCTAssertThrowsError(try AdviceValidator.validate(ModelAdvice(snapshotID: snapshot.id.uuidString,
            items: [.init(candidateID: "delete-documents", disposition: .review, reason: .cacheReview)]),
            request: RecommendationRequest(snapshot: snapshot), snapshot: snapshot)) { XCTAssertEqual($0 as? AdviceError, .unknownCandidate) }
    }
    func testStaleSnapshotRejected() {
        let snapshot = ScanSnapshot(id: UUID(), candidates: [candidate()])
        XCTAssertThrowsError(try AdviceValidator.validate(ModelAdvice(snapshotID: UUID().uuidString, items: []),
            request: RecommendationRequest(snapshot: snapshot), snapshot: snapshot)) { XCTAssertEqual($0 as? AdviceError, .staleSnapshot) }
    }
    func testDuplicateAndUnsupportedReasonRejected() {
        let snapshot = ScanSnapshot(id: UUID(), candidates: [candidate(), candidate("c1", path: "Library/Caches/other")])
        let request = RecommendationRequest(snapshot: snapshot)
        let item = ModelAdvice.Item(candidateID: "c0", disposition: .review, reason: .cacheReview)
        XCTAssertThrowsError(try AdviceValidator.validate(ModelAdvice(snapshotID: snapshot.id.uuidString, items: [item, item]), request: request, snapshot: snapshot)) { XCTAssertEqual($0 as? AdviceError, .duplicateCandidate) }
        XCTAssertThrowsError(try AdviceValidator.validate(ModelAdvice(snapshotID: snapshot.id.uuidString,
            items: [.init(candidateID: "c0", disposition: .review, reason: .downloadCost)]), request: request, snapshot: snapshot)) { XCTAssertEqual($0 as? AdviceError, .unsupportedReason) }
    }
    func testOmittedCandidatesRemainRulesBased() throws {
        let snapshot = ScanSnapshot(id: UUID(), candidates: [candidate(), candidate("c1", path: "Library/Caches/other")])
        let rows = try AdviceValidator.validate(ModelAdvice(snapshotID: snapshot.id.uuidString,
            items: [.init(candidateID: "c1", disposition: .keep, reason: .uncertainUse)]), request: RecommendationRequest(snapshot: snapshot), snapshot: snapshot)
        XCTAssertEqual(rows.map(\.candidateID), ["c1", "c0"])
        XCTAssertTrue(rows[0].appleRanked); XCTAssertFalse(rows[1].appleRanked)
    }
    func testRecentIsNotCalledInactiveAndNeverAutoSelected() {
        let c = candidate(evidence: [.cacheLocation, .recentlyModified, .activityUnknown])
        let rows = RulesPlanner.recommendations(for: ScanSnapshot(id: UUID(), candidates: [c]))
        XCTAssertEqual(rows[0].disposition, .keep)
        XCTAssertEqual(rows[0].reason, .recentChanges)
    }
}

private final class FakeFS: CleanupFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [URL: FileStamp]
    private var moves: [URL] = []
    init(_ candidates: [CleanupCandidate]) { files = Dictionary(uniqueKeysWithValues: candidates.map { ($0.url, $0.stamp) }) }
    var moved: [URL] { lock.lock(); defer { lock.unlock() }; return moves }
    func change(_ url: URL, to stamp: FileStamp) { lock.lock(); defer { lock.unlock() }; files[url] = stamp }
    func stamp(_ url: URL) throws -> FileStamp {
        lock.lock(); defer { lock.unlock() }
        guard let value = files[url] else { throw CleanupError.unreadableFile }; return value
    }
    func moveToTrash(_ url: URL) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        let destination = home.appendingPathComponent(".Trash/\(UUID().uuidString)")
        guard let value = files.removeValue(forKey: url) else { throw CleanupError.unreadableFile }
        moves.append(url); files[destination] = value; return destination
    }
    func restore(from trash: URL, to original: URL) throws {
        lock.lock(); defer { lock.unlock() }
        guard files[original] == nil else { throw CleanupError.destinationExists }
        guard let value = files.removeValue(forKey: trash) else { throw CleanupError.unreadableFile }
        files[original] = value
    }
}
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 100)
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance() { lock.lock(); defer { lock.unlock() }; date = date.addingTimeInterval(301) }
}
final class CleanupServiceTests: XCTestCase {
    func testOnlyExplicitSelectionMovesAndPlanIsSingleUse() async throws {
        let a = candidate(), b = candidate("b", path: "Library/Caches/b")
        let fs = FakeFS([a, b]), snapshot = ScanSnapshot(id: UUID(), candidates: [a, b])
        let service = CleanupService(fileSystem: fs), policy = PathProtection(home: home)
        let plan = try await service.prepare(snapshot: snapshot, selectedIDs: [a.id], currentSnapshotID: snapshot.id, protection: policy)
        let report = try await service.execute(planID: plan.id, currentSnapshotID: snapshot.id, protection: policy)
        XCTAssertEqual(fs.moved, [a.url]); XCTAssertEqual(report.movedBytes, 100)
        do { _ = try await service.execute(planID: plan.id, currentSnapshotID: snapshot.id, protection: policy); XCTFail("replayed") }
        catch { XCTAssertEqual(error as? CleanupError, .unknownPlan) }
    }
    func testChangedFileStopsWholePlanBeforeAnyMove() async throws {
        let a = candidate(), b = candidate("b", path: "Library/Caches/b")
        let fs = FakeFS([a, b]), snapshot = ScanSnapshot(id: UUID(), candidates: [a, b])
        let service = CleanupService(fileSystem: fs), policy = PathProtection(home: home)
        let plan = try await service.prepare(snapshot: snapshot, selectedIDs: [a.id, b.id], currentSnapshotID: snapshot.id, protection: policy)
        fs.change(b.url, to: stamp(2))
        do { _ = try await service.execute(planID: plan.id, currentSnapshotID: snapshot.id, protection: policy); XCTFail("changed file accepted") }
        catch { XCTAssertEqual(error as? CleanupError, .changedFile) }
        XCTAssertTrue(fs.moved.isEmpty)
    }
    func testNewExclusionStopsApprovedPlan() async throws {
        let a = candidate(), fs = FakeFS([candidate()]), snapshot = ScanSnapshot(id: UUID(), candidates: [candidate()])
        let service = CleanupService(fileSystem: fs)
        let plan = try await service.prepare(snapshot: snapshot, selectedIDs: [a.id], currentSnapshotID: snapshot.id, protection: PathProtection(home: home))
        do { _ = try await service.execute(planID: plan.id, currentSnapshotID: snapshot.id, protection: PathProtection(home: home, excluded: [a.url])); XCTFail("exclusion ignored") }
        catch { XCTAssertEqual(error as? CleanupError, .protectedPath) }
        XCTAssertTrue(fs.moved.isEmpty)
    }
    func testStaleSnapshotAndUnknownSelectionRejected() async {
        let a = candidate(), snapshot = ScanSnapshot(id: UUID(), candidates: [candidate()])
        let service = CleanupService(fileSystem: FakeFS([a]))
        do { _ = try await service.prepare(snapshot: snapshot, selectedIDs: [a.id], currentSnapshotID: UUID(), protection: PathProtection(home: home)); XCTFail() }
        catch { XCTAssertEqual(error as? CleanupError, .stalePlan) }
        do { _ = try await service.prepare(snapshot: snapshot, selectedIDs: ["forged"], currentSnapshotID: snapshot.id, protection: PathProtection(home: home)); XCTFail() }
        catch { XCTAssertEqual(error as? CleanupError, .invalidSelection) }
    }
    func testExpiredPlanCannotExecute() async throws {
        let a = candidate(), clock = TestClock(), fs = FakeFS([candidate()])
        let snapshot = ScanSnapshot(id: UUID(), candidates: [a]), policy = PathProtection(home: home)
        let service = CleanupService(fileSystem: fs, now: { clock.read() })
        let plan = try await service.prepare(snapshot: snapshot, selectedIDs: [a.id], currentSnapshotID: snapshot.id, protection: policy)
        clock.advance()
        do { _ = try await service.execute(planID: plan.id, currentSnapshotID: snapshot.id, protection: policy); XCTFail() }
        catch { XCTAssertEqual(error as? CleanupError, .expiredPlan) }
        XCTAssertTrue(fs.moved.isEmpty)
    }
    func testRestoreDoesNotOverwrite() async throws {
        let a = candidate(), fs = FakeFS([candidate()]), snapshot = ScanSnapshot(id: UUID(), candidates: [candidate()])
        let service = CleanupService(fileSystem: fs), policy = PathProtection(home: home)
        let plan = try await service.prepare(snapshot: snapshot, selectedIDs: [a.id], currentSnapshotID: snapshot.id, protection: policy)
        let report = try await service.execute(planID: plan.id, currentSnapshotID: snapshot.id, protection: policy)
        fs.change(a.url, to: stamp(2))
        do { try await service.restore(recordID: report.moved[0].id, protection: policy); XCTFail() }
        catch { XCTAssertEqual(error as? CleanupError, .destinationExists) }
        XCTAssertEqual(try fs.stamp(a.url), stamp(2))
    }
    func testRestoreOfUnchangedItemWorks() async throws {
        let a = candidate(), fs = FakeFS([candidate()]), snapshot = ScanSnapshot(id: UUID(), candidates: [candidate()])
        let service = CleanupService(fileSystem: fs), policy = PathProtection(home: home)
        let plan = try await service.prepare(snapshot: snapshot, selectedIDs: [a.id], currentSnapshotID: snapshot.id, protection: policy)
        let report = try await service.execute(planID: plan.id, currentSnapshotID: snapshot.id, protection: policy)
        try await service.restore(recordID: report.moved[0].id, protection: policy)
        XCTAssertEqual(try fs.stamp(a.url), a.stamp)
        let history = await service.history(); XCTAssertTrue(history.isEmpty)
    }
}

final class LocalFileSystemTests: XCTestCase {
    private func withFixture(_ body: (URL) throws -> Void) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        // POSIX realpath preserves /private; Foundation may shorten it back to /var.
        guard let physical = realpath(temporary.path, nil) else { throw CleanupError.unreadableFile }
        defer { free(physical) }
        let root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
        try body(root)
    }
    func testDetectsNestedEditsNotJustRootMtime() throws {
        try withFixture { root in
            let nested = root.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let file = nested.appendingPathComponent("data"); try Data("one".utf8).write(to: file)
            let fs = LocalCleanupFileSystem(), before = try fs.stamp(root)
            try Data("two".utf8).write(to: file)
            XCTAssertNotEqual(try fs.stamp(root), before)
        }
    }
    func testRejectsSymlinkAndSymlinkAncestor() throws {
        try withFixture { root in
            let target = root.appendingPathComponent("target")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let link = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let file = target.appendingPathComponent("data"); try Data("x".utf8).write(to: file)
            XCTAssertThrowsError(try LocalCleanupFileSystem().stamp(root))
            XCTAssertThrowsError(try LocalCleanupFileSystem().stamp(link.appendingPathComponent("data")))
        }
    }
    func testRejectsHardlinksAndInspectionOverflow() throws {
        try withFixture { root in
            let file = root.appendingPathComponent("a"); try Data("x".utf8).write(to: file)
            XCTAssertThrowsError(try LocalCleanupFileSystem(maximumEntries: 1).stamp(root))
            try FileManager.default.linkItem(at: file, to: root.appendingPathComponent("b"))
            XCTAssertThrowsError(try LocalCleanupFileSystem().stamp(root))
        }
    }
}

final class RecipeTests: XCTestCase {
    func testNameAloneNeverAuthorizesBuildOutput() {
        for name in ["dist", "target", "__pycache__"] {
            XCTAssertNil(CleanupRecipe.kind(categoryID: "build-artifacts", directoryName: name, manifests: []))
        }
    }
    func testManifestMustMatchEcosystem() {
        XCTAssertNil(CleanupRecipe.kind(categoryID: "build-artifacts", directoryName: "target", manifests: ["package.json"]))
        XCTAssertEqual(CleanupRecipe.kind(categoryID: "build-artifacts", directoryName: "target", manifests: ["Cargo.toml"]), .buildOutput)
        XCTAssertEqual(CleanupRecipe.kind(categoryID: "node-modules", directoryName: "node_modules", manifests: ["package.json"]), .dependencies)
    }
    func testDangerousCategoriesNeverBecomeSmartCandidates() {
        for category in ["git-repos", "ai-models", "container-vms", "large-files", "old-downloads", "editor-state-backups", "docker-volume-prune"] {
            XCTAssertNil(CleanupRecipe.kind(categoryID: category, directoryName: "cache", manifests: ["package.json"]))
        }
    }
    func testManualReviewDoesNotRemoveHardProtections() {
        let policy = PathProtection(home: home, includeReviewOnlyRoots: false)
        XCTAssertTrue(policy.allows(home.appendingPathComponent(".ollama/models")))
        XCTAssertFalse(policy.allows(home.appendingPathComponent(".ssh")))
        XCTAssertFalse(policy.allows(home.appendingPathComponent("Library/Application Support/FastCleanup")))
    }
    func testXcodeBuildEvidenceSupportsOnlyBuildReason() {
        let c = candidate(kind: .buildOutput, evidence: [.buildLocation, .activityUnknown])
        XCTAssertTrue(RecommendationReason.rebuildCost.isSupported(by: c))
        XCTAssertFalse(RecommendationReason.downloadCost.isSupported(by: c))
    }
}
