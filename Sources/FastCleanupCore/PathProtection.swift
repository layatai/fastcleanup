import Foundation

/// Component-wise, conservatively case-insensitive comparisons also protect ancestors.
/// Never use a raw string prefix: /home/user2 is not inside /home/user.
public enum PathRules {
    public static func contains(_ parent: URL, _ child: URL) -> Bool {
        let a = parent.standardizedFileURL.pathComponents.map { $0.precomposedStringWithCanonicalMapping.lowercased() }
        let b = child.standardizedFileURL.pathComponents.map { $0.precomposedStringWithCanonicalMapping.lowercased() }
        return a.count <= b.count && Array(b.prefix(a.count)) == a
    }
    public static func overlaps(_ a: URL, _ b: URL) -> Bool { contains(a, b) || contains(b, a) }
}

public struct PathProtection: Sendable {
    public let home: URL
    public let excluded: [URL]
    private let includeReviewOnlyRoots: Bool
    public init(home: URL, excluded: [URL] = [], includeReviewOnlyRoots: Bool = true) {
        self.home = home.standardizedFileURL; self.excluded = excluded; self.includeReviewOnlyRoots = includeReviewOnlyRoots
    }

    public var protectedRoots: [URL] {
        let alwaysProtected = [".ssh", ".gnupg", ".aws", ".kube", "Library/Keychains", "Library/CloudStorage",
            "Library/Mobile Documents", "Library/Application Support/FastCleanup", "Dropbox", "OneDrive", "Google Drive", "Box"]
        let reviewOnly = [
            ".Trash", ".ollama",
            ".cache/huggingface", ".cache/lm-studio", ".lmstudio",
            "Library/Keychains", "Library/CloudStorage", "Library/Mobile Documents",
            "Library/Application Support/FastCleanup", "Library/Application Support/lm-studio",
            "Library/Application Support/nomic.ai", "Library/Application Support/Telegram Desktop",
            "Library/Application Support/ZaloData", "Library/Developer/Xcode/Archives",
            "Library/Containers/com.docker.docker", "Library/Application Support/rancher-desktop",
            "Dropbox", "OneDrive", "Google Drive", "Box", "Pictures/Photos Library.photoslibrary",
        ]
        return (alwaysProtected + (includeReviewOnlyRoots ? reviewOnly : [])).map { home.appendingPathComponent($0) } + excluded
    }

    public func allows(_ url: URL) -> Bool {
        let target = url.standardizedFileURL
        guard target != home, PathRules.contains(home, target) else { return false }
        return !protectedRoots.contains { PathRules.overlaps($0, target) }
    }

    public func validate(_ url: URL, stamp: FileStamp) throws {
        guard allows(url) else { throw CleanupError.protectedPath }
        for entry in stamp.entries {
            let child = entry.relativePath.isEmpty ? url : url.appendingPathComponent(entry.relativePath)
            guard allows(child) else { throw CleanupError.protectedPath }
            let name = child.lastPathComponent.lowercased()
            if [".git", ".ssh", ".gnupg", ".aws", ".kube", ".env", "keychains"].contains(name) {
                throw CleanupError.protectedPath
            }
        }
    }
}

public enum CandidateNormalizer {
    /// Ambiguous overlapping directory actions are omitted, not assigned a weaker safety tier.
    public static func disjoint(_ candidates: [CleanupCandidate]) -> [CleanupCandidate] {
        var seen = Set<String>()
        let unique = candidates.filter { seen.insert($0.url.standardizedFileURL.path.lowercased()).inserted }
        return unique.filter { a in
            !unique.contains { b in a.id != b.id && PathRules.overlaps(a.url, b.url) }
        }
    }
}
