import AppKit
import SwiftUI

@MainActor
final class ResultsWindowController: NSObject, NSWindowDelegate {
    static let shared = ResultsWindowController()
    private var window: NSWindow?

    func show(state: AppState) {
        if window == nil {
            let host = NSHostingController(rootView: ResultsRootView().environmentObject(state))
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
    func windowWillClose(_ notification: Notification) { NSApp.setActivationPolicy(.accessory) }
}
