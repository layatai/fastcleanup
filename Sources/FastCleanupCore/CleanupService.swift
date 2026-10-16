import Foundation

public struct ReviewPlan: Identifiable, Sendable {
    public let id: UUID
    public let snapshotID: UUID
    public let createdAt: Date
    public let candidates: [CleanupCandidate]
    public var footprint: Int64 { candidates.reduce(0) { total, c in
        let (sum, overflow) = total.addingReportingOverflow(c.allocatedBytes)
        return overflow ? Int64.max : sum
    } }
}

public struct TrashRecord: Identifiable, Sendable {
    public let id: UUID
    public let originalURL: URL
    public let trashURL: URL
    public let allocatedBytes: Int64
    public let trashStamp: FileStamp?
}
public struct CleanupReport: Sendable {
    public let moved: [TrashRecord]
    public let failures: [String]
    public var movedBytes: Int64 { moved.reduce(0) { total, record in
        let (sum, overflow) = total.addingReportingOverflow(record.allocatedBytes)
        return overflow ? Int64.max : sum
    } }
}

/// No model, Process, shell, permanent-delete, or network capability is exposed here.
/// Synchronous filesystem operations inside the actor serialize mutations without reentrancy.
public actor CleanupService {
    private let fileSystem: any CleanupFileSystem
    private let now: @Sendable () -> Date
    private var pending: ReviewPlan?
    private var journal: [TrashRecord] = []
    public init(fileSystem: any CleanupFileSystem = LocalCleanupFileSystem(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileSystem = fileSystem; self.now = now
    }

    public func prepare(snapshot: ScanSnapshot, selectedIDs: Set<String>, currentSnapshotID: UUID,
                        protection: PathProtection) throws -> ReviewPlan {
        pending = nil
        guard snapshot.id == currentSnapshotID else { throw CleanupError.stalePlan }
        let candidates = snapshot.candidates.filter { selectedIDs.contains($0.id) }
        guard !candidates.isEmpty, candidates.count == selectedIDs.count,
              Set(candidates.map(\.id)).count == candidates.count,
              CandidateNormalizer.disjoint(candidates).count == candidates.count else { throw CleanupError.invalidSelection }
        for candidate in candidates { try revalidate(candidate, protection: protection) }
        let plan = ReviewPlan(id: UUID(), snapshotID: snapshot.id, createdAt: now(), candidates: candidates)
        pending = plan
        return plan
    }

    public func discardPlan() { pending = nil }

    public func execute(planID: UUID, currentSnapshotID: UUID, protection: PathProtection) throws -> CleanupReport {
        guard let plan = pending, plan.id == planID else { throw CleanupError.unknownPlan }
        pending = nil // Single use, including failed attempts.
        guard plan.snapshotID == currentSnapshotID else { throw CleanupError.stalePlan }
        guard (0...300).contains(now().timeIntervalSince(plan.createdAt)) else { throw CleanupError.expiredPlan }
        // Fail the whole plan if any item already changed before the first mutation.
        for candidate in plan.candidates { try revalidate(candidate, protection: protection) }
        var moved: [TrashRecord] = [], failures: [String] = []
        for candidate in plan.candidates {
            do {
                try Task.checkCancellation()
                try revalidate(candidate, protection: protection)
                let destination = try fileSystem.moveToTrash(candidate.url)
                // A successful move remains a success even if post-move inspection fails.
                let record = TrashRecord(id: UUID(), originalURL: candidate.url, trashURL: destination,
                    allocatedBytes: candidate.allocatedBytes, trashStamp: try? fileSystem.stamp(destination))
                moved.append(record); journal.append(record)
                while journal.count > 100 || journal.reduce(0, { $0 + ($1.trashStamp?.entries.count ?? 0) }) > 40_000 { journal.removeFirst() }
            } catch {
                // Error text comes from trusted code, never generated model text.
                failures.append("\(candidate.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return CleanupReport(moved: moved, failures: failures)
    }

    public func history() -> [TrashRecord] { journal }

    public func restore(recordID: UUID, protection: PathProtection) throws {
        guard let index = journal.firstIndex(where: { $0.id == recordID }),
              let expected = journal[index].trashStamp else { throw CleanupError.unknownPlan }
        let record = journal[index]
        try protection.validate(record.originalURL, stamp: expected)
        guard try fileSystem.stamp(record.trashURL) == expected else { throw CleanupError.changedFile }
        try fileSystem.restore(from: record.trashURL, to: record.originalURL)
        journal.remove(at: index)
    }

    private func revalidate(_ candidate: CleanupCandidate, protection: PathProtection) throws {
        try Task.checkCancellation()
        try protection.validate(candidate.url, stamp: candidate.stamp)
        let current = try fileSystem.stamp(candidate.url)
        try protection.validate(candidate.url, stamp: current)
        guard current == candidate.stamp else { throw CleanupError.changedFile }
    }
}
