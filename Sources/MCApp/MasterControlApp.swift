import AppKit
import SwiftUI

@main
struct MasterControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(coordinator: coordinator)
        } label: {
            Image(systemName: coordinator.state.symbolName)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Hides the app from the Dock so it lives entirely in the menu bar.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct MenuContent: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        Text(coordinator.state.label)

        Divider()

        if coordinator.events.isEmpty {
            Text("No activity yet").disabled(true)
        } else {
            // Show most recent first.
            ForEach(Array(coordinator.events.suffix(10).reversed())) { event in
                ActivityRow(event: event)
            }
            Divider()
            Button("Clear activity") { coordinator.clearEvents() }
        }

        Divider()

        Button(coordinator.paused ? "Resume listening" : "Pause listening") {
            coordinator.togglePause()
        }
        .keyboardShortcut("p")

        Button("Settings…") {
            SettingsWindowController.shared.show()
        }
        .keyboardShortcut(",")

        Button("Quit MasterControl") {
            coordinator.quit()
        }
        .keyboardShortcut("q")
    }
}

struct ActivityRow: View {
    let event: ActivityEvent

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        let time = Self.timeFormatter.string(from: event.timestamp)
        let summary: String = {
            let head = event.heard.isEmpty ? "(silence)" : "\u{201C}\(event.heard)\u{201D}"
            return "\(time)  \(head)  →  \(event.status.summary)"
        }()
        Text(summary)
            .disabled(true)
    }
}
