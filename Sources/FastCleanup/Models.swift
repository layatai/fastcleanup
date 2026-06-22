import Foundation

struct ScanItem: Identifiable, Hashable, Sendable {
    let id = UUID()
    let url: URL
    let size: Int64
    let modified: Date?
    var name: String { url.lastPathComponent }
    var path: String { url.path }
    /// Containing directory, home-abbreviated — disambiguates same-named items.
    var location: String { Format.locationPath(url) }
    /// Non-optional key for Table sorting.
    var sortableModified: Date { modified ?? .distantPast }
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
    /// A command-based cleanup. Yields one representative item whose size is the
    /// sum of the existing `sizingRoots` (the command's backing cache dirs, if any;
    /// may be empty for tools like `docker prune` with no cheap size estimate).
    case command(sizingRoots: [URL])
}

/// An external tool invocation used by command-based cleanups.
struct ShellCommand: Sendable, Hashable {
    let executable: String
    let arguments: [String]
    var display: String { ([executable] + arguments).joined(separator: " ") }
}

enum CleanupAction: Equatable, Sendable {
    case trash              // move items to Trash (or delete permanently)
    case gitCompact         // run `git gc` to repack history (keeps all commits)
    case command(ShellCommand)   // run an external tool (brew/docker/pnpm …) to reclaim space
    case dedupeNodeModules  // APFS clone-dedupe of node_modules under the category roots
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
    // Command/dedupe categories run a tool; they stay visible even at 0 measured bytes.
    var isCommandBased: Bool {
        switch action {
        case .command, .dedupeNodeModules: return true
        default: return false
        }
    }
}

struct CategoryResult: Identifiable, Sendable {
    let definition: CategoryDefinition
    var items: [ScanItem]
    var id: String { definition.id }
    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var count: Int { items.count }
    var topItems: [ScanItem] { items.sorted { $0.size > $1.size } }
}
