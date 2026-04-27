import AppKit
import SwiftUI

/// Hosts `SettingsView` in an `NSWindow` we control directly.
///
/// SwiftUI's `Settings { … }` scene is fragile in menu-bar
/// (`LSUIElement`) apps: `showSettingsWindow:` finds nothing to
/// activate, or the window opens hidden behind every other app and the
/// user can't tab to it. Owning the window lets us reliably bring it
/// forward and close it.
@MainActor
final class SettingsWindowController {

    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private init() {}

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "MasterControl Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("MasterControlSettings")
            self.window = window
        }
        // Activate the (otherwise dock-less) menu-bar app so the
        // window can become key. Without this the window appears but
        // stays unfocused behind whatever is in front.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
