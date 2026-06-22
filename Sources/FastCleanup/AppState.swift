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
    /// True when `fclones` is absent on an APFS volume but Homebrew can install it.
    @Published var canSuggestFclones = false
    @Published var isInstallingTool = false
    /// Transient confirmation/error text; auto-clears a few seconds after it's set.
    @Published var statusMessage: String? {
        didSet {
            statusClearTask?.cancel()
            guard statusMessage != nil else { return }
            statusClearTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                withAnimation { self?.statusMessage = nil }
            }
        }
    }

    private let scanner = DiskScanner()
    private var scanTask: Task<Void, Never>?
    private var statusClearTask: Task<Void, Never>?

    var nonEmptyResults: [CategoryResult] { results.filter { $0.totalSize > 0 } }
    var reclaimable: Int64 { nonEmptyResults.reduce(0) { $0 + $1.totalSize } }
    var selectedSize: Int64 { results.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.totalSize } }
    var selectedCount: Int { results.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.count } }

    var cleanSummary: String {
        let sel = results.filter { selected.contains($0.id) }
        let hasGit = sel.contains { $0.definition.action == .gitCompact }
        let hasTrash = sel.contains { $0.definition.action == .trash }
        let hasCommand = sel.contains { if case .command = $0.definition.action { return true }; return false }
        let hasDedupe = sel.contains { $0.definition.action == .dedupeNodeModules }
        var parts: [String] = []
        if hasTrash {
            parts.append(useTrash ? "Files move to the Trash and can be recovered."
                                  : "Files are permanently deleted. This cannot be undone.")
        }
        if hasGit { parts.append("Git repositories are compacted with git gc — every commit is preserved.") }
        if hasCommand { parts.append("Selected tools will be run (e.g. brew/docker/pnpm cleanup).") }
        if hasDedupe { parts.append("node_modules are deduplicated with APFS clones — non-destructive, projects keep working.") }
        return parts.joined(separator: " ")
    }

    func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
    func refreshDisk() { disk = DiskSpace.current() }

    func scan() {
        guard !isScanning, !isCleaning else { return }
        isScanning = true
        statusMessage = nil
        progress = ScanProgress(total: 0, completed: 0, current: nil)
        results = []
        disk = DiskSpace.current()
        let scanner = self.scanner

        scanTask = Task { [weak self] in
            // Build the catalog off the main thread — tool detection may spawn a login shell.
            let defs = await Task.detached(priority: .userInitiated) { CategoryCatalog.all() }.value
            guard let self else { return }
            self.progress = ScanProgress(total: defs.count, completed: 0, current: nil)
            var collected: [CategoryResult] = []
            await withTaskGroup(of: CategoryResult.self) { group in
                for def in defs {
                    group.addTask { CategoryResult(definition: def, items: scanner.collect(def)) }
                }
                for await r in group {
                    collected.append(r)
                    self.progress.completed += 1
                    self.progress.current = r.definition.title
                    self.results = collected
                        .filter { $0.totalSize > 0 || $0.definition.isCommandBased }
                        .sorted { $0.totalSize > $1.totalSize }
                }
            }
            self.selected = Set(collected.filter { $0.definition.defaultSelected && $0.totalSize > 0 }.map(\.id))
            self.isScanning = false
            self.lastScan = Date()
            self.progress.current = nil
            self.refreshDisk()
            self.refreshToolSuggestions()
        }
    }

    /// Recompute whether to suggest installing `fclones` (for node_modules dedupe).
    /// Runs off-main since the tool probe can spawn a login shell.
    func refreshToolSuggestions() {
        Task { [weak self] in
            let can = await Task.detached(priority: .utility) { () -> Bool in
                !CommandRunner.hasBinary("fclones")
                    && CommandRunner.isAPFS(FileManager.default.homeDirectoryForCurrentUser)
                    && CommandRunner.hasBinary("brew")
            }.value
            self?.canSuggestFclones = can
        }
    }

    /// One-click install of `fclones` via Homebrew, then rescan to reveal the dedupe action.
    func installFclones() {
        guard !isInstallingTool else { return }
        isInstallingTool = true
        statusMessage = "Installing fclones…"
        Task { [weak self] in
            let res = await Task.detached(priority: .userInitiated) {
                CommandRunner.run(ShellCommand(executable: "brew", arguments: ["install", "fclones"]))
            }.value
            guard let self else { return }
            CommandRunner.clearCache()   // forget the cached "not installed" result
            self.isInstallingTool = false
            self.statusMessage = res.ok ? "Installed fclones" : "fclones install failed — see Homebrew output"
            self.canSuggestFclones = false
            if res.ok { self.scan() }
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

    /// Move several items (a Table selection) to the Trash, updating state in place.
    func trashItems(_ items: [ScanItem], inCategory id: String) {
        guard !isCleaning, !items.isEmpty else { return }
        let urls = items.map(\.url)
        Task { [weak self] in
            let trashed = await Task.detached(priority: .userInitiated) { () -> Set<URL> in
                var ok = Set<URL>()
                for url in urls {
                    do { try FileManager.default.trashItem(at: url, resultingItemURL: nil); ok.insert(url) }
                    catch { /* locked / vanished — leave it in the list */ }
                }
                return ok
            }.value
            guard let self else { return }
            if let idx = self.results.firstIndex(where: { $0.id == id }) {
                self.results[idx].items.removeAll { trashed.contains($0.url) }
            }
            self.results.removeAll { $0.totalSize == 0 }
            self.statusMessage = "Trashed \(trashed.count) item\(trashed.count == 1 ? "" : "s")"
            self.refreshDisk()
        }
    }

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
            case .command(let cmd):
                let roots = sizingRoots(of: cat.definition)
                let before = roots.reduce(Int64(0)) { $0 + scanner.size(of: $1) }
                if CommandRunner.run(cmd).ok {
                    let after = roots.reduce(Int64(0)) { $0 + scanner.size(of: $1) }
                    out.freed += max(0, before - after)
                } else {
                    out.skipped += 1
                }
            case .dedupeNodeModules:
                // Non-destructive; reclaimed space surfaces via the post-clean rescan.
                if !CommandRunner.dedupeNodeModules(under: cat.definition.roots, scanner: scanner).ok {
                    out.skipped += 1
                }
            }
        }
        return out
    }

    /// The backing cache dirs a command category sizes itself from.
    nonisolated private static func sizingRoots(of def: CategoryDefinition) -> [URL] {
        if case .command(let roots) = def.strategy { return roots }
        return []
    }
}
