import Foundation

public enum CandidateKind: String, Codable, Sendable { case cache, buildOutput, dependencies }
public enum Evidence: String, Codable, CaseIterable, Sendable {
    case cacheLocation, buildLocation, projectManifest, lockfile, recentlyModified, olderModification, activityUnknown

    public var description: String {
        switch self {
        case .cacheLocation: return "Located in a known cache directory; regeneration is not guaranteed."
        case .buildLocation: return "Located in Xcode DerivedData; rebuilding may be expensive."
        case .projectManifest: return "A matching project manifest exists; rebuilding may require tools or downloads."
        case .lockfile: return "A dependency lockfile exists; it does not guarantee offline recovery."
        case .recentlyModified: return "Modified within the last seven days. This is not a last-used timestamp."
        case .olderModification: return "Not modified within seven days. This does not establish inactivity."
        case .activityUnknown: return "Whether the owning app or project is in use is unknown."
        }
    }
}

/// Local URLs and filesystem identities never enter the model's request type.
public struct CleanupCandidate: Identifiable, Sendable, Equatable {
    public let id: String
    public let url: URL
    public let categoryID: String
    public let kind: CandidateKind
    public let allocatedBytes: Int64
    public let evidence: [Evidence]
    public let stamp: FileStamp

    public init(id: String, url: URL, categoryID: String, kind: CandidateKind,
                allocatedBytes: Int64, evidence: [Evidence], stamp: FileStamp) {
        self.id = id; self.url = url; self.categoryID = categoryID; self.kind = kind
        self.allocatedBytes = max(0, allocatedBytes); self.evidence = evidence; self.stamp = stamp
    }
}

public struct ScanSnapshot: Sendable {
    public let id: UUID
    public let candidates: [CleanupCandidate]
    public init(id: UUID, candidates: [CleanupCandidate]) { self.id = id; self.candidates = candidates }
}

public enum Disposition: String, Codable, Sendable { case review, keep }
public enum RecommendationReason: String, Codable, Sendable {
    case cacheReview, rebuildCost, downloadCost, recentChanges, uncertainUse

    public var text: String {
        switch self {
        case .cacheReview: return "Review this cache. The owning app may need to recreate or download its contents."
        case .rebuildCost: return "Review build output. A recognized build location or matching manifest was found, but rebuilding has a cost."
        case .downloadCost: return "Review dependencies only when you can reinstall them; downloads may be required."
        case .recentChanges: return "Consider keeping this item because it was modified recently."
        case .uncertainUse: return "Review manually: whether this data is currently needed is unknown."
        }
    }

    public func isSupported(by candidate: CleanupCandidate) -> Bool {
        switch self {
        case .cacheReview: return candidate.kind == .cache && candidate.evidence.contains(.cacheLocation)
        case .rebuildCost: return candidate.kind == .buildOutput && (candidate.evidence.contains(.projectManifest) || candidate.evidence.contains(.buildLocation))
        case .downloadCost: return candidate.kind == .dependencies && candidate.evidence.contains(.projectManifest)
        case .recentChanges: return candidate.evidence.contains(.recentlyModified)
        case .uncertainUse: return candidate.evidence.contains(.activityUnknown)
        }
    }
}

public struct Recommendation: Identifiable, Equatable, Sendable {
    public var id: String { candidateID }
    public let candidateID: String
    public let disposition: Disposition
    public let reason: RecommendationReason
    public let appleRanked: Bool
    public init(candidateID: String, disposition: Disposition, reason: RecommendationReason, appleRanked: Bool) {
        self.candidateID = candidateID; self.disposition = disposition; self.reason = reason; self.appleRanked = appleRanked
    }
}

public enum RulesPlanner {
    public static func recommendations(for snapshot: ScanSnapshot) -> [Recommendation] {
        snapshot.candidates.sorted {
            let a = $0.evidence.contains(.recentlyModified), b = $1.evidence.contains(.recentlyModified)
            if a != b { return !a }
            return $0.allocatedBytes == $1.allocatedBytes ? $0.id < $1.id : $0.allocatedBytes > $1.allocatedBytes
        }.map { c in
            let recent = c.evidence.contains(.recentlyModified)
            let reason: RecommendationReason = recent ? .recentChanges :
                (c.kind == .cache ? .cacheReview : c.kind == .buildOutput ? .rebuildCost : .downloadCost)
            return Recommendation(candidateID: c.id, disposition: recent ? .keep : .review,
                                  reason: reason.isSupported(by: c) ? reason : .uncertainUse, appleRanked: false)
        }
    }
}

/// Small, fixed-schema metadata records. No filenames, paths, document text, tool calls, or byte goals.
public struct RecommendationRequest: Codable, Sendable {
    public struct Item: Codable, Sendable {
        public let id: String
        public let kind: CandidateKind
        public let sizeMiB: Int64
        public let evidence: [Evidence]
    }
    public static let maximumCandidates = 8
    public static let maximumPromptBytes = 4_000
    public let snapshotID: String
    public let items: [Item]

    public init(snapshot: ScanSnapshot) {
        snapshotID = snapshot.id.uuidString
        let byID = Dictionary(snapshot.candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        items = RulesPlanner.recommendations(for: snapshot).prefix(Self.maximumCandidates).compactMap {
            guard let c = byID[$0.candidateID] else { return nil }
            return Item(id: c.id, kind: c.kind, sizeMiB: c.allocatedBytes / 1_048_576,
                        evidence: Array(Set(c.evidence)).sorted { $0.rawValue < $1.rawValue })
        }
    }

    public func prompt() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumPromptBytes else { throw AdviceError.oversizedRequest }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct ModelAdvice: Codable, Sendable {
    public struct Item: Codable, Sendable {
        public let candidateID: String
        public let disposition: Disposition
        public let reason: RecommendationReason
        public init(candidateID: String, disposition: Disposition, reason: RecommendationReason) {
            self.candidateID = candidateID; self.disposition = disposition; self.reason = reason
        }
    }
    public let snapshotID: String
    public let items: [Item]
    public init(snapshotID: String, items: [Item]) { self.snapshotID = snapshotID; self.items = items }
}

public enum AdviceError: Error, Equatable { case staleSnapshot, unknownCandidate, duplicateCandidate, unsupportedReason, oversizedRequest, oversizedResponse }
public enum AdviceValidator {
    public static func validate(_ advice: ModelAdvice, request: RecommendationRequest,
                                snapshot: ScanSnapshot) throws -> [Recommendation] {
        guard advice.snapshotID == snapshot.id.uuidString, advice.snapshotID == request.snapshotID else { throw AdviceError.staleSnapshot }
        guard advice.items.count <= request.items.count else { throw AdviceError.oversizedResponse }
        let allowed = Set(request.items.map(\.id))
        let candidates = Dictionary(snapshot.candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var result: [Recommendation] = []
        for item in advice.items {
            guard allowed.contains(item.candidateID), let c = candidates[item.candidateID] else { throw AdviceError.unknownCandidate }
            guard seen.insert(item.candidateID).inserted else { throw AdviceError.duplicateCandidate }
            guard item.reason.isSupported(by: c) else { throw AdviceError.unsupportedReason }
            // Model advice never changes permissions, byte totals, or selection.
            result.append(Recommendation(candidateID: c.id, disposition: item.disposition, reason: item.reason, appleRanked: true))
        }
        result += RulesPlanner.recommendations(for: snapshot).filter { !seen.contains($0.candidateID) }
        return result
    }
}

public enum ModelAvailability: Equatable, Sendable {
    case available
    case unavailable(String)
    public var message: String {
        switch self {
        case .available: return "Apple's on-device model is ready. No separate model download."
        case .unavailable(let reason): return reason
        }
    }
    public var isAvailable: Bool { if case .available = self { return true }; return false }
}

public protocol LocalRecommendationProvider: Sendable {
    func availability() async -> ModelAvailability
    func recommend(_ request: RecommendationRequest) async throws -> ModelAdvice
}
