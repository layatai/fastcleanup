import Foundation
import FastCleanupCore

struct ScanItem: Identifiable, Hashable, Sendable {
    let id = UUID()
    let url: URL
    let size: Int64
    let modified: Date?
    // Cheap root identity captured at scan time. Smart Cleanup additionally snapshots descendants.
    let fileIdentity: FileStamp.Entry?
    init(url: URL, size: Int64, modified: Date?) {
        self.url = url; self.size = size; self.modified = modified
        self.fileIdentity = try? LocalCleanupFileSystem().rootIdentity(url)
    }
    static func == (lhs: ScanItem, rhs: ScanItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    var name: String { url.lastPathComponent }
    var path: String { url.path }
    var location: String { Format.locationPath(url) }
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
    case command(sizingRoots: [URL])
}
struct ShellCommand: Sendable, Hashable {
    let executable: String
    let arguments: [String]
    var display: String { ([executable] + arguments).joined(separator: " ") }
}
enum CleanupAction: Equatable, Sendable {
    case trash
    case gitCompact
    case command(ShellCommand)
    case dedupeNodeModules
    var commandDisplay: String? {
        if case .command(let c) = self { return c.display }
        if case .gitCompact = self { return "git gc" }
        return nil
    }
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
    var defaultSelected: Bool { safety == .safe && action == .trash }
    var isCommandBased: Bool {
        switch action {
        // Git scan items point to repository ROOTS, never to disposable files.
        case .gitCompact, .command, .dedupeNodeModules: return true
        case .trash: return false
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
