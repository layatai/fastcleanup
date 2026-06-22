import AppKit
import SwiftUI

/// Lazily creates and shows the native results window on demand. Using an AppKit
/// window (rather than a SwiftUI `Window` scene) keeps this menu-bar/agent app from
/// auto-opening a window at launch, and lets us flip the activation policy to
/// `.regular` only while the window is visible — so a Dock icon and app menu appear
/// when there's a real window, and disappear again once it closes.
@MainActor
final class ResultsWindowController: NSObject, NSWindowDelegate {
    static let shared = ResultsWindowController()
    private var window: NSWindow?

    func show(state: AppState) {
        if window == nil {
            let host = NSHostingController(rootView: DetailWindowView().environmentObject(state))
            // Bridge SwiftUI navigationTitle / .toolbar into the real window chrome.
            host.sceneBridgingOptions = [.all]

            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.title = "FastCleanup"
            w.titlebarAppearsTransparent = false
            w.setContentSize(NSSize(width: 940, height: 620))
            w.contentMinSize = NSSize(width: 780, height: 480)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            w.setFrameAutosaveName("FastCleanupResultsWindow")
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a pure menu-bar utility (no Dock icon) when the window is dismissed.
        NSApp.setActivationPolicy(.accessory)
    }
}
