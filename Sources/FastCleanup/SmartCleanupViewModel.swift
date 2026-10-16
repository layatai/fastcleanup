import SwiftUI
import FastCleanupCore
import FastCleanupAI

@MainActor
final class SmartCleanupViewModel: ObservableObject {
    @Published var snapshot: ScanSnapshot?
    @Published var recommendations: [Recommendation] = []
    @Published var selectedIDs = Set<String>()
    @Published var availability: ModelAvailability = .unavailable("Checking Apple model availability…")
    @Published var message = "Preparing rules-based review…"
    @Published var lastOutcome: String?
    @Published var isLoading = false
    @Published var isAnalyzing = false
    @Published var isPreparing = false
    @Published var reviewPlan: ReviewPlan?
    @Published var history: [TrashRecord] = []
    @Published var excludedPaths: [String] = []
    @Published var errorMessage: String?
    private weak var app: AppState?
    private let provider = AppleModelProvider()
    private let engine: RecommendationEngine
    private var work: Task<Void, Never>?
    private var workID = UUID()
    private var keptIDs = Set<String>()

    init(app: AppState) { self.app = app; self.engine = app.recommendationEngine; self.excludedPaths = CleanupSafety.exclusions.map(\.path) }
    var selectedBytes: Int64 { snapshot?.candidates.filter { selectedIDs.contains($0.id) }.reduce(0) { $0 + $1.allocatedBytes } ?? 0 }
    func candidate(_ id: String) -> CleanupCandidate? { snapshot?.candidates.first { $0.id == id } }

    func load() {
        cancelWork()
        reviewPlan = nil; snapshot = nil; recommendations = []; selectedIDs = []; keptIDs = []
        guard let app else { return }
        if app.isScanning { message = "Waiting for the current scan to finish."; return }
        guard !app.isCleaning else { message = "Cleanup is running. Review after the next scan."; return }
        let results = app.results, generation = app.scanGeneration, protection = CleanupSafety.protection
        let id = workID
        isLoading = true
        work = Task { [weak self] in
            guard let self else { return }
            self.availability = await self.provider.availability()
            self.history = await app.smartCleanupService.history()
            let builder = Task.detached(priority: .utility) {
                try SmartSnapshotBuilder.build(results: results, generation: generation, protection: protection)
            }
            do {
                let built = try await withTaskCancellationHandler(operation: { try await builder.value }, onCancel: { builder.cancel() })
                guard !Task.isCancelled, self.workID == id, app.scanGeneration == generation, !app.isScanning, !app.isCleaning else { return }
                self.snapshot = built.snapshot
                self.recommendations = RulesPlanner.recommendations(for: built.snapshot)
                self.message = "\(built.snapshot.candidates.count) bounded, inspectable candidates · \(built.omitted) other items remain in manual review. Nothing is selected automatically."
                self.isLoading = false
            } catch {
                guard self.workID == id else { return }
                self.isLoading = false
                if !(error is CancellationError) { self.message = "Could not inspect this snapshot. Use the normal results view or rescan." }
            }
        }
    }

    func analyze() {
        guard let app, let snapshot, !app.isScanning, !app.isCleaning, !isLoading, !isPreparing, !isAnalyzing else { return }
        cancelWork()
        let id = workID
        isAnalyzing = true
        message = "Ranking bounded metadata on this Mac…"
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.engine.analyze(snapshot)
                guard !Task.isCancelled, self.workID == id, app.scanGeneration == snapshot.id, !app.isScanning, !app.isCleaning else { return }
                self.recommendations = result.recommendations.map { row in
                    self.keptIDs.contains(row.candidateID) ? Recommendation(candidateID: row.candidateID, disposition: .keep, reason: .uncertainUse, appleRanked: false) : row
                }
                self.message = result.message
                self.availability = await self.provider.availability()
                self.isAnalyzing = false
            } catch {
                guard self.workID == id else { return }
                self.isAnalyzing = false
                self.message = "Analysis canceled. Rules-based review remains available."
            }
        }
    }
    func cancelWork() {
        work?.cancel(); work = nil; workID = UUID()
        isAnalyzing = false; isLoading = false; isPreparing = false
    }
    func cancelAnalysis() {
        cancelWork()
        if let snapshot { recommendations = RulesPlanner.recommendations(for: snapshot) }
        message = "Analysis canceled. No files were changed."
    }
    func toggle(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }
    func keep(_ id: String) {
        selectedIDs.remove(id); keptIDs.insert(id)
        recommendations = recommendations.map { row in
            row.candidateID == id ? Recommendation(candidateID: id, disposition: .keep, reason: .uncertainUse, appleRanked: false) : row
        }
    }
    func exclude(_ candidate: CleanupCandidate) {
        guard excludedPaths.count < 256 else { errorMessage = "The 256-path exclusion limit was reached."; return }
        if !excludedPaths.contains(candidate.url.path) { excludedPaths.append(candidate.url.path) }
        saveExclusions(); load()
    }
    func removeExclusion(_ path: String) { excludedPaths.removeAll { $0 == path }; saveExclusions(); load() }
    private func saveExclusions() { UserDefaults.standard.set(excludedPaths, forKey: CleanupSafety.exclusionsKey) }

    func prepareReview() {
        guard let app, let snapshot, !selectedIDs.isEmpty, !isLoading, !isAnalyzing, !isPreparing, !app.isScanning, !app.isCleaning else { return }
        cancelWork()
        let id = workID, selected = selectedIDs, protection = CleanupSafety.protection
        isPreparing = true
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let plan = try await app.smartCleanupService.prepare(snapshot: snapshot, selectedIDs: selected,
                    currentSnapshotID: app.scanGeneration, protection: protection)
                guard !Task.isCancelled, self.workID == id, app.scanGeneration == snapshot.id, !app.isScanning, !app.isCleaning else { return }
                self.reviewPlan = plan; self.isPreparing = false
            } catch {
                guard self.workID == id else { return }
                self.isPreparing = false; self.errorMessage = error.localizedDescription
            }
        }
    }
    func discardReview() {
        reviewPlan = nil
        guard let app else { return }
        Task { await app.smartCleanupService.discardPlan() }
    }
    func execute(_ plan: ReviewPlan) {
        guard let app else { return }
        reviewPlan = nil
        // Do not cancel a mutation when the view redraws or its scan generation changes.
        Task { [weak self] in
            do {
                let report = try await app.executeSmartPlan(plan)
                self?.history = await app.smartCleanupService.history()
                self?.lastOutcome = "Moved \(report.moved.count) items (\(Format.bytes(report.movedBytes))) to Trash. Storage is not immediately freed. \(report.failures.count) items failed."
                if !report.failures.isEmpty { self?.errorMessage = report.failures.joined(separator: "\n") }
            } catch { self?.errorMessage = error.localizedDescription }
        }
    }
    func restore(_ record: TrashRecord) {
        guard let app else { return }
        Task { [weak self] in
            do {
                try await app.restoreSmartItem(record.id)
                self?.history = await app.smartCleanupService.history()
                self?.lastOutcome = "Restored \(record.originalURL.lastPathComponent)."
            } catch { self?.errorMessage = error.localizedDescription }
        }
    }
}
