import SwiftUI
import AppKit

@main
struct ConvertorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Convertor", systemImage: "arrow.triangle.2.circlepath") {
            MenuContentView()
                .environmentObject(ConversionCenter.shared)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let dragMonitor = DragMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        NSApp.setActivationPolicy(.accessory)
        dragMonitor.start()
    }
}
