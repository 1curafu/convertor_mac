import AppKit
import SwiftUI

/// The menu bar icon. A click opens the Convertor panel; a right-click or ⌃-click opens a short menu
/// with Settings and Quit. A double click keeps the panel open instead of opening and closing it.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let popover = NSPopover()
    private var closedAt = Date.distantPast

    override init() {
        super.init()
        let hosting = NSHostingController(rootView: MenuContentView(close: { [weak self] in self?.closePanel() })
            .environmentObject(ConversionCenter.shared))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = false  // so a double click's second press can't catch it half closed
        popover.delegate = self

        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Convertor")
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if (event?.clickCount ?? 1) > 1 {
            openPanel()
        } else if popover.isShown {
            closePanel()
        } else if Date().timeIntervalSince(closedAt) > 0.3 {
            // A transient popover already closes on the mouse-down of the click that would toggle it.
            openPanel()
        }
    }

    @objc func openPanel() {
        guard !popover.isShown, let button = item.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func closePanel() { popover.performClose(nil) }

    /// False until the menu bar has placed the icon (or when macOS hides it from the menu bar).
    var isInMenuBar: Bool { item.button?.window != nil }

    func popoverDidClose(_ notification: Notification) { closedAt = Date() }

    private func showMenu() {
        guard let button = item.button else { return }
        closePanel()
        menu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
    }

    func menu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Convertor", action: #selector(openPanel), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Convertor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func openSettings() { SettingsWindow.show() }
}

/// The Settings window, opened from the panel or the right-click menu.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Convertor Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
