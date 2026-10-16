import SwiftUI
import FastCleanupCore

struct ResultsRootView: View {
    @EnvironmentObject private var state: AppState
    @State private var showingSmartCleanup = false
    var body: some View {
        DetailWindowView()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingSmartCleanup = true } label: { Label("Smart Cleanup", systemImage: "sparkles") }
                        .disabled(state.isCleaning || state.isScanning)
                }
            }
            .sheet(isPresented: $showingSmartCleanup) { SmartCleanupView(app: state) }
    }
}

@MainActor
struct SmartCleanupView: View {
    @ObservedObject var app: AppState
    @StateObject private var model: SmartCleanupViewModel
    @Environment(\.dismiss) private var dismiss
    init(app: AppState) {
        self.app = app
        _model = StateObject(wrappedValue: SmartCleanupViewModel(app: app))
    }
    private var busy: Bool { app.isCleaning || app.isScanning || app.isInstallingTool || model.isPreparing }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            if model.isLoading { ProgressView("Inspecting bounded metadata…") }
            if let outcome = model.lastOutcome { Text(verbatim: outcome).font(.callout) }
            Text(verbatim: model.message).font(.callout).foregroundStyle(.secondary)
            candidateList
            exclusionsAndHistory
            Divider()
            HStack {
                Text("Selected footprint: \(Format.bytes(model.selectedBytes))").font(.callout)
                Spacer()
                Button("Close") { dismiss() }.disabled(app.isCleaning)
                Button("Review \(model.selectedIDs.count) Items…") { model.prepareReview() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedIDs.isEmpty || busy || model.isAnalyzing || model.isLoading)
            }
        }
        .padding(20)
        .frame(minWidth: 800, idealWidth: 860, minHeight: 610, idealHeight: 680)
        .interactiveDismissDisabled(app.isCleaning)
        .onAppear { model.load() }
        .onChange(of: app.scanGeneration) { _, _ in model.load() }
        .onChange(of: app.isScanning) { _, scanning in if !scanning { model.load() } }
        .onDisappear { model.cancelWork() }
        .sheet(item: $model.reviewPlan) { plan in review(plan) }
        .alert("Smart Cleanup", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(verbatim: model.errorMessage ?? "") }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Smart Cleanup", systemImage: "sparkles").font(.title2.bold())
            Text("Review first. Nothing is selected or deleted by AI.").font(.headline)
            Text("Apple analysis uses only bounded category, size, and evidence metadata on this Mac. No file contents, filenames, full paths, model downloads, or cloud fallback.")
                .font(.callout).foregroundStyle(.secondary)
            Text(verbatim: model.availability.message).font(.caption)
            HStack {
                Button("Analyze with Apple Intelligence") { model.analyze() }
                    .disabled(!model.availability.isAvailable || model.snapshot?.candidates.isEmpty != false || model.isLoading || model.isAnalyzing || busy)
                if model.isAnalyzing {
                    ProgressView().controlSize(.small)
                    Button("Cancel Analysis") { model.cancelAnalysis() }
                } else {
                    Button("Refresh Review") { model.load() }.disabled(busy || model.isLoading)
                }
                if app.results.isEmpty { Button("Scan Disk") { app.scan() }.disabled(busy) }
            }
        }
    }
    private var candidateList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if model.recommendations.isEmpty && !model.isLoading {
                    Text("No candidates passed this bounded review. Personal data, models, backups, linked files, and unrecognized directories remain in the normal results view.")
                        .foregroundStyle(.secondary).padding(.vertical)
                }
                ForEach(model.recommendations) { row in
                    if let candidate = model.candidate(row.candidateID) { candidateRow(candidate, row: row) }
                }
            }
        }
        .frame(minHeight: 160, maxHeight: .infinity)
    }
    private func candidateRow(_ candidate: CleanupCandidate, row: Recommendation) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("Select \(candidate.url.lastPathComponent)", isOn: Binding(
                get: { model.selectedIDs.contains(candidate.id) }, set: { _ in model.toggle(candidate.id) }))
                .labelsHidden().toggleStyle(.checkbox).disabled(busy || model.isAnalyzing)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(verbatim: candidate.url.lastPathComponent).font(.headline)
                    Text(row.disposition == .keep ? "Consider keeping" : "Review required").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(Format.bytes(candidate.allocatedBytes)).monospacedDigit()
                }
                Text(verbatim: Format.displayPath(candidate.url)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text(verbatim: row.reason.text).font(.callout)
                Text(row.appleRanked ? "Apple-ranked · explanation from verified evidence" : "Rules-based recommendation").font(.caption2).foregroundStyle(.secondary)
                DisclosureGroup("Observed facts") {
                    ForEach(candidate.evidence, id: \.rawValue) { evidence in Text(verbatim: evidence.description).font(.caption) }
                }
                HStack {
                    Button("Keep") { model.keep(candidate.id) }.disabled(busy)
                    Button("Always Exclude") { model.exclude(candidate) }.disabled(busy)
                    Button("Reveal in Finder") { FileActions.reveal(candidate.url) }
                }.controlSize(.small)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
    private var exclusionsAndHistory: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup("Persistent exclusions (\(model.excludedPaths.count))") {
                ScrollView {
                    ForEach(model.excludedPaths, id: \.self) { path in
                        HStack {
                            Text(verbatim: path).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Remove") { model.removeExclusion(path) }.disabled(busy)
                        }
                    }
                }.frame(maxHeight: 90)
            }
            DisclosureGroup("Restore this session’s Trash moves (\(model.history.count))") {
                Text("History is bounded and kept only for this session. After restarting, recover files through Finder’s Trash.").font(.caption)
                ScrollView {
                    ForEach(model.history.reversed()) { record in
                        HStack {
                            Text(verbatim: record.originalURL.lastPathComponent).font(.caption)
                            Spacer()
                            Button("Restore") { model.restore(record) }.disabled(busy || record.trashStamp == nil)
                        }
                    }
                }.frame(maxHeight: 90)
            }
        }
    }
    private func review(_ plan: ReviewPlan) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Confirm these exact items").font(.title2.bold())
            Text("Only these \(plan.candidates.count) items will move to Trash. The permanent-delete setting is ignored. Emptying Trash is a separate action; this move does not immediately free \(Format.bytes(plan.footprint)).")
            ScrollView {
                ForEach(plan.candidates) { candidate in
                    HStack {
                        Text(verbatim: Format.displayPath(candidate.url)).textSelection(.enabled)
                        Spacer()
                        Text(Format.bytes(candidate.allocatedBytes))
                    }.padding(.vertical, 4)
                }
            }
            Text("Metadata and protections are checked again before execution. Changed or unreadable items require another review.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.discardReview() }
                Button("Move \(plan.candidates.count) Items to Trash", role: .destructive) { model.execute(plan) }
                    .buttonStyle(.borderedProminent).disabled(app.isCleaning || app.isScanning || app.scanGeneration != plan.snapshotID)
            }
        }
        .padding(24).frame(width: 680, height: 420)
        .interactiveDismissDisabled()
    }
}
