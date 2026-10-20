import AppKit
import SwiftUI
import XCTest
@testable import Convertor

/// Renders the wheel, menu, settings and every editor window to PNGs in light and dark mode,
/// so the UI can be reviewed without a person at the Mac. Runs only when
/// `$CONVERTOR_SNAPSHOT_OUT` is set (CI uploads that folder as an artifact).
@MainActor
final class SnapshotTests: XCTestCase {
    private var out: URL!
    private var fixtures: URL!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["CONVERTOR_SNAPSHOT_OUT"] else {
            throw XCTSkip("set CONVERTOR_SNAPSHOT_OUT to render UI snapshots")
        }
        out = URL(fileURLWithPath: path)
        fixtures = FileManager.default.temporaryDirectory.appendingPathComponent("ConvertorSnapshotFixtures")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        Prefs.registerDefaults()
    }

    // MARK: Capture

    private let appearances: [(name: String, appearance: NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]

    /// Draws a window's content into a PNG, and also asks the window server for a real screenshot
    /// (which includes materials and Liquid Glass) when the runner allows it.
    private func capture(_ window: NSWindow, as name: String) async throws {
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name).png"))
        }
        let screen = out.appendingPathComponent("\(name)-screen.png")
        _ = try? await Shell.capture("/usr/sbin/screencapture", ["-x", "-o", "-l", "\(window.windowNumber)", screen.path])
    }

    private func show<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name, transparent: Bool = false) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: 80, y: 80), size: size),
                              styleMask: transparent ? [.borderless] : [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        if transparent {
            window.isOpaque = false
            window.backgroundColor = .clear
        }
        window.contentView = NSHostingView(rootView: view)
        window.setContentSize(size)
        window.orderFrontRegardless()
        return window
    }

    // MARK: Fixtures

    private func fixture(_ name: String) -> URL { fixtures.appendingPathComponent(name) }

    private func photo(_ name: String, width: Int = 1200, height: Int = 800) throws -> URL {
        let url = fixture(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [CGColor(srgbRed: 0.98, green: 0.62, blue: 0.25, alpha: 1), CGColor(srgbRed: 0.35, green: 0.55, blue: 0.95, alpha: 1)]
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85))
        ctx.fillEllipse(in: CGRect(x: width / 3, y: height / 4, width: height / 2, height: height / 2))
        try ImageEngine.write(ctx.makeImage()!, to: url, ext: "png", quality: 1, metadata: nil)
        return url
    }

    private func media(_ name: String, video: Bool) async throws -> URL {
        let url = fixture(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let ffmpeg = FFmpeg.path else { throw XCTSkip("ffmpeg not available") }
        var args = ["-y", "-loglevel", "error"]
        if video { args += ["-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30:duration=6"] }
        args += ["-f", "lavfi", "-i", "sine=frequency=330:beep_factor=4:duration=6"]
        if video { args += ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest"] }
        try await Shell.run(ffmpeg, args + [url.path])
        return url
    }

    private func pdf(_ name: String) throws -> URL {
        let url = fixture(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let text = StructuredText(markdown: (1...6).map { "# Page \($0)\n\nSome text for page \($0). " + String(repeating: "Lorem ipsum dolor sit amet. ", count: 60) }
            .joined(separator: "\n\n"))
        try DocumentEngine.printToPDF(text.attributedString, output: url)
        return url
    }

    // MARK: Wheel

    func testWheels() async throws {
        let image = try photo("photo.png")
        let video = try await media("clip.mp4", video: true)
        let audio = try await media("voice.mp3", video: false)
        let document = try pdf("report.pdf")
        let cases: [(name: String, urls: [URL], mode: Mode, hovered: Int?)] = [
            ("wheel-image-convert", [image], .convert, 0),
            ("wheel-image-tools", [image], .tools, 3),
            ("wheel-images-tools", [image, image], .tools, nil),
            ("wheel-video-tools", [video], .tools, 5),
            ("wheel-audio-tools", [audio], .tools, 6),
            ("wheel-pdf-convert", [document], .convert, 1),
            ("wheel-actions", [image], .actions, 2),
        ]
        for (name, urls, mode, hovered) in cases {
            for (theme, appearance) in appearances {
                let model = WheelModel()
                model.load(urls, mode: mode)
                model.hovered = hovered
                model.visible = true
                let window = show(WheelView(model: model), size: WheelGeometry.size, appearance: appearance, transparent: true)
                try await Task.sleep(for: .milliseconds(600))
                try await capture(window, as: "\(name)-\(theme)")
                window.close()
            }
        }
    }

    // MARK: Menu bar and settings

    func testMenuAndSettings() async throws {
        let center = ConversionCenter.shared
        center.run("holiday.mov → MP4") { try await Task.sleep(for: .seconds(30)); return [] }
        center.run("report.pdf → DOCX") { [] }
        center.run("song.flac → OPUS") { throw ConvertError("This format needs ffmpeg.") }
        try await Task.sleep(for: .milliseconds(300))

        for (theme, appearance) in appearances {
            let menu = show(MenuContentView().environmentObject(center), size: CGSize(width: 320, height: 420), appearance: appearance)
            try await Task.sleep(for: .milliseconds(600))
            try await capture(menu, as: "menu-\(theme)")
            menu.close()

            let settings = show(SettingsView(), size: CGSize(width: 480, height: 640), appearance: appearance)
            try await Task.sleep(for: .milliseconds(600))
            try await capture(settings, as: "settings-\(theme)")
            settings.close()
        }
    }

    // MARK: Editors

    /// Opens each editor through the real code path, waits for it to load its file, and captures it.
    func testEditors() async throws {
        let image = try photo("photo.png")
        let portrait = try photo("portrait.png", width: 800, height: 1200)
        let video = try await media("clip.mp4", video: true)
        let audio = try await media("voice.mp3", video: false)
        let document = try pdf("report.pdf")

        let editors: [(name: String, tool: Tool, urls: [URL])] = [
            ("crop", .crop, [image]), ("annotate", .annotate, [image]), ("redact", .redact, [image]),
            ("background", .addBackground, [image]), ("edit", .edit, [image]), ("collage", .collage, [image, portrait]),
            ("metadata-image", .metadata, [image]), ("metadata-video", .metadata, [video]), ("metadata-pdf", .metadata, [document]),
            ("trim-video", .trim, [video]), ("trim-audio", .trim, [audio]), ("bleep", .bleep, [audio]),
            ("split", .split, [video]), ("snapshot", .snapshot, [video]), ("crop-video", .crop, [video]),
            ("redact-video", .redact, [video]), ("speed", .speed, [video]), ("visualize", .visualize, [audio]),
            ("channels", .channels, [audio]), ("join", .join, [video, video]), ("organize", .organize, [document]),
        ]

        for (name, tool, urls) in editors {
            for (theme, appearance) in appearances {
                let before = Editors.windows.count
                Editors.open(tool, title: name, urls: urls)
                let window = try XCTUnwrap(Editors.windows.last, "\(name) didn't open a window")
                XCTAssertEqual(Editors.windows.count, before + 1, name)
                window.appearance = NSAppearance(named: appearance)
                try await Task.sleep(for: .seconds(2.5))   // let the editor load its file
                try await capture(window, as: "editor-\(name)-\(theme)")
                window.close()
            }
        }
    }
}
