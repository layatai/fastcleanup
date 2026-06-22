import SwiftUI
import AppKit

/// A full, native results window: category sidebar + sortable item table, with a
/// real title bar, toolbar, and multi-selection. Opened from the menu-bar popover.
struct DetailWindowView: View {
    @EnvironmentObject var state: AppState
    @State private var selectedCategoryID: String?
    @State private var selection = Set<ScanItem.ID>()
    @State private var sortOrder = [KeyPathComparator(\ScanItem.size, order: .reverse)]

    private var categories: [CategoryResult] { state.nonEmptyResults }
    private var current: CategoryResult? {
        categories.first { $0.id == selectedCategoryID } ?? categories.first
    }
    private var rows: [ScanItem] { (current?.items ?? []).sorted(using: sortOrder) }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 780, minHeight: 480)
        .toolbar { toolbar }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selectedCategoryID) {
            Section("Categories") {
                ForEach(categories) { r in
                    sidebarRow(r).tag(r.id)
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 248)
        .safeAreaInset(edge: .bottom) { diskFooter }
    }

    private func sidebarRow(_ r: CategoryResult) -> some View {
        HStack(spacing: 9) {
            Toggle("", isOn: Binding(
                get: { state.selected.contains(r.id) },
                set: { _ in state.toggle(r.id) }))
                .toggleStyle(.checkbox).labelsHidden()
            Image(systemName: r.definition.systemImage)
                .foregroundStyle(r.definition.tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(r.definition.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if r.definition.safety == .caution {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8)).foregroundStyle(.orange)
                    }
                }
                Text("\(r.count) item\(r.count == 1 ? "" : "s")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Text(Format.bytes(r.totalSize))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    private var diskFooter: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 18)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(Format.bytes(state.disk.free)) free")
                        .font(.system(size: 12, weight: .medium))
                    Text("\(Format.bytes(state.reclaimable)) reclaimable")
                        .font(.caption2).foregroundStyle(.tint)
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if state.results.isEmpty {
            ContentUnavailableView {
                Label("No results yet", systemImage: "sparkles")
            } description: {
                Text("Scan to find caches, build artifacts, and junk you can safely remove.")
            } actions: {
                Button("Scan Now") { state.scan() }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isScanning)
            }
        } else if let cat = current {
            VStack(spacing: 0) {
                FclonesSuggestionBanner()
                table(cat)
            }
            .navigationTitle(cat.definition.title)
            .navigationSubtitle("\(cat.count) items · \(Format.bytes(cat.totalSize)) · \(cat.definition.subtitle)")
        } else {
            ContentUnavailableView("Select a category", systemImage: "sidebar.left")
        }
    }

    private func table(_ cat: CategoryResult) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { item in
                HStack(spacing: 6) {
                    Image(systemName: "doc").foregroundStyle(.secondary)
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                }
            }
            TableColumn("Location", value: \.location) { item in
                Text(item.location).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head).help(item.path)
            }
            TableColumn("Modified", value: \.sortableModified) { item in
                Text(item.modified.map(Format.relativeDate) ?? "—").foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 110)
            TableColumn("Size", value: \.size) { item in
                Text(Format.bytes(item.size)).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 80, ideal: 96)
            TableColumn("") { item in
                if !cat.definition.isCommandBased {
                    Button {
                        state.trashItems([item], inCategory: cat.id)
                        selection.remove(item.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Move to Trash")
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .width(34)
        }
        .contextMenu(forSelectionType: ScanItem.ID.self) { ids in
            rowMenu(ids, in: cat)
        } primaryAction: { ids in
            if let it = cat.items.first(where: { ids.contains($0.id) }) { FileActions.reveal(it.url) }
        }
    }

    @ViewBuilder private func rowMenu(_ ids: Set<ScanItem.ID>, in cat: CategoryResult) -> some View {
        let chosen = cat.items.filter { ids.contains($0.id) }
        if chosen.count == 1, let one = chosen.first {
            Button { FileActions.open(one.url) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
            Button { FileActions.reveal(one.url) } label: { Label("Reveal in Finder", systemImage: "folder") }
            Divider()
            Button { FileActions.copy(one.path) } label: { Label("Copy Path", systemImage: "doc.on.doc") }
            Divider()
        }
        if !chosen.isEmpty && !cat.definition.isCommandBased {
            Button(role: .destructive) {
                state.trashItems(chosen, inCategory: cat.id)
                selection.removeAll()
            } label: {
                Label(chosen.count > 1 ? "Move \(chosen.count) Items to Trash" : "Move to Trash",
                      systemImage: "trash")
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let msg = state.statusMessage {
                Label(msg, systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            Button { state.scan() } label: {
                Label(state.isScanning ? "Scanning…" : "Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(state.isScanning || state.isCleaning)

            Button { state.cleanSelected() } label: {
                Label(state.isCleaning ? "Cleaning…" : "Clean \(Format.bytes(state.selectedSize))",
                      systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .disabled(state.selected.isEmpty || state.isCleaning || state.isScanning)
        }
    }
}
