import AppKit
import SwiftUI

/// Watches system-wide file drags and opens the wheel when a modifier is tapped mid-drag:
/// ⇧ convert, ⌘ tools, ⌃ actions. Pressing another of those keys switches wheels.
///
/// Global mouse monitors don't need Accessibility permission, and modifier state is polled
/// with `NSEvent.modifierFlags`, so the app works without any privacy prompts.
@MainActor
final class DragMonitor {
    private let model = WheelModel()
    private lazy var panel = makePanel()
    private var monitor: Any?
    private var timer: Timer?
    private var baselineChangeCount = NSPasteboard(name: .drag).changeCount
    private var dragURLs: [URL] = []
    private var lastFlags: NSEvent.ModifierFlags = []

    func start() {
        model.onPerform = { [weak self] action, urls in
            guard let self else { return }
            Task { @MainActor in
                self.hide(after: 0)
                ConversionCenter.shared.perform(action, on: urls)
            }
        }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDragged() }
        }
    }

    /// A new file drag shows up as a change on the drag pasteboard.
    private func mouseDragged() {
        guard timer == nil else { return }
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != baselineChangeCount else { return }
        baselineChangeCount = pasteboard.changeCount

        guard Prefs.defaults.bool(forKey: Prefs.gestureEnabled),
              let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty
        else { return }

        dragURLs = urls
        lastFlags = NSEvent.modifierFlags
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Polls the mouse button and modifier keys for the rest of the drag.
    private func tick() {
        if NSEvent.pressedMouseButtons & 1 == 0 {
            timer?.invalidate()
            timer = nil
            baselineChangeCount = NSPasteboard(name: .drag).changeCount
            // Leave the panel up a moment so a drop on it is still delivered.
            if panel.isVisible { hide(after: 0.35) }
            return
        }

        let flags = NSEvent.modifierFlags
        let pressed = flags.subtracting(lastFlags)
        lastFlags = flags

        let mode: Mode?
        if pressed.contains(.shift) { mode = .convert }
        else if pressed.contains(.command) { mode = .tools }
        else if pressed.contains(.control) { mode = .actions }
        else { mode = nil }
        guard let mode else { return }

        if panel.isVisible {
            model.mode = mode
        } else {
            show(mode: mode)
        }
    }

    private func show(mode: Mode) {
        model.load(dragURLs, mode: mode)
        let mouse = NSEvent.mouseLocation
        let size = WheelGeometry.size
        let center = WheelGeometry.center
        // Centre the donut (not the panel) on the cursor; AppKit's y axis points up.
        panel.setFrameOrigin(NSPoint(x: mouse.x - center.x, y: mouse.y - (size.height - center.y)))
        panel.orderFrontRegardless()
        model.visible = true
    }

    private func hide(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.timer == nil || delay == 0 else { return }
                self.model.visible = false
                self.model.hovered = nil
                self.panel.orderOut(nil)
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: WheelGeometry.size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: WheelView(model: model))
        host.frame = NSRect(origin: .zero, size: WheelGeometry.size)
        panel.contentView = host
        return panel
    }
}
