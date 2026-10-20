import SwiftUI
import AppKit

@main
struct ConvertorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // The menu bar icon is an AppKit status item (see StatusItem.swift): MenuBarExtra has no
    // right-click menu and toggles its window twice on a double click.
    var body: some Scene {
        Settings {
            SettingsView()
        }
        // ⌘, (while an editor puts the app in the Dock) opens the same window as the panel.
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { SettingsWindow.show() }.keyboardShortcut(",")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var dragMonitor: DragMonitor?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        NSApp.setActivationPolicy(.accessory)
        statusItem = StatusItemController()
        let monitor = DragMonitor()
        monitor.start()
        dragMonitor = monitor
    }
}
