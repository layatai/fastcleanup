import Foundation
import FastCleanupCore

/// The catalog remains data-driven; this is the single entry point used for scanning.
/// Broad/name-only recipes must not inherit an automatic 'safe' selection.
enum CleanupSafety {
    static let exclusionsKey = "smartCleanup.excludedPaths.v1"
    static var exclusions: [URL] {
        (UserDefaults.standard.stringArray(forKey: exclusionsKey) ?? []).prefix(256).map { URL(fileURLWithPath: $0) }
    }
    static var protection: PathProtection {
        PathProtection(home: FileManager.default.homeDirectoryForCurrentUser, excluded: exclusions)
    }
    static var manualProtection: PathProtection {
        PathProtection(home: FileManager.default.homeDirectoryForCurrentUser, excluded: exclusions, includeReviewOnlyRoots: false)
    }
    static func catalog() -> [CategoryDefinition] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let reviewOnly: Set<String> = ["node-modules", "build-artifacts", "pkg-stores", "editor-state-backups",
            "app-data-caches", "saved-app-state", "tmp-files", "trash", "logs"]
        return CategoryCatalog.all().map { d in
            // .cache also contains caution-only Hugging Face and LM Studio models.
            let roots = d.id == "pkg-stores" ? d.roots.filter { $0.standardizedFileURL != home.appendingPathComponent(".cache").standardizedFileURL } : d.roots
            return CategoryDefinition(id: d.id, title: d.title, subtitle: d.subtitle, systemImage: d.systemImage,
                tintHex: d.tintHex, safety: reviewOnly.contains(d.id) ? .caution : d.safety,
                roots: roots, strategy: d.strategy, action: d.action)
        }
    }

    static func validateTrashItem(_ item: ScanItem, category: CategoryDefinition, protection: PathProtection) throws {
        guard category.action == .trash else { throw CleanupError.invalidSelection }
        guard !FileManager.default.fileExists(atPath: item.url.appendingPathComponent(".git").path) else { throw CleanupError.protectedPath }
        // Shared, hard exclusions apply even to category and context-menu actions.
        guard protection.allows(item.url) else { throw CleanupError.protectedPath }
        guard let identity = item.fileIdentity,
              try LocalCleanupFileSystem().rootIdentity(item.url) == identity else { throw CleanupError.changedFile }
        // Resolve only for validation, never to select a new deletion target.
        guard item.url.standardizedFileURL == item.url.resolvingSymlinksInPath().standardizedFileURL else { throw CleanupError.unsafeFile }
    }

    static func conflict(in targets: [CategoryResult]) -> Bool {
        let paths = targets.filter { $0.definition.action == .trash }.flatMap(\.items).map(\.url)
        for i in paths.indices {
            for j in paths.indices where j > i {
                if PathRules.overlaps(paths[i], paths[j]) { return true }
            }
        }
        let ids = Set(targets.map(\.id))
        if ids.contains("node-modules-dedupe") && ids.contains("node-modules") { return true }
        if ids.contains("docker-system-prune") && ids.filter({ $0.hasPrefix("docker-") }).count > 1 { return true }
        // Native prune tools can overlap file-based cache removals. Keep the operations separate.
        if targets.contains(where: { $0.definition.isCommandBased }) && !paths.isEmpty { return true }
        return false
    }
}
