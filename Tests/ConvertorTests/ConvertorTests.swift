import AppKit
import PDFKit
import XCTest
@testable import Convertor

/// End-to-end checks of the conversion engines on real files. Outputs are left in
/// `$CONVERTOR_TEST_OUT` (or a temp folder) so CI can validate them with other tools.
final class ConvertorTests: XCTestCase {
    static let workDir: URL = {
        let base = ProcessInfo.processInfo.environment["CONVERTOR_TEST_OUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("ConvertorTests")
        try? FileManager.default.removeItem(at: base)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private func file(_ name: String) -> URL { Self.workDir.appendingPathComponent(name) }

    private func exists(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path) && (size > 0 || url.hasDirectoryPath),
                      "missing or empty: \(url.lastPathComponent)", file: file, line: line)
    }

    // MARK: Fixtures

    private func makePNG(_ name: String, width: Int = 640, height: Int = 480, alpha: Bool = false) throws -> URL {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if !alpha {
            ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.4, blue: 0, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        let url = file(name)
        try ImageEngine.write(ctx.makeImage()!, to: url, ext: "png", quality: 1, metadata: nil)
        return url
    }

    @MainActor
    private func makePDF(_ name: String) throws -> URL {
        let text = StructuredText(markdown: """
        # Quarterly report

        This is the **first** paragraph of a test document. It is long enough to wrap onto a second line \
        when laid out on a US Letter page, which exercises the reflow logic.

        ## Numbers

        Item    Count    Price
        Apples    3    1.50
        Pears    10    0.75
        """)
        let url = file(name)
        try DocumentEngine.printToPDF(text.attributedString, output: url)
        return url
    }

    private func requireFFmpeg() throws -> String {
        guard let path = FFmpeg.path else { throw XCTSkip("ffmpeg not available") }
        return path
    }

    private func makeVideo(_ name: String, seconds: Int = 3) async throws -> URL {
        let ffmpeg = try requireFFmpeg()
        let url = file(name)
        try await Shell.run(ffmpeg, ["-y", "-loglevel", "error",
                                     "-f", "lavfi", "-i", "testsrc=size=320x240:rate=30:duration=\(seconds)",
                                     "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)",
                                     "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", url.path])
        return url
    }

    private func makeAudio(_ name: String) async throws -> URL {
        let ffmpeg = try requireFFmpeg()
        let url = file(name)
        try await Shell.run(ffmpeg, ["-y", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=4", url.path])
        return url
    }

    // MARK: Catalog & wheel

    func testCatalogMatchesTangerineWheels() {
        let png = URL(fileURLWithPath: "/tmp/a.png")
        let convert = Catalog.actions(for: [png], mode: .convert).map(\.title)
        XCTAssertFalse(convert.contains("PNG"))
        XCTAssertTrue(convert.contains("WEBP") && convert.contains("AVIF") && convert.contains("PDF"))
        XCTAssertEqual(Catalog.actions(for: [png], mode: .tools).map(\.title),
                       ["Compress", "Metadata", "Edit", "Annotate", "Add BG", "Crop", "Redact"])
        XCTAssertEqual(Catalog.actions(for: [URL(fileURLWithPath: "/tmp/a.mov")], mode: .tools).count, 9)
        XCTAssertEqual(Catalog.actions(for: [URL(fileURLWithPath: "/tmp/a.mp3")], mode: .tools).map(\.title),
                       ["Compress", "Metadata", "Normalize", "Visualize", "Trim", "Channels", "Bleep"])
        XCTAssertEqual(Catalog.actions(for: [URL(fileURLWithPath: "/tmp/a.pdf")], mode: .convert).count, 9)
        XCTAssertEqual(Catalog.actions(for: [png], mode: .actions).count, 6)
        XCTAssertEqual(FileKind.of(URL(fileURLWithPath: "/tmp/a.key")), .slides)
        XCTAssertEqual(FileKind.of(URL(fileURLWithPath: "/tmp/a.ods")), .spreadsheet)
        XCTAssertEqual(FileKind.of(URL(fileURLWithPath: "/tmp/a.epub")), .epub)
    }

    func testWheelHitTesting() {
        let c = WheelGeometry.center
        let r = (WheelGeometry.inner + WheelGeometry.outer) / 2
        XCTAssertEqual(WheelGeometry.segment(at: CGPoint(x: c.x, y: c.y - r), count: 4), 0)       // top
        XCTAssertEqual(WheelGeometry.segment(at: CGPoint(x: c.x + r, y: c.y), count: 4), 1)       // right
        XCTAssertEqual(WheelGeometry.segment(at: CGPoint(x: c.x, y: c.y + r), count: 4), 2)       // bottom
        XCTAssertEqual(WheelGeometry.segment(at: CGPoint(x: c.x - r, y: c.y), count: 4), 3)       // left
        XCTAssertNil(WheelGeometry.segment(at: c, count: 4))                                      // hub cancels
    }

    // MARK: Images

    func testImageConversions() async throws {
        let png = try makePNG("photo.png")
        for ext in ["jpg", "heic", "tiff", "bmp", "gif", "pdf"] {
            exists(try await ImageEngine.convert(png, to: ext))
        }
        if FFmpeg.isAvailable {
            exists(try await ImageEngine.convert(png, to: "webp"))
            exists(try await ImageEngine.convert(png, to: "avif"))
        }
        exists(try ImageEngine.compress(try makePNG("transparent.png", alpha: true)))
    }

    func testImageEdits() async throws {
        let png = try makePNG("edit.png")
        let cropped = try await EditJobs.cropImage(png, rect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), size: nil)[0]
        let (image, _) = try ImageEngine.load(cropped)
        XCTAssertEqual(image.width, 320)
        XCTAssertEqual(image.height, 240)

        let annotations = [
            ImageEdits.Annotation(kind: .arrow, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.5, y: 0.5)], color: .tangerine, width: 0.01),
            ImageEdits.Annotation(kind: .text, points: [CGPoint(x: 0.2, y: 0.8)], color: .tangerine, width: 0.01, text: "Hello"),
            ImageEdits.Annotation(kind: .callout, points: [CGPoint(x: 0.7, y: 0.3)], color: .tangerine, width: 0.01, number: 1),
        ]
        exists(try await EditJobs.annotate(png, annotations)[0])
        for style in MediaEdits.RedactStyle.allCases {
            exists(try await EditJobs.redact(png, areas: [CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.2)], style: style)[0])
        }
        exists(try await EditJobs.addBackground(png, ImageEdits.Background())[0])
        var adjustments = ImageEdits.Adjustments()
        adjustments.exposure = 0.5
        adjustments.effect = .noir
        adjustments.quarterTurns = 1
        let edited = try await EditJobs.editPhoto(png, adjustments)[0]
        XCTAssertEqual(try ImageEngine.load(edited).0.width, 480, "a quarter turn swaps width and height")

        let second = try makePNG("edit2.png", width: 400, height: 600)
        for layout in ImageEdits.Layout.allCases {
            exists(try await EditJobs.collage([png, second], layout: layout, spacing: 0.01, cornerRadius: 0.02, background: .tangerine)[0])
        }
        let jpg = try await ImageEngine.convert(png, to: "jpg")
        for source in [png, jpg] {
            var metadata = ImageEdits.readMetadata(source)
            metadata.author = "Convertor Tests"
            metadata.title = "Sunset"
            let tagged = try await EditJobs.imageMetadata(source, metadata, removeLocation: true)[0]
            XCTAssertEqual(ImageEdits.readMetadata(tagged).author, "Convertor Tests", source.pathExtension)
            XCTAssertEqual(ImageEdits.readMetadata(tagged).title, "Sunset", source.pathExtension)
        }
    }

    // MARK: Spreadsheets

    func testSpreadsheetRoundTrips() async throws {
        let csv = file("table.csv")
        try "Name,Count,Note\nApples,3,\"red, crisp\"\nPears,10,\"says \"\"hi\"\"\"\nZip,007,\n".write(to: csv, atomically: true, encoding: .utf8)
        let original = try await Spreadsheet.read(csv)
        XCTAssertEqual(original.sheets[0].rows[1], ["Apples", "3", "red, crisp"])

        for ext in ["xlsx", "ods", "tsv"] {
            let out = Output.file(for: csv, ext: ext)
            try await Spreadsheet.write(original, to: out, ext: ext)
            let back = try await Spreadsheet.read(out)
            XCTAssertEqual(back.sheets[0].rows[0], ["Name", "Count", "Note"], ext)
            XCTAssertEqual(back.sheets[0].rows[2][2], ext == "tsv" ? "says \"hi\"" : "says \"hi\"", ext)
            XCTAssertEqual(back.sheets[0].rows[3][1], "007", "leading zeros stay text in \(ext)")
            XCTAssertEqual(back.sheets[0].rows[2][1], "10", ext)
        }
        let pdf = Output.file(for: csv, ext: "pdf")
        try await Spreadsheet.write(original, to: pdf, ext: "pdf")
        exists(pdf)
    }

    // MARK: Documents

    @MainActor
    func testDocumentConversions() async throws {
        let md = file("notes.md")
        try "# Title\n\nSome **bold** and *italic* text.\n\n- one\n- two\n".write(to: md, atomically: true, encoding: .utf8)
        for ext in ["docx", "txt", "html", "epub", "pdf", "png"] {
            for output in try await DocumentEngine.convert(md, to: ext) { exists(output) }
        }
        let docx = file("notes.docx")
        let back = try await DocumentEngine.convert(docx, to: "md")[0]
        let markdown = try String(contentsOf: back, encoding: .utf8)
        XCTAssertTrue(markdown.contains("**bold**"), markdown)

        let epub = file("notes.epub")
        let text = try await EPUB.read(epub)
        XCTAssertTrue(text.string.contains("Some bold and italic text."), text.string)
    }

    @MainActor
    func testPDFConversions() async throws {
        let pdf = try makePDF("report.pdf")
        for ext in ["docx", "txt", "md", "epub", "xlsx", "pptx", "png", "jpg"] {
            for output in try await DocumentEngine.convertPDF(pdf, to: ext) { exists(output) }
        }
        let markdown = try String(contentsOf: file("report.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("# Quarterly report"), markdown)
        XCTAssertTrue(markdown.contains("paragraph of a test document. It is long enough to wrap onto a second line when laid out"),
                      "lines are re-flowed: \(markdown)")

        let workbook = try await Spreadsheet.read(file("report.xlsx"))
        XCTAssertTrue(workbook.sheets[0].rows.joined().contains { $0.contains("Apples") }, "\(workbook.sheets[0].rows)")

        exists(try DocumentEngine.compressPDF(pdf))
        exists(try DocumentEngine.splitPDF(pdf))
        let merged = try DocumentEngine.merge([pdf, pdf])
        XCTAssertEqual(PDFDocument(url: merged)?.pageCount, 2 * (PDFDocument(url: pdf)?.pageCount ?? 0))
        let organized = try await EditJobs.organizePDF(pdf, pages: [(0, 90), (0, 0)])[0]
        XCTAssertEqual(PDFDocument(url: organized)?.pageCount, 2)
        XCTAssertEqual(PDFDocument(url: organized)?.page(at: 0)?.rotation, 90)
        let tagged = try EditJobs.pdfMetadata(pdf, fields: ["Title": "Report", "Author": "Tests"], removeAll: false)
        XCTAssertEqual(PDFDocument(url: tagged)?.documentAttributes?[PDFDocumentAttribute.titleAttribute.rawValue] as? String, "Report")
    }

    func testOCRReadsRenderedText() throws {
        let width = 1200, height = 300
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSAttributedString(string: "Scanned invoice 2026", attributes: [.font: NSFont.systemFont(ofSize: 72)])
            .draw(at: CGPoint(x: 40, y: 100))
        NSGraphicsContext.restoreGraphicsState()
        let text = PDFText.ocr(ctx.makeImage()!).joined(separator: " ")
        XCTAssertTrue(text.contains("invoice"), text)
    }

    // MARK: Subtitles & archives

    func testSubtitlesRoundTrip() throws {
        let srt = file("captions.srt")
        try "1\n00:00:01,000 --> 00:00:02,500\nHello\n\n2\n00:00:03,000 --> 00:00:04,000\nWorld\n".write(to: srt, atomically: true, encoding: .utf8)
        let vtt = try TextEngine.convertSubtitles(srt, to: "vtt")
        let content = try String(contentsOf: vtt, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("WEBVTT"))
        XCTAssertTrue(content.contains("00:00:01.000 --> 00:00:02.500"))
        let back = try TextEngine.convertSubtitles(vtt, to: "srt")
        XCTAssertTrue(try String(contentsOf: back, encoding: .utf8).contains("2\n00:00:03,000 --> 00:00:04,000\nWorld"))
    }

    func testArchives() async throws {
        let png = try makePNG("archived.png")
        for ext in ["zip", "tar", "tar.gz"] {
            let archive = try await ArchiveEngine.pack([png], as: ext)
            let folder = try await ArchiveEngine.extract(archive)
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("archived.png").path), ext)
        }
    }

    // MARK: Audio & video (needs ffmpeg)

    func testMediaConversions() async throws {
        let video = try await makeVideo("clip.mp4")
        for ext in ["mov", "mkv", "webm", "gif", "mp3"] {
            exists(try await MediaEngine.convert(video, to: ext))
        }
        let audio = try await makeAudio("tone.wav")
        for ext in ["mp3", "m4a", "flac", "ogg", "opus", "aiff"] {
            exists(try await MediaEngine.convert(audio, to: ext))
        }
        exists(try await MediaEngine.compress(video))
        exists(try await MediaEngine.mute(video))
        exists(try await MediaEngine.normalize(audio))
    }

    func testMediaEdits() async throws {
        let video = try await makeVideo("edit.mp4", seconds: 4)
        let audio = try await makeAudio("speech.wav")

        let trimmed = try await MediaEdits.trim(video, start: 1, end: 3, removeSilence: false)
        let trimmedDuration = await Media.probe(trimmed).duration
        XCTAssertEqual(trimmedDuration, 2, accuracy: 0.3)
        let trimmedAudio = try await MediaEdits.trim(audio, start: 0.5, end: 2.5, removeSilence: true)
        let trimmedAudioDuration = await Media.probe(trimmedAudio).duration
        XCTAssertEqual(trimmedAudioDuration, 2, accuracy: 0.3)

        let fast = try await MediaEdits.speed(video, factor: 2, hasAudio: true)
        let fastDuration = await Media.probe(fast).duration
        XCTAssertEqual(fastDuration, 2, accuracy: 0.3)

        let clips = try await MediaEdits.split(video, at: [1.5], duration: 4)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: clips.path).count, 2)

        let joined = try await MediaEdits.join([video, video])
        let joinedDuration = await Media.probe(joined).duration
        XCTAssertEqual(joinedDuration, 8, accuracy: 0.5)

        let cropped = try await MediaEdits.crop(video, rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), width: 320, height: 240)
        let info = await Media.probe(cropped)
        XCTAssertEqual(info.width, 160)
        XCTAssertEqual(info.height, 120)

        for style in MediaEdits.RedactStyle.allCases {
            exists(try await MediaEdits.redact(video, rects: [CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)], style: style,
                                               range: style == .solid ? 1...2 : nil, width: 320, height: 240))
        }

        exists(try await MediaEdits.bleep(audio, ranges: [1...1.5, 2...2.5], sound: .beep, duration: 4))
        exists(try await MediaEdits.bleep(audio, ranges: [1...1.5], sound: .silence, duration: 4))
        exists(try await MediaEdits.channels(audio, mono: false))
        let visual = try await MediaEdits.visualize(audio, canvas: .square, style: .waveform, color: "FF4F00", image: nil)
        let visualHasVideo = await Media.probe(visual).hasVideo
        XCTAssertTrue(visualHasVideo)
        exists(try await MediaEdits.visualize(audio, canvas: .portrait, style: .bars, color: "FF4F00", image: nil))
        exists(try await MediaEdits.visualize(audio, canvas: .landscape, style: .image, color: "FF4F00", image: try makePNG("cover.png")))

        let folder = try Output.folder(for: video, suffix: " frames")
        exists(try await MediaEdits.snapshot(video, at: 1.2, into: folder))

        let tagged = try await MediaEdits.writeMetadata(video, fields: ["title": "Holiday", "artist": "Me"], removeAll: false)
        let tags = await Media.metadata(tagged)
        XCTAssertEqual(tags["title"], "Holiday")
        let waveform = await Media.waveform(audio)
        XCTAssertFalse(waveform.isEmpty)
    }
}
