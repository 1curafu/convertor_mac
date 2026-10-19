import AppKit
import SwiftUI

/// The ⌃ wheel: things to do with a file other than converting it.
@MainActor
enum FileActions {
    static func perform(_ action: FileAction, on urls: [URL]) {
        guard let first = urls.first else { return }
        let pasteboard = NSPasteboard.general

        switch action {
        case .airDrop:
            NSApp.activate(ignoringOtherApps: true)
            NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
        case .copy:
            pasteboard.clearContents()
            pasteboard.writeObjects(urls as [NSURL])
        case .copyPath:
            pasteboard.clearContents()
            pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        case .move:
            // Let the drag session finish before running a modal panel.
            DispatchQueue.main.async { move(urls) }
        case .float:
            urls.forEach(FloatPanel.show)
        case .terminal:
            let isFolder = (try? first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let folder = isFolder ? first : first.deletingLastPathComponent()
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
            NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private static func move(_ urls: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Move Here"
        panel.message = "Move \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files") to…"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        for url in urls {
            let ext = url.pathExtension
            let name = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
            let target = Output.unique(destination, name: name, ext: ext.isEmpty ? nil : ext)
            do {
                try FileManager.default.moveItem(at: url, to: target)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}

/// A small always-on-top window holding a file, which can be dragged back out anywhere.
@MainActor
enum FloatPanel {
    private static var panels: [NSPanel] = []

    static func show(_ url: URL) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = url.lastPathComponent
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: FloatView(url: url))

        let mouse = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: mouse.x + 24 * CGFloat(panels.count % 5), y: mouse.y - 220))
        panel.orderFrontRegardless()
        panels.append(panel)

        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { note in
            MainActor.assumeIsolated {
                panels.removeAll { $0 === note.object as? NSPanel }
            }
        }
    }
}

private struct FloatView: View {
    let url: URL

    var body: some View {
        Image(nsImage: NSImage(contentsOf: url) ?? NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .scaledToFit()
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
            .help("Drag the file out of this window")
    }
}
