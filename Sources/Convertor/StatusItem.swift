import AppKit
import SwiftUI

/// The menu bar icon. A click opens the Convertor panel and a second click closes it; a double click
/// leaves it open. A right-click or ⌃-click opens a short menu with Settings and Quit.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let popover = NSPopover()
    private var monitors: [Any] = []
    private var dragCountAtPress = 0

    override init() {
        super.init()
        let hosting = NSHostingController(rootView: MenuContentView(close: { [weak self] in self?.closePanel() })
            .environmentObject(ConversionCenter.shared))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        // Not .transient: that closes on the icon's own mouse-down (so a click would reopen it) and
        // whenever the app isn't active. The panel closes on clicks elsewhere instead (see openPanel).
        popover.behavior = .applicationDefined
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
        } else {
            openPanel()
        }
    }

    @objc func openPanel() {
        guard !popover.isShown, let button = item.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()

        // A click in another app closes the panel, but only once the button is released without
        // a drag starting: dragging a file from Finder onto the panel starts with that same press.
        let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown]) { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.otherAppClicked(type) }
        }
        let inside = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            let swallow = MainActor.assumeIsolated { self?.closeIfOutside(event) ?? false }
            return swallow ? nil : event
        }
        monitors = [outside, inside].compactMap { $0 }
    }

    private func otherAppClicked(_ type: NSEvent.EventType) {
        let count = NSPasteboard(name: .drag).changeCount
        if type == .leftMouseDown { dragCountAtPress = count }
        else if type == .rightMouseDown || count == dragCountAtPress { closePanel() }
    }

    /// Closes the panel on Escape (swallowing the key) or a click in another of the app's windows.
    /// Clicks on the icon itself are left to `clicked`.
    private func closeIfOutside(_ event: NSEvent) -> Bool {
        guard NSApp.modalWindow == nil else { return false }  // e.g. the panel's Choose Files… dialog
        if event.type == .keyDown {
            guard event.keyCode == 53 else { return false }
            closePanel()
            return true
        }
        if event.window !== popover.contentViewController?.view.window && event.window !== item.button?.window {
            closePanel()
        }
        return false
    }

    func closePanel() { popover.performClose(nil) }

    func popoverDidClose(_ notification: Notification) {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    /// False until the menu bar has placed the icon. Headless sessions (CI) never do: the icon's
    /// window stays zero-height and a panel can't be anchored to it.
    var isInMenuBar: Bool { (item.button?.window?.frame.height ?? 0) > 0 }

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
