import SwiftUI
import AppKit

struct RootView: View {
    @EnvironmentObject var state: AppState
    @State private var showSettings = false
    @State private var expanded: Set<String> = []

    // User-resizable panel size, persisted across launches. MenuBarExtra windows
    // aren't natively resizable, so we drive the frame from storage and resize it
    // via the corner grip below.
    @AppStorage("panelWidth") private var panelWidth: Double = 400
    @AppStorage("panelHeight") private var panelHeight: Double = 540
    @State private var resizeBase: CGSize?

    static let minSize = CGSize(width: 360, height: 420)
    static let maxSize = CGSize(width: 760, height: 1040)

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(showSettings: $showSettings)
            Divider()
            if showSettings {
                SettingsView(showSettings: $showSettings)
            } else {
                content
            }
        }
        .frame(width: panelWidth, height: panelHeight)
        .background(.background)
        .overlay(alignment: .bottomTrailing) { resizeGrip }
    }

    @ViewBuilder private var content: some View {
        if state.isScanning && state.results.isEmpty {
            ScanningView().frame(maxHeight: .infinity)
        } else if state.results.isEmpty {
            EmptyStateView().frame(maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 14) {
                    OverviewCard()
                    CategoryListCard(expanded: $expanded)
                }
                .padding(14)
            }
            .frame(maxHeight: .infinity)
            FclonesSuggestionBanner()
            FooterView()
        }
    }

    private var resizeGrip: some View {
        ResizeGrip()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let base = resizeBase ?? CGSize(width: panelWidth, height: panelHeight)
                        if resizeBase == nil { resizeBase = base }
                        panelWidth = min(max(base.width + value.translation.width,
                                             Self.minSize.width), Self.maxSize.width)
                        panelHeight = min(max(base.height + value.translation.height,
                                             Self.minSize.height), Self.maxSize.height)
                    }
                    .onEnded { _ in resizeBase = nil }
            )
            .help("Drag to resize")
    }
}

/// Classic macOS bottom-right resize grip (diagonal ticks). Shows a frame-resize
/// pointer on hover where the OS supports it (macOS 15+).
struct ResizeGrip: View {
    var body: some View {
        let grip = Canvas { ctx, size in
            var p = Path()
            for off in stride(from: 1.0, through: 9.0, by: 4.0) {
                p.move(to: CGPoint(x: size.width - 1, y: size.height - off))
                p.addLine(to: CGPoint(x: size.width - off, y: size.height - 1))
            }
            ctx.stroke(p, with: .color(.secondary.opacity(0.55)), lineWidth: 1.3)
        }
        .frame(width: 15, height: 15)

        if #available(macOS 15.0, *) {
            grip.pointerStyle(.frameResize(position: .bottomTrailing))
        } else {
            grip
        }
    }
}

struct HeaderView: View {
    @EnvironmentObject var state: AppState
    @Binding var showSettings: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 16, weight: .semibold)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("FastCleanup").font(.headline)
                Text(state.lastScan == nil ? "Ready to scan"
                     : "Scanned \(Format.relativeDate(state.lastScan))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                ResultsWindowController.shared.show(state: state)
            } label: {
                Image(systemName: "macwindow")
            }.buttonStyle(.borderless).help("Open results in a window")
            Button { showSettings.toggle() } label: {
                Image(systemName: showSettings ? "xmark" : "gearshape")
            }.buttonStyle(.borderless).help("Settings")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

struct DiskGauge: View {
    let disk: DiskSpace
    private var color: Color {
        switch disk.usedFraction { case ..<0.75: return .green; case ..<0.9: return .orange; default: return .red }
    }
    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.15), lineWidth: 10)
            Circle().trim(from: 0, to: disk.usedFraction)
                .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(Format.bytes(disk.free)).font(.system(size: 14, weight: .bold))
                Text("free").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 92, height: 92)
        .animation(.easeOut(duration: 0.5), value: disk.usedFraction)
    }
}

struct OverviewCard: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                DiskGauge(disk: state.disk)
                VStack(alignment: .leading, spacing: 6) {
                    Text("RECLAIMABLE").font(.caption2).foregroundStyle(.secondary)
                    Text(Format.bytes(state.reclaimable))
                        .font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(.tint)
                    HStack(spacing: 4) {
                        Image(systemName: "internaldrive")
                        Text("\(Format.bytes(state.disk.used)) of \(Format.bytes(state.disk.total)) used")
                    }.font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if !state.nonEmptyResults.isEmpty {
                UsageDonut(results: state.nonEmptyResults).frame(height: 160)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(.quaternary.opacity(0.4)))
    }
}

struct CategoryListCard: View {
    @EnvironmentObject var state: AppState
    @Binding var expanded: Set<String>
    var body: some View {
        let rows = state.nonEmptyResults
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, r in
                CategoryRow(result: r,
                            isSelected: state.selected.contains(r.id),
                            isExpanded: expanded.contains(r.id),
                            onToggleSelect: { state.toggle(r.id) },
                            onToggleExpand: {
                                if expanded.contains(r.id) { expanded.remove(r.id) } else { expanded.insert(r.id) }
                            })
                if idx < rows.count - 1 { Divider().padding(.leading, 44) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(.quaternary.opacity(0.4)))
    }
}

struct CategoryRow: View {
    @EnvironmentObject var state: AppState
    let result: CategoryResult
    let isSelected: Bool
    let isExpanded: Bool
    let onToggleSelect: () -> Void
    let onToggleExpand: () -> Void
    @State private var hoveredItem: ScanItem.ID?
    private var def: CategoryDefinition { result.definition }
    private var revealURL: URL? { result.topItems.first?.url ?? def.roots.first }

    @ViewBuilder private func itemMenu(_ item: ScanItem) -> some View {
        Button { FileActions.open(item.url) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
        Button { FileActions.reveal(item.url) } label: { Label("Reveal in Finder", systemImage: "folder") }
        Divider()
        Button { FileActions.copy(item.path) } label: { Label("Copy Path", systemImage: "doc.on.doc") }
        Button { FileActions.copy(item.name) } label: { Label("Copy Name", systemImage: "textformat") }
        Divider()
        Button(role: .destructive) { state.trashItem(item, inCategory: def.id) } label: {
            Label("Move to Trash", systemImage: "trash")
        }
    }

    @ViewBuilder private var categoryMenu: some View {
        if let u = revealURL {
            Button { FileActions.reveal(u) } label: { Label("Reveal in Finder", systemImage: "folder") }
        }
        Button(action: onToggleSelect) {
            Label(isSelected ? "Deselect" : "Select",
                  systemImage: isSelected ? "circle" : "checkmark.circle.fill")
        }
        Button(action: onToggleExpand) {
            Label(isExpanded ? "Collapse" : "Expand Items",
                  systemImage: isExpanded ? "chevron.down" : "chevron.right")
        }
        Divider()
        if let root = def.roots.first {
            Button { FileActions.copy(root.path) } label: { Label("Copy Path", systemImage: "doc.on.doc") }
        }
        Button { FileActions.copy(Format.bytes(result.totalSize)) } label: {
            Label("Copy Size", systemImage: "number")
        }
        Divider()
        Button(role: .destructive) { state.cleanCategory(def.id) } label: {
            Label(cleanActionLabel.text, systemImage: cleanActionLabel.icon)
        }
    }

    private var cleanActionLabel: (text: String, icon: String) {
        switch def.action {
        case .trash:              return ("Move All to Trash", "trash")
        case .gitCompact:         return ("Compact with git gc", "arrow.triangle.2.circlepath")
        case .command(let c):     return ("Run \(c.display)", "terminal")
        case .dedupeNodeModules:  return ("Deduplicate (APFS clones)", "square.on.square.dashed")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onToggleSelect) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(isSelected ? def.tint : Color.secondary.opacity(0.5))
                }.buttonStyle(.plain)

                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(def.tint.opacity(0.18)).frame(width: 28, height: 28)
                    Image(systemName: def.systemImage).font(.system(size: 13, weight: .semibold)).foregroundStyle(def.tint)
                }

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(def.title).font(.system(size: 13, weight: .semibold))
                        if def.safety == .caution {
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(.orange)
                        }
                    }
                    Text("\(result.count) item\(result.count == 1 ? "" : "s") · \(def.subtitle)")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(Format.bytes(result.totalSize)).font(.system(size: 13, weight: .semibold, design: .rounded))
                Button(action: onToggleExpand) {
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Hide items" : "Show items")
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggleSelect)
            .contextMenu { categoryMenu }

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(result.topItems.prefix(8)) { item in
                        HStack(spacing: 8) {
                            Image(systemName: "doc").font(.system(size: 10)).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).font(.caption2).lineLimit(1).truncationMode(.middle)
                                // Where it lives — disambiguates many same-named items (node_modules, dist…).
                                Text(Format.locationPath(item.url))
                                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                                    .lineLimit(1).truncationMode(.head)
                            }
                            Spacer(minLength: 8)
                            Text(Format.bytes(item.size)).font(.caption2).foregroundStyle(.secondary)
                            if !def.isCommandBased {
                                Button { state.trashItem(item, inCategory: def.id) } label: {
                                    Image(systemName: "trash").font(.system(size: 11))
                                }
                                .buttonStyle(.plain).foregroundStyle(.red)
                                .opacity(hoveredItem == item.id ? 1 : 0)
                                .help("Move to Trash")
                                .frame(width: 16)
                            }
                        }
                        .padding(.vertical, 4).padding(.leading, 44).padding(.trailing, 12)
                        .contentShape(Rectangle())
                        .help(item.path)
                        .onHover { inside in
                            if inside { hoveredItem = item.id }
                            else if hoveredItem == item.id { hoveredItem = nil }
                        }
                        .onTapGesture(count: 2) { FileActions.reveal(item.url) }
                        .contextMenu { itemMenu(item) }
                    }
                    if result.count > 8 {
                        Text("+ \(result.count - 8) more").font(.caption2).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 44).padding(.bottom, 4)
                    }
                }
            }
        }
    }
}

struct FooterView: View {
    @EnvironmentObject var state: AppState
    @State private var confirming = false
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Button { state.scan() } label: {
                    Label(state.isScanning ? "Scanning…" : "Rescan", systemImage: "arrow.clockwise")
                }.disabled(state.isScanning || state.isCleaning)
                Spacer()
                if let msg = state.statusMessage {
                    Text(msg).font(.caption).foregroundStyle(.green)
                }
                Button { confirming = true } label: {
                    if state.isCleaning { Label("Cleaning…", systemImage: "hourglass") }
                    else { Text("Clean \(Format.bytes(state.selectedSize))") }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(state.selected.isEmpty || state.isCleaning || state.isScanning)
                .confirmationDialog(
                    "Clean \(Format.bytes(state.selectedSize)) across \(state.selectedCount) items?",
                    isPresented: $confirming, titleVisibility: .visible) {
                    Button("Clean Now", role: .destructive) { state.cleanSelected() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(state.cleanSummary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }
}

/// Shown when `fclones` isn't installed on an APFS volume — offers a one-click
/// Homebrew install that unlocks the non-destructive node_modules dedupe action.
struct FclonesSuggestionBanner: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        if state.canSuggestFclones {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Shrink node_modules without deleting")
                        .font(.system(size: 12, weight: .medium))
                    Text("Install fclones to dedupe identical files via APFS clones.")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                Button { state.installFclones() } label: {
                    if state.isInstallingTool { ProgressView().controlSize(.small) }
                    else { Text("Install") }
                }
                .controlSize(.small)
                .disabled(state.isInstallingTool)
                .help("brew install fclones")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.tint.opacity(0.08))
        }
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(spacing: 16) {
            DiskGauge(disk: state.disk)
            VStack(spacing: 4) {
                Text("\(Format.bytes(state.disk.free)) free of \(Format.bytes(state.disk.total))").font(.headline)
                Text("Scan to find caches, build artifacts, and junk you can safely remove.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 30)
            }
            Button { state.scan() } label: {
                Label("Scan Now", systemImage: "magnifyingglass").frame(maxWidth: 160)
            }.controlSize(.large).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
}

struct ScanningView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(spacing: 18) {
            ProgressView(value: state.progress.fraction) {
                Text("Scanning…").font(.headline)
            } currentValueLabel: {
                Text(state.progress.current ?? "Preparing").font(.caption).foregroundStyle(.secondary)
            }
            .progressViewStyle(.linear).frame(width: 260)
            Text("\(state.progress.completed) / \(state.progress.total) categories")
                .font(.caption).foregroundStyle(.secondary)
            Button("Cancel", role: .cancel) { state.cancelScan() }.controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
}

enum FileActions {
    static func open(_ url: URL) { _ = NSWorkspace.shared.open(url) }
    static func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    static func copy(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }
}

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @Binding var showSettings: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $state.useTrash) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Move to Trash").font(.system(size: 13, weight: .medium))
                    Text("Recommended — items can be recovered. Turn off to delete permanently.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack {
                Text("FastCleanup 1.1").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Quit", role: .destructive) { NSApplication.shared.terminate(nil) }.controlSize(.small)
            }
        }
        .padding(16).frame(maxHeight: .infinity, alignment: .top)
    }
}
