import Foundation

struct ScanItem: Identifiable, Hashable, Sendable {
    let id = UUID()
    let url: URL
    let size: Int64
    let modified: Date?
    var name: String { url.lastPathComponent }
    var path: String { url.path }
}

enum Safety: Sendable { case safe, caution }

enum CollectStrategy: Sendable {
    case children
    case namedDirectories([String])
    case cacheDirectories([String])
    case namedFiles(suffixes: [String])
    case largeFiles(minBytes: Int64)
    case oldFiles(olderThanDays: Int)
    case paths
    case gitRepositories(minBytes: Int64)
}

enum CleanupAction: Sendable {
    case trash       // move items to Trash (or delete permanently)
    case gitCompact  // run `git gc` to repack history (keeps all commits)
}

struct CategoryDefinition: Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let tintHex: String
    let safety: Safety
    let roots: [URL]
    let strategy: CollectStrategy
    var action: CleanupAction = .trash
    // Auto-selected only when both safe AND a plain trash-delete.
    var defaultSelected: Bool { safety == .safe && action == .trash }
}

struct CategoryResult: Identifiable, Sendable {
    let definition: CategoryDefinition
    var items: [ScanItem]
    var id: String { definition.id }
    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var count: Int { items.count }
    var topItems: [ScanItem] { items.sorted { $0.size > $1.size } }
}
