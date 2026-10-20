import AppKit
import PDFKit
import XCTest
@testable import Convertor

/// Every conversion on every wheel, for every kind of file, with the *content* of each result
/// checked: the marker text is really there (and visible on rendered pages), images aren't blank,
/// durations match, tables keep their cells. Runs in light and dark mode. Writes a report and a
/// preview of every result so a person (or Claude) can look at them.
@MainActor
final class MatrixTests: XCTestCase {
    private static let marker = "Convertor marker 42"

    private var root: URL!
    private var previews: URL?
    private var report: [String] = []
    private var failures: [String] = []

    override func setUp() async throws {
        let base = ProcessInfo.processInfo.environment["CONVERTOR_TEST_OUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("ConvertorTests")
        root = base.appendingPathComponent("matrix")
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let snapshots = ProcessInfo.processInfo.environment["CONVERTOR_SNAPSHOT_OUT"] {
            previews = URL(fileURLWithPath: snapshots).appendingPathComponent("matrix")
            try? FileManager.default.removeItem(at: previews!)
            try FileManager.default.createDirectory(at: previews!, withIntermediateDirectories: true)
        }
        Prefs.registerDefaults()
    }

    // MARK: Fixtures

    private func url(_ name: String, in folder: String = "sources") throws -> URL {
        let dir = root.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    private var markerText: NSAttributedString {
        // No foreground colour on purpose, like most Word files.
        let body = (1...40).map { "\($0). \(Self.marker) — the quick brown fox jumps over the lazy dog." }.joined(separator: "\n")
        let text = NSMutableAttributedString(string: "Report title\n", attributes: [.font: NSFont(name: "Helvetica-Bold", size: 24)!])
        text.append(NSAttributedString(string: body + "\n", attributes: [.font: NSFont(name: "Helvetica", size: 12)!]))
        return text
    }

    private func drawnImage(width: Int = 1200, height: Int = 800) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.4, blue: 0, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: width / 10, y: height / 2, width: height / 3, height: height / 3))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSAttributedString(string: Self.marker, attributes: [.font: NSFont(name: "Helvetica-Bold", size: 64)!, .foregroundColor: NSColor.black])
            .draw(at: CGPoint(x: 60, y: 120))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    private func makeFixtures() async throws -> [URL] {
        var files: [URL] = []
        func add(_ url: URL) { files.append(url) }

        // Images
        let png = try url("photo.png")
        try ImageEngine.write(drawnImage(), to: png, ext: "png", quality: 1, metadata: nil); add(png)
        let jpg = try url("portrait.jpg")
        let destination = CGImageDestinationCreateWithURL(jpg as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, drawnImage(), [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination)); add(jpg)
        let svg = try url("logo.svg")
        try """
        <svg xmlns="http://www.w3.org/2000/svg" width="400" height="200"><rect width="400" height="200" fill="#ffffff"/>\
        <circle cx="100" cy="100" r="80" fill="#ff5a1f"/><text x="200" y="110" font-size="32" fill="#000">Logo</text></svg>
        """.write(to: svg, atomically: true, encoding: .utf8); add(svg)

        // Documents
        let docx = try url("notes.docx")
        let text = markerText
        let range = NSRange(location: 0, length: text.length)
        try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: docx); add(docx)
        let rtf = try url("notes.rtf")
        try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: rtf); add(rtf)
        let odt = try url("notes.odt")
        try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.openDocument]).write(to: odt); add(odt)
        let html = try url("notes.html")
        try "<html><body><h1>Report title</h1><p>\(Self.marker) in <b>HTML</b>.</p></body></html>".write(to: html, atomically: true, encoding: .utf8); add(html)
        let md = try url("notes.md")
        try "# Report title\n\n\(Self.marker) in **Markdown**.\n\n- one\n- two\n".write(to: md, atomically: true, encoding: .utf8); add(md)
        let txt = try url("notes.txt")
        try "Report title\n\n\(Self.marker) in plain text.\n".write(to: txt, atomically: true, encoding: .utf8); add(txt)

        // PDFs: one with real text, one scanned (image only, needs OCR)
        let pdf = try url("report.pdf")
        try DocumentEngine.printToPDF(text, output: pdf); add(pdf)
        let scan = try url("scan.pdf")
        let scanned = PDFDocument()
        scanned.insert(PDFPage(image: NSImage(cgImage: drawnImage(), size: NSSize(width: 1200, height: 800)))!, at: 0)
        XCTAssertTrue(scanned.write(to: scan)); add(scan)

        // E-book, spreadsheets, subtitles
        let epub = try url("book.epub")
        try await EPUB.write(StructuredText(markdown: "# Chapter one\n\n\(Self.marker) in an EPUB.\n"), title: "Book", to: epub); add(epub)
        let csv = try url("table.csv")
        try "Name,Count\n\(Self.marker),3\nPears,10\n".write(to: csv, atomically: true, encoding: .utf8); add(csv)
        let workbook = try await Spreadsheet.read(csv)
        let xlsx = try url("table.xlsx"); try await Spreadsheet.write(workbook, to: xlsx, ext: "xlsx"); add(xlsx)
        let ods = try url("sheet.ods"); try await Spreadsheet.write(workbook, to: ods, ext: "ods"); add(ods)
        let tsv = try url("sheet.tsv"); try await Spreadsheet.write(workbook, to: tsv, ext: "tsv"); add(tsv)
        let srt = try url("captions.srt")
        try "1\n00:00:01,000 --> 00:00:02,500\n\(Self.marker)\n".write(to: srt, atomically: true, encoding: .utf8); add(srt)

        // Archives and a folder
        let folder = try url("folder", in: "sources")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.marker.write(to: folder.appendingPathComponent("inside.txt"), atomically: true, encoding: .utf8)
        add(folder)
        let zip = try await ArchiveEngine.pack([folder], as: "zip")
        let moved = try url("bundle.zip"); try FileManager.default.moveItem(at: zip, to: moved); add(moved)

        // Slides (our own PPTX; converting it needs Keynote or LibreOffice)
        let pptx = try await DocumentEngine.convertPDF(pdf, to: "pptx")[0]
        let slides = try url("deck.pptx"); try FileManager.default.moveItem(at: pptx, to: slides); add(slides)

        // Media
        if let ffmpeg = FFmpeg.path {
            for (name, args) in [
                ("clip.mp4", ["-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30:duration=4", "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
                              "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest"]),
                ("clip.mkv", ["-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30:duration=4", "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
                              "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "libopus", "-shortest"]),
                ("tone.wav", ["-f", "lavfi", "-i", "sine=frequency=440:duration=4"]),
                ("tone.mp3", ["-f", "lavfi", "-i", "sine=frequency=440:duration=4"]),
                ("tone.ogg", ["-f", "lavfi", "-i", "sine=frequency=440:duration=4", "-c:a", "libvorbis"]),
            ] {
                let target = try url(name)
                try await Shell.run(ffmpeg, ["-y", "-loglevel", "error"] + args + [target.path])
                add(target)
            }
        }
        return files
    }

    // MARK: Checks

    /// True when an image has real content (not one flat colour).
    private func hasContent(_ image: CGImage) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        var low: CGFloat = 1, high: CGFloat = 0
        let step = max(1, min(rep.pixelsWide, rep.pixelsHigh) / 60)
        for x in stride(from: 0, to: rep.pixelsWide, by: step) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let luminance = 0.3 * color.redComponent + 0.59 * color.greenComponent + 0.11 * color.blueComponent
                low = min(low, luminance)
                high = max(high, luminance)
            }
        }
        return high - low > 0.25
    }

    private func save(preview image: CGImage, for output: URL, label: String) {
        guard let previews else { return }
        let longest = max(image.width, image.height)
        let small = longest > 700 ? ((try? ImageEngine.resized(image, scale: 700 / CGFloat(longest))) ?? image) : image
        let name = label.replacingOccurrences(of: "/", with: "-") + ".png"
        try? ImageEngine.write(small, to: previews.appendingPathComponent(name), ext: "png", quality: 1, metadata: nil)
    }

    /// Checks one output file; returns nil when it's good, or what's wrong.
    private func check(_ output: URL, from source: URL, label: String) async -> String? {
        let ext = Catalog.normalize(output)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: output.path, isDirectory: &isFolder) else { return "no output file" }

        if isFolder.boolValue && FileKind.of(output) == .folder && !["zip", "tar", "gz"].contains(Catalog.normalize(source)) {
            let items = (try? FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)) ?? []
            guard !items.isEmpty else { return "empty folder" }
            for item in items.sorted(by: { $0.path < $1.path }).prefix(2) {
                if let problem = await check(item, from: source, label: "\(label)-\(item.deletingPathExtension().lastPathComponent)") {
                    return "\(item.lastPathComponent): \(problem)"
                }
            }
            return nil
        }
        if isFolder.boolValue {   // extracted archive
            let found = FileManager.default.enumerator(atPath: output.path)?.allObjects.compactMap { $0 as? String } ?? []
            return found.contains { $0.hasSuffix("inside.txt") } ? nil : "archive didn't contain inside.txt (\(found))"
        }

        let sourceKind = FileKind.of(source)
        switch FileKind.of(output) {
        case .image:
            guard let imageSource = CGImageSourceCreateWithURL(output as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { return "unreadable image" }
            save(preview: image, for: output, label: label)
            if ext == "gif", sourceKind == .video, CGImageSourceGetCount(imageSource) < 2 { return "GIF has only one frame" }
            return hasContent(image) ? nil : "image is blank"

        case .pdf:
            guard let document = PDFDocument(url: output), let page = document.page(at: 0) else { return "unreadable PDF" }
            guard let image = PDFText.render(page, dpi: 72) else { return "PDF page didn't render" }
            save(preview: image, for: output, label: label)
            guard hasContent(image) else { return "PDF page is blank (nothing visible)" }
            if [.document, .pdf, .epub, .spreadsheet].contains(sourceKind), source.lastPathComponent != "scan.pdf" {
                let text = document.string ?? ""
                if !text.contains("marker 42") && !text.contains("Report title") && !text.contains("Chapter one") { return "PDF lost the text" }
            }
            return nil

        case .video, .audio:
            let info = await Media.probe(output)
            let expected = await Media.probe(source).duration
            if abs(info.duration - expected) > 0.6 { return String(format: "duration %.2fs, expected %.2fs", info.duration, expected) }
            if FileKind.of(output) == .video && !info.hasVideo { return "no video stream" }
            if ext == "mp3" || FileKind.of(output) == .audio { if !info.hasAudio { return "no audio stream" } }
            if FileKind.of(output) == .video, let frame = await Media.frame(output, at: 1) {
                save(preview: frame, for: output, label: label)
                if !hasContent(frame) { return "video frame is blank" }
            }
            return nil

        case .spreadsheet:
            guard let workbook = try? await Spreadsheet.read(output) else { return "unreadable spreadsheet" }
            let cells = workbook.sheets.flatMap { $0.rows.flatMap { $0 } }
            return cells.contains { $0.contains("marker 42") || $0.contains("Report title") } ? nil : "marker cell missing"

        case .slides:
            guard let folder = try? await ZipPackage.extract(output) else { return "not a valid PPTX package" }
            defer { try? FileManager.default.removeItem(at: folder) }
            let slide = folder.appendingPathComponent("ppt/slides/slide1.xml")
            return FileManager.default.fileExists(atPath: slide.path) ? nil : "PPTX has no slides"

        case .archive:
            guard let folder = try? await ArchiveEngine.extract(output) else { return "can't extract" }
            let found = FileManager.default.enumerator(atPath: folder.path)?.allObjects.compactMap { $0 as? String } ?? []
            // A zipped folder or archive holds inside.txt; a zipped file holds itself.
            let expected = [.folder, .archive].contains(sourceKind) ? "inside.txt" : source.lastPathComponent
            return found.contains { $0.hasSuffix(expected) } ? nil : "archive is missing \(expected) (\(found))"

        default:
            let text: String
            switch ext {
            case "epub": text = (try? await EPUB.read(output).string) ?? ""
            case "docx", "rtf", "odt", "html", "doc": text = (try? NSAttributedString(url: output, options: [:], documentAttributes: nil).string) ?? ""
            default: text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
            }
            if source.lastPathComponent == "scan.pdf" { return text.lowercased().contains("marker") ? nil : "OCR didn't find the text: \(text.prefix(80))" }
            return text.contains("marker 42") || text.contains("Report title") || text.contains("Chapter one") ? nil
                : "text missing: \(text.prefix(80))"
        }
    }

    /// iWork targets need the app; on machines without it the error must say so clearly.
    private func isMissingApp(_ error: Error) -> Bool {
        let message = error.localizedDescription
        return ["Pages is needed", "Keynote is needed", "Numbers is needed", "LibreOffice is needed", "free on the Mac App Store"].contains { message.contains($0) }
    }

    private func run(_ action: Action, on urls: [URL], label: String) async {
        do {
            let outputs = try await Engine.perform(action, on: urls)
            guard !outputs.isEmpty else { failures.append("\(label): no outputs"); return }
            for output in outputs {
                if let problem = await check(output, from: urls[0], label: label) {
                    failures.append("\(label): \(problem)")
                    report.append("| \(label) | ✗ \(problem) |")
                } else {
                    report.append("| \(label) | ✓ |")
                }
            }
        } catch let error where error.localizedDescription.hasPrefix("Already as small") {
            // Compress keeps nothing when the result would be bigger; that's the right outcome.
            report.append("| \(label) | – \(error.localizedDescription) |")
        } catch let error where isMissingApp(error) {
            report.append("| \(label) | – needs Pages/Keynote/Numbers (not on this machine): \(error.localizedDescription) |")
        } catch {
            failures.append("\(label): \(error.localizedDescription)")
            report.append("| \(label) | ✗ error: \(error.localizedDescription) |")
        }
    }

    // MARK: The matrix

    func testEveryWheelActionProducesCorrectContent() async throws {
        let fixtures = try await makeFixtures()

        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            for source in fixtures {
                // Dark mode only matters where AppKit draws: documents, PDFs, spreadsheets, e-books.
                if theme == "dark", ![.document, .pdf, .spreadsheet, .epub].contains(FileKind.of(source)) { continue }
                for action in Catalog.actions(for: [source], mode: .convert) {
                    await run(action, on: [source], label: "\(theme)/\(source.lastPathComponent)→\(action.title)")
                }
                for action in Catalog.actions(for: [source], mode: .tools) {
                    guard case .tool(let tool) = action.kind, !tool.needsEditor(for: FileKind.of(source)) else { continue }
                    if theme == "dark" { continue }
                    await run(action, on: [source], label: "\(theme)/\(source.lastPathComponent)→\(action.title)")
                }
            }
        }
        NSApp.appearance = nil

        // Batch tools on selections
        let images = fixtures.filter { FileKind.of($0) == .image && $0.pathExtension != "svg" }
        let pdfs = fixtures.filter { FileKind.of($0) == .pdf }
        await run(Action.tool(.createPDF, "Create PDF", ""), on: images, label: "selection/images→Create PDF")
        await run(Action.tool(.merge, "Merge", ""), on: pdfs, label: "selection/pdfs→Merge")
        await run(Action.tool(.zip, "ZIP", ""), on: [fixtures.first { $0.lastPathComponent == "folder" }!], label: "selection/folder→ZIP")

        let summary = "\(report.filter { $0.contains("✓") }.count) passed, \(failures.count) failed, "
            + "\(report.filter { $0.contains("| –") }.count) need iWork apps"
        let markdown = "# Conversion matrix\n\n\(summary)\n\n| Conversion | Result |\n|---|---|\n" + report.joined(separator: "\n") + "\n"
        try markdown.write(to: root.appendingPathComponent("matrix.md"), atomically: true, encoding: .utf8)
        if let previews { try markdown.write(to: previews.appendingPathComponent("matrix.md"), atomically: true, encoding: .utf8) }
        print(summary)
        XCTAssertTrue(failures.isEmpty, "\(failures.count) conversions failed:\n" + failures.joined(separator: "\n"))
    }
}
