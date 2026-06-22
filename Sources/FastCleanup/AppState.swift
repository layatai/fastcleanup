import SwiftUI

@MainActor
final class AppState: ObservableObject {
    struct ScanProgress {
        var total = 0
        var completed = 0
        var current: String?
        var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
    }

    @Published var results: [CategoryResult] = []
    @Published var isScanning = false
    @Published var isCleaning = false
    @Published var progress = ScanProgress()
    @Published var disk = DiskSpace.current()
    @Published var selected: Set<String> = []
    @Published var lastScan: Date?
    @Published var useTrash = true
    @Published var statusMessage: String?

    private let scanner = DiskScanner()
    private var scanTask: Task<Void, Never>?

    var nonEmptyResults: [CategoryResult] { results.filter { $0.totalSize > 0 } }
    var reclaimable: Int64 { nonEmptyResults.reduce(0) { $0 + $1.totalSize } }
    var selectedSize: Int64 { results.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.totalSize } }
    var selectedCount: Int { results.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.count } }

    var cleanSummary: String {
        let sel = results.filter { selected.contains($0.id) }
        let hasGit = sel.contains { $0.definition.action == .gitCompact }
        let hasTrash = sel.contains { $0.definition.action == .trash }
        var parts: [String] = []
        if hasTrash {
            parts.append(useTrash ? "Files move to the Trash and can be recovered."
                                  : "Files are permanently deleted. This cannot be undone.")
        }
        if hasGit { parts.append("Git repositories are compacted with git gc — every commit is preserved.") }
        return parts.joined(separator: " ")
    }

    func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
    func refreshDisk() { disk = DiskSpace.current() }

    func scan() {
        guard !isScanning, !isCleaning else { return }
        let defs = CategoryCatalog.all()
        isScanning = true
        statusMessage = nil
        progress = ScanProgress(total: defs.count, completed: 0, current: nil)
        results = []
        disk = DiskSpace.current()
        let scanner = self.scanner

        scanTask = Task { [weak self] in
            var collected: [CategoryResult] = []
            await withTaskGroup(of: CategoryResult.self) { group in
                for def in defs {
                    group.addTask { CategoryResult(definition: def, items: scanner.collect(def)) }
                }
                for await r in group {
                    guard let self else { continue }
                    collected.append(r)
                    self.progress.completed += 1
                    self.progress.current = r.definition.title
                    self.results = collected.filter { $0.totalSize > 0 }.sorted { $0.totalSize > $1.totalSize }
                }
            }
            guard let self else { return }
            self.selected = Set(collected.filter { $0.definition.defaultSelected && $0.totalSize > 0 }.map(\.id))
            self.isScanning = false
            self.lastScan = Date()
            self.progress.current = nil
            self.refreshDisk()
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        isScanning = false
        progress.current = nil
    }

    func cleanSelected() {
        guard !isCleaning, !selected.isEmpty else { return }
        runClean(results.filter { selected.contains($0.id) })
    }

    /// Clean a single category from its context menu.
    func cleanCategory(_ id: String) {
        guard !isCleaning, let cat = results.first(where: { $0.id == id }) else { return }
        runClean([cat])
    }

    private func runClean(_ targets: [CategoryResult]) {
        guard !isCleaning, !targets.isEmpty else { return }
        let useTrash = self.useTrash
        let scanner = self.scanner
        isCleaning = true
        statusMessage = nil

        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                Self.perform(targets, useTrash: useTrash, scanner: scanner)
            }.value
            guard let self else { return }
            self.isCleaning = false
            self.statusMessage = outcome.skipped > 0
                ? "Freed \(Format.bytes(outcome.freed)) · \(outcome.skipped) in use — quit the app & rescan"
                : "Freed \(Format.bytes(outcome.freed))"
            self.selected = []
            self.scan()
        }
    }

    /// Move a single item to the Trash from its context menu (updates state in place).
    func trashItem(_ item: ScanItem, inCategory id: String) {
        guard !isCleaning else { return }
        Task { [weak self] in
            let ok = await Task.detached(priority: .userInitiated) { () -> Bool in
                do { try FileManager.default.trashItem(at: item.url, resultingItemURL: nil); return true }
                catch { return false }
            }.value
            guard let self else { return }
            guard ok else { self.statusMessage = "Couldn't trash \(item.name)"; return }
            if let idx = self.results.firstIndex(where: { $0.id == id }) {
                self.results[idx].items.removeAll { $0.id == item.id }
            }
            self.results.removeAll { $0.totalSize == 0 }
            self.statusMessage = "Trashed \(item.name)"
            self.refreshDisk()
        }
    }

    /// Result of a cleanup pass: bytes reclaimed plus how many items couldn't be
    /// removed because they were locked/in use (e.g. a browser's cache while it runs).
    struct CleanOutcome: Sendable { var freed: Int64 = 0; var skipped: Int = 0 }

    nonisolated private static func perform(_ targets: [CategoryResult],
                                            useTrash: Bool, scanner: DiskScanner) -> CleanOutcome {
        var out = CleanOutcome()
        let fm = FileManager.default
        for cat in targets {
            switch cat.definition.action {
            case .trash:
                for item in cat.items {
                    do {
                        if useTrash { try fm.trashItem(at: item.url, resultingItemURL: nil) }
                        else        { try fm.removeItem(at: item.url) }
                        out.freed += item.size
                    } catch {
                        // Vanished paths are gone already; anything still on disk is locked/in use.
                        if fm.fileExists(atPath: item.url.path) { out.skipped += 1 }
                    }
                }
            case .gitCompact:
                for item in cat.items {
                    let gitDir = item.url.appending(path: ".git", directoryHint: .isDirectory)
                    let before = scanner.size(of: gitDir)
                    GitMaintenance.gc(at: item.url)
                    out.freed += max(0, before - scanner.size(of: gitDir))
                }
            }
        }
        return out
    }
}
