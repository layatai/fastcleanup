import SwiftUI

@main
struct FastCleanupApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            RootView().environmentObject(state)
        } label: {
            Image(systemName: state.disk.usedFraction > 0.9
                  ? "externaldrive.fill.badge.exclamationmark" : "sparkles")
        }
        .menuBarExtraStyle(.window)
    }
}
