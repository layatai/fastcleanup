import Foundation
import FastCleanupCore

struct SmartSnapshotBuild: Sendable {
    let snapshot: ScanSnapshot
    let inspected: Int
    let omitted: Int
}

enum SmartSnapshotBuilder {
    static let maximumCandidates = 16
    static let maximumInspections = 24
    static func build(results: [CategoryResult], generation: UUID, protection: PathProtection, now: Date = Date()) throws -> SmartSnapshotBuild {
        let fs = LocalCleanupFileSystem()
        let all = results.filter { $0.definition.action == .trash }.flatMap { category in
            category.items.map { (category.id, $0) }
        }.sorted { $0.1.size > $1.1.size }
        let home = protection.home
        let homeDevice = try fs.rootIdentity(home).device
        var candidates: [CleanupCandidate] = [], inspected = 0
        for (categoryID, item) in all {
            try Task.checkCancellation()
            guard candidates.count < maximumCandidates, inspected < maximumInspections else { break }
            guard protection.allows(item.url) else { continue }
            if categoryID == "app-caches", !PathRules.contains(home.appendingPathComponent("Library/Caches"), item.url) { continue }
            if categoryID == "xcode-derived", !PathRules.contains(home.appendingPathComponent("Library/Developer/Xcode/DerivedData"), item.url) { continue }
            let manifests = manifestNames(near: item.url.deletingLastPathComponent(), home: home,
                                          levels: categoryID == "node-modules" ? 1 : 4)
            guard let kind = CleanupRecipe.kind(categoryID: categoryID, directoryName: item.name, manifests: manifests) else { continue }
            inspected += 1
            do {
                let stamp = try fs.stamp(item.url)
                guard let root = stamp.entries.first(where: { $0.relativePath.isEmpty }), root.device == homeDevice,
                      root == item.fileIdentity else { continue }
                try protection.validate(item.url, stamp: stamp)
                var evidence: [Evidence] = [.activityUnknown]
                if kind == .cache { evidence.append(.cacheLocation) }
                if categoryID == "xcode-derived" { evidence.append(.buildLocation) }
                else if kind != .cache { evidence.append(.projectManifest) }
                if !manifests.isDisjoint(with: ["package-lock.json", "pnpm-lock.yaml", "yarn.lock", "Cargo.lock", "uv.lock"]) { evidence.append(.lockfile) }
                if let modified = item.modified {
                    evidence.append(now.timeIntervalSince(modified) < 7 * 86_400 ? .recentlyModified : .olderModification)
                }
                guard stamp.allocatedBytes > 0 else { continue }
                candidates.append(CleanupCandidate(id: "c\(candidates.count)", url: item.url, categoryID: categoryID,
                    kind: kind, allocatedBytes: stamp.allocatedBytes, evidence: evidence, stamp: stamp))
            } catch is CancellationError { throw CancellationError() }
            catch { continue } // Ambiguous, changing, linked, cloud, or incomplete trees remain manual-only.
        }
        let disjoint = CandidateNormalizer.disjoint(candidates)
        return SmartSnapshotBuild(snapshot: ScanSnapshot(id: generation, candidates: disjoint), inspected: inspected,
                                  omitted: max(0, all.count - disjoint.count))
    }

    private static func manifestNames(near url: URL, home: URL, levels: Int) -> Set<String> {
        let names = ["package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "Cargo.toml", "Cargo.lock",
                     "pyproject.toml", "requirements.txt", "setup.cfg", "uv.lock"]
        var found = Set<String>(), directory = url
        for _ in 0..<levels {
            guard PathRules.contains(home, directory), directory != home else { break }
            for name in names {
                let file = directory.appendingPathComponent(name)
                guard let info = try? FileManager.default.attributesOfItem(atPath: file.path),
                      info[.type] as? FileAttributeType == .typeRegular,
                      ((info[.size] as? NSNumber)?.int64Value ?? Int64.max) <= 1_048_576 else { continue }
                found.insert(name)
            }
            if !found.isEmpty { break }
            directory.deleteLastPathComponent()
        }
        return found
    }
}
