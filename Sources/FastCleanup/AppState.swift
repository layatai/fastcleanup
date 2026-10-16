import SwiftUI
import AppKit
import FastCleanupCore
import FastCleanupAI

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
    @Published private(set) var scanGeneration = UUID()
    @Published var canSuggestFclones = false
    @Published var isInstallingTool = false
    @Published var statusMessage: String? {
        didSet {
            statusClearTask?.cancel()
            guard statusMessage != nil else { return }
            statusClearTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                withAnimation { self?.statusMessage = nil }
            }
        }
    }
    let smartCleanupService = CleanupService()
    let recommendationEngine = RecommendationEngine()
    private let scanner = DiskScanner()
    private var scanTask: Task<Void, Never>?
    private var statusClearTask: Task<Void, Never>?

    var nonEmptyResults: [CategoryResult] { results.filter { $0.totalSize > 0 } }
    var visibleResults: [CategoryResult] { results.filter { $0.totalSize > 0 || $0.definition.isCommandBased } }
    // A conservative union of scanned file footprints, not guaranteed immediately freeable bytes.
    var reclaimable: Int64 { footprint(results.filter { $0.definition.action == .trash }) }
    var selectedSize: Int64 { footprint(results.filter { selected.contains($0.id) }) }
    var selectedCount: Int { results.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.count } }
    private func footprint(_ categories: [CategoryResult]) -> Int64 {
        let items = categories.flatMap(\.items).sorted { $0.url.pathComponents.count < $1.url.pathComponents.count }
        var covered: [URL] = [], total: Int64 = 0
        for item in items where !covered.contains(where: { PathRules.contains($0, item.url) }) {
            covered.append(item.url)
            let (sum, overflow) = total.addingReportingOverflow(item.size)
            total = overflow ? Int64.max : sum
        }
        return total
    }
    var cleanSummary: String {
        let targets = results.filter { selected.contains($0.id) }
        var parts: [String] = []
        if targets.contains(where: { $0.definition.action == .trash }) {
            parts.append(useTrash ? "Files move to Trash. This does not immediately free disk space."
                                  : "Files are permanently deleted. This cannot be undone.")
        }
        if targets.contains(where: { $0.definition.isCommandBased }) {
            parts.append("Selected maintenance tools change data in place and cannot be undone through Trash.")
        }
        return parts.joined(separator: " ")
    }
    func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
    func refreshDisk() { disk = DiskSpace.current() }

    func scan() {
        guard !isScanning, !isCleaning, !isInstallingTool else { return }
        scanTask?.cancel()
        scanGeneration = UUID()
        let generation = scanGeneration
        isScanning = true; statusMessage = nil; selected = []
        progress = ScanProgress(); results = []; disk = DiskSpace.current()
        let scanner = self.scanner
        scanTask = Task { [weak self] in
            let defs = await Task.detached(priority: .userInitiated) {
                CommandRunner.clearCache()
                return CleanupSafety.catalog()
            }.value
            guard let self, !Task.isCancelled, self.scanGeneration == generation else { return }
            self.progress = ScanProgress(total: defs.count)
            var collected: [CategoryResult] = []
            await withTaskGroup(of: CategoryResult.self) { group in
                for def in defs { group.addTask { CategoryResult(definition: def, items: scanner.collect(def)) } }
                for await result in group {
                    guard !Task.isCancelled, self.scanGeneration == generation else { group.cancelAll(); break }
                    collected.append(result)
                    self.progress.completed += 1; self.progress.current = result.definition.title
                    self.results = collected.filter { $0.totalSize > 0 || $0.definition.isCommandBased }.sorted { $0.totalSize > $1.totalSize }
                }
            }
            guard !Task.isCancelled, self.scanGeneration == generation else { return }
            self.selected = Set(collected.filter { $0.definition.defaultSelected && $0.totalSize > 0 }.map(\.id))
            self.isScanning = false; self.lastScan = Date(); self.progress.current = nil
            self.refreshDisk(); self.refreshToolSuggestions()
        }
    }
    func cancelScan() {
        scanTask?.cancel()
        scanGeneration = UUID() // Late results and model advice cannot replace the next scan.
        isScanning = false; progress.current = nil; results = []; selected = []
    }
    func refreshToolSuggestions() {
        Task { [weak self] in
            let can = await Task.detached(priority: .utility) {
                !CommandRunner.hasBinary("fclones") && CommandRunner.isAPFS(FileManager.default.homeDirectoryForCurrentUser) && CommandRunner.hasBinary("brew")
            }.value
            self?.canSuggestFclones = can
        }
    }
    func installFclones() {
        guard !isInstallingTool, !isScanning, !isCleaning else { return }
        isInstallingTool = true; statusMessage = "Installing fclones…"
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                CommandRunner.run(ShellCommand(executable: "brew", arguments: ["install", "fclones"]))
            }.value
            guard let self else { return }
            CommandRunner.clearCache(); self.isInstallingTool = false; self.canSuggestFclones = false
            if result.ok { self.scan() }
            self.statusMessage = result.ok ? "Installed fclones" : "fclones install failed"
        }
    }
    func cleanSelected() { runClean(results.filter { selected.contains($0.id) }) }
    func cleanCategory(_ id: String) {
        guard let category = results.first(where: { $0.id == id }) else { return }
        runClean([category])
    }
    func trashItem(_ item: ScanItem, inCategory id: String) { trashItems([item], inCategory: id) }
    func trashItems(_ items: [ScanItem], inCategory id: String) {
        guard let category = results.first(where: { $0.id == id }), category.definition.action == .trash else {
            statusMessage = "This item supports maintenance, not Move to Trash."; return
        }
        let ids = Set(items.map(\.id)), current = category.items.filter { ids.contains($0.id) }
        guard current.count == ids.count else { statusMessage = "Selection changed. Rescan first."; return }
        runClean([CategoryResult(definition: category.definition, items: current)], alwaysTrash: true)
    }
    private func runClean(_ targets: [CategoryResult], alwaysTrash: Bool = false) {
        guard !isCleaning, !isScanning, !isInstallingTool, !targets.isEmpty else { return }
        guard !CleanupSafety.conflict(in: targets) else {
            statusMessage = "Overlapping actions selected. Clean these categories separately."; return
        }
        let trash = alwaysTrash || useTrash
        // One common confirmation and mutation gate covers every legacy entry point.
        let alert = NSAlert()
        alert.messageText = trash ? "Review cleanup actions" : "Permanently delete selected files?"
        let names = targets.map { "\($0.definition.title): \($0.count) items" }.joined(separator: "\n")
        alert.informativeText = names + "\n\n" + (trash ? "File removals go to Trash and do not immediately free storage. Maintenance commands change data in place."
            : "File removals are permanent. Maintenance commands change data in place. This cannot be undone.")
        alert.alertStyle = .warning; alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let scanner = self.scanner, protection = CleanupSafety.manualProtection
        isCleaning = true; statusMessage = nil
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                Self.perform(targets, useTrash: trash, scanner: scanner, protection: protection)
            }.value
            guard let self else { return }
            self.isCleaning = false
            self.scan()
            self.statusMessage = "Moved to Trash: \(Format.bytes(outcome.trashed)) · removed footprint: \(Format.bytes(outcome.removed))" +
                (outcome.skipped > 0 ? " · \(outcome.skipped) failed or protected" : "")
        }
    }

    /// Smart Cleanup ignores the permanent-delete setting and shares the app-wide mutation gate.
    func executeSmartPlan(_ plan: ReviewPlan) async throws -> CleanupReport {
        guard !isCleaning, !isScanning, !isInstallingTool, plan.snapshotID == scanGeneration else { throw CleanupError.stalePlan }
        isCleaning = true
        let before = DiskSpace.current().free
        do {
            let report = try await smartCleanupService.execute(planID: plan.id, currentSnapshotID: scanGeneration, protection: CleanupSafety.protection)
            isCleaning = false
            let delta = DiskSpace.current().free - before
            scan()
            statusMessage = "Moved \(Format.bytes(report.movedBytes)) to Trash · observed free-space change: \(delta < 0 ? "−" : "+")\(Format.bytes(abs(delta))) (not attributed savings)"
            return report
        } catch { isCleaning = false; throw error }
    }
    func restoreSmartItem(_ id: UUID) async throws {
        guard !isCleaning, !isScanning, !isInstallingTool else { throw CleanupError.stalePlan }
        isCleaning = true
        do {
            try await smartCleanupService.restore(recordID: id, protection: CleanupSafety.protection)
            isCleaning = false; scan(); statusMessage = "Restored item without overwriting existing data."
        } catch { isCleaning = false; throw error }
    }

    struct CleanOutcome: Sendable { var trashed: Int64 = 0; var removed: Int64 = 0; var skipped = 0 }
    nonisolated private static func perform(_ targets: [CategoryResult], useTrash: Bool, scanner: DiskScanner,
                                            protection: PathProtection) -> CleanOutcome {
        var outcome = CleanOutcome()
        let fm = FileManager.default
        for category in targets {
            switch category.definition.action {
            case .trash:
                for item in category.items {
                    do {
                        if category.id == "trash" && useTrash { throw CleanupError.protectedPath }
                        try CleanupSafety.validateTrashItem(item, category: category.definition, protection: protection)
                        if useTrash {
                            try fm.trashItem(at: item.url, resultingItemURL: nil); outcome.trashed += item.size
                        } else { try fm.removeItem(at: item.url); outcome.removed += item.size }
                    } catch { outcome.skipped += 1 }
                }
            case .gitCompact:
                for item in category.items {
                    guard !protection.excluded.contains(where: { PathRules.overlaps($0, item.url) }) else { outcome.skipped += 1; continue }
                    let git = item.url.appendingPathComponent(".git")
                    let before = scanner.size(of: git)
                    GitMaintenance.gc(at: item.url)
                    outcome.removed += max(0, before - scanner.size(of: git))
                }
            case .command(let command):
                // Legacy, explicit native-tool maintenance is separate from Smart Cleanup.
                // Do not run broad tools when path exclusions cannot be enforced by their CLI.
                guard protection.excluded.isEmpty else { outcome.skipped += 1; continue }
                let roots = sizingRoots(of: category.definition)
                let before = roots.reduce(Int64(0)) { $0 + scanner.size(of: $1) }
                if CommandRunner.run(command).ok {
                    let after = roots.reduce(Int64(0)) { $0 + scanner.size(of: $1) }
                    outcome.removed += max(0, before - after)
                } else { outcome.skipped += 1 }
            case .dedupeNodeModules:
                guard protection.excluded.isEmpty else { outcome.skipped += 1; continue }
                if !CommandRunner.dedupeNodeModules(under: category.definition.roots, scanner: scanner).ok { outcome.skipped += 1 }
            }
        }
        return outcome
    }
    nonisolated private static func sizingRoots(of definition: CategoryDefinition) -> [URL] {
        if case .command(let roots) = definition.strategy { return roots }; return []
    }
}
