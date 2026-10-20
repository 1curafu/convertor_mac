import AppKit
import PDFKit
import Quartz

/// Documents, e-books, slides and PDFs.
/// Native code (NSAttributedString, PDFKit, our own EPUB/PPTX/XLSX writers) handles what it can;
/// Pages and Keynote take over for their own formats and for layout-faithful Office rendering.
/// Only the rich-text import/export and printing run on the main actor (the HTML importer and the
/// print system require it); rendering, OCR and PDF work stay in the background.
enum DocumentEngine {
    private static let richTypes: [String: NSAttributedString.DocumentType] = [
        "docx": .officeOpenXML, "rtf": .rtf, "html": .html, "odt": .openDocument, "doc": .docFormat,
    ]
    /// Formats Pages can open directly.
    private static let pagesOpenable: Set<String> = ["docx", "doc", "rtf", "txt"]
    private static let pagesExports: [String: IWork.Format] = [
        "pdf": .pdf, "docx": .word, "epub": .epub, "txt": .plainText, "rtf": .richText,
    ]

    // MARK: Documents and EPUB

    static func convert(_ url: URL, to ext: String) async throws -> [URL] {
        let source = Catalog.normalize(url)

        // Pages documents: let Pages export whatever it can natively.
        if source == "pages", let format = pagesExports[ext] {
            let out = Output.file(for: url, ext: ext)
            try await IWork.export(url, with: .pages, as: format, to: out)
            return [out]
        }
        // Word → PDF keeps its real layout when Pages is available; otherwise fall through.
        if ext == "pdf", ["docx", "doc", "rtf"].contains(source), IWork.App.pages.isInstalled {
            let out = Output.file(for: url, ext: ext)
            if (try? await IWork.export(url, with: .pages, as: .pdf, to: out)) != nil { return [out] }
        }
        if ext == "pages", pagesOpenable.contains(source) {
            let out = Output.file(for: url, ext: ext)
            try await IWork.saveNative(url, with: .pages, to: out)
            return [out]
        }

        let text = try await readRich(url)
        return try await writeRich(text, ext: ext, source: url)
    }

    @MainActor
    static func readRich(_ url: URL) async throws -> NSAttributedString {
        switch Catalog.normalize(url) {
        case "pages":
            let temp = try Output.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: temp) }
            let docx = temp.appendingPathComponent("document.docx")
            try await IWork.export(url, with: .pages, as: .word, to: docx)
            return try NSAttributedString(url: docx, options: [:], documentAttributes: nil)
        case "epub":
            return try await EPUB.read(url)
        case "md":
            return StructuredText(markdown: try String(contentsOf: url, encoding: .utf8)).attributedString
        default:
            return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        }
    }

    /// Writes rich text as `ext` next to `source`. Images of several pages go into a folder.
    @MainActor
    static func writeRich(_ text: NSAttributedString, ext: String, source: URL) async throws -> [URL] {
        let out = Output.file(for: source, ext: ext)
        switch ext {
        case "txt":
            try text.string.write(to: out, atomically: true, encoding: .utf8)
        case "md":
            try StructuredText(text).markdown.write(to: out, atomically: true, encoding: .utf8)
        case "epub":
            try await EPUB.write(StructuredText(text), title: Output.baseName(source), to: out)
        case "pdf":
            try printToPDF(text, output: out)
        case "png", "jpg":
            let temp = try Output.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: temp) }
            let pdf = temp.appendingPathComponent("document.pdf")
            try printToPDF(text, output: pdf)
            guard let document = PDFDocument(url: pdf) else { throw ConvertError("Couldn't lay out the document") }
            return try renderPages(document, source: source, ext: ext, dpi: 200)
        case "pages":
            let temp = try Output.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: temp) }
            let docx = temp.appendingPathComponent("\(Output.baseName(source)).docx")
            try richData(text, ext: "docx").write(to: docx)
            try await IWork.saveNative(docx, with: .pages, to: out)
        default:
            try richData(text, ext: ext).write(to: out)
        }
        return [out]
    }

    @MainActor
    private static func richData(_ text: NSAttributedString, ext: String) throws -> Data {
        guard let type = richTypes[ext] else { throw ConvertError("Can't write \(ext.uppercased()) documents") }
        var attributes: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
        if type == .html { attributes[.characterEncoding] = String.Encoding.utf8.rawValue }
        return try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attributes)
    }

    /// Lays rich text out on US Letter pages.
    @MainActor
    static func printToPDF(_ text: NSAttributedString, output: URL) throws {
        let info = NSPrintInfo(dictionary: [.jobSavingURL: output])
        info.jobDisposition = .save
        info.paperSize = NSSize(width: 612, height: 792)
        info.topMargin = 54
        info.bottomMargin = 54
        info.leftMargin = 54
        info.rightMargin = 54
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false

        // Paper is white whatever the Mac's theme. Text with no colour of its own (most Word
        // documents) would otherwise take the dark-mode text colour, white, and vanish.
        let printable = NSMutableAttributedString(attributedString: text)
        // Trailing line breaks would print an empty last page.
        while let last = printable.string.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
            printable.deleteCharacters(in: NSRange(location: printable.length - 1, length: 1))
        }
        if printable.length == 0 { printable.append(NSAttributedString(string: " ")) }
        let whole = NSRange(location: 0, length: printable.length)
        printable.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
            if value == nil { printable.addAttribute(.foregroundColor, value: NSColor.black, range: range) }
        }
        let light = NSAppearance(named: .aqua)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 612 - 108, height: 1))
        textView.appearance = light
        textView.drawsBackground = false
        textView.textStorage?.setAttributedString(printable)
        textView.isVerticallyResizable = true
        if let container = textView.textContainer { textView.layoutManager?.ensureLayout(for: container) }
        textView.sizeToFit()

        let operation = NSPrintOperation(view: textView, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.jobTitle = Output.baseName(output)   // becomes the PDF's Title instead of "Untitled"
        var printed = false
        (light ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance { printed = operation.run() }
        guard printed, FileManager.default.fileExists(atPath: output.path) else {
            throw ConvertError("Couldn't create the PDF")
        }
        if let document = PDFDocument(url: output),
           document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String != operation.jobTitle {
            document.documentAttributes?[PDFDocumentAttribute.titleAttribute] = operation.jobTitle
            document.write(to: output)
        }
    }

    // MARK: Slides

    static func convertSlides(_ url: URL, to ext: String) async throws -> [URL] {
        let source = Catalog.normalize(url)
        if ext == "pptx" {
            let out = Output.file(for: url, ext: ext)
            try await IWork.export(url, with: .keynote, as: .powerPoint, to: out)
            return [out]
        }

        let temp = try Output.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let pdf = ext == "pdf" ? Output.file(for: url, ext: "pdf") : temp.appendingPathComponent("slides.pdf")
        if source != "odp", IWork.App.keynote.isInstalled {
            try await IWork.export(url, with: .keynote, as: .pdf, to: pdf)
        } else if LibreOffice.path != nil {
            try await LibreOffice.convert(url, to: "pdf", output: pdf)
        } else if source == "odp" {
            throw ConvertError("LibreOffice is needed to open ODP slides. It's free from libreoffice.org.")
        } else {
            throw ConvertError("Keynote is needed for slides. It's free on the Mac App Store.")
        }
        if ext == "pdf" { return [pdf] }

        guard let document = PDFDocument(url: pdf), let first = document.page(at: 0) else {
            throw ConvertError("Couldn't render the slides")
        }
        // Aim for 1920 px wide slide images.
        let width = max(first.bounds(for: .cropBox).width, 1)
        return try renderPages(document, source: url, ext: ext, dpi: 72 * 1920 / width)
    }

    // MARK: PDF

    static func convertPDF(_ url: URL, to ext: String) async throws -> [URL] {
        guard let document = PDFDocument(url: url) else { throw ConvertError("Can't open \(url.lastPathComponent)") }
        let out = Output.file(for: url, ext: ext)

        switch ext {
        case "jpg", "png":
            return try renderPages(document, source: url, ext: ext, dpi: 300)
        case "txt":
            try (await PDFText.text(document)).string.write(to: out, atomically: true, encoding: .utf8)
        case "md":
            try StructuredText(await PDFText.text(document)).markdown.write(to: out, atomically: true, encoding: .utf8)
        case "epub":
            try await EPUB.write(StructuredText(await PDFText.text(document)), title: Output.baseName(url), to: out)
        case "docx", "pages", "rtf":
            return try await writeRich(PDFText.text(document), ext: ext, source: url)
        case "xlsx":
            // One sheet per page; columns split where the text has tabs or wide gaps.
            var sheets: [Workbook.Sheet] = []
            for (index, page) in (await PDFText.pages(document)).enumerated() {
                let rows = page.string.components(separatedBy: "\n")
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    .map { line in
                        line.components(separatedBy: "\t").flatMap {
                            $0.replacingOccurrences(of: #" {2,}"#, with: "\t", options: .regularExpression)
                                .components(separatedBy: "\t")
                        }.map { $0.trimmingCharacters(in: .whitespaces) }
                    }
                sheets.append(.init(name: "Page \(index + 1)", rows: rows))
            }
            try await Spreadsheet.write(Workbook(sheets: sheets), to: out, ext: "xlsx")
        case "pptx":
            var slides: [(jpeg: Data, width: Int, height: Int)] = []
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index), let image = PDFText.render(page, dpi: 150),
                      let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.88])
                else { continue }
                slides.append((jpeg, image.width, image.height))
            }
            try await PPTX.write(slides: slides, to: out)
        default:
            throw ConvertError("Can't convert PDF to \(ext.uppercased())")
        }
        return [out]
    }

    /// Every page as an image; several pages land in their own folder.
    static func renderPages(_ document: PDFDocument, source: URL, ext: String, dpi: CGFloat) throws -> [URL] {
        let count = document.pageCount
        let folder = count > 1 ? try Output.folder(for: source, suffix: " pages") : nil
        var outputs: [URL] = []
        for index in 0..<count {
            guard let page = document.page(at: index), let image = PDFText.render(page, dpi: dpi) else { continue }
            let out = folder.map { Output.unique($0, name: "Page \(index + 1)", ext: ext) } ?? Output.file(for: source, ext: ext)
            try ImageEngine.write(image, to: out, ext: ext, quality: 0.92, metadata: nil)
            outputs.append(out)
        }
        return folder.map { [$0] } ?? outputs
    }

    static func compressPDF(_ url: URL) throws -> URL {
        guard let document = PDFDocument(url: url) else { throw ConvertError("Can't open \(url.lastPathComponent)") }
        let out = Output.file(for: url, suffix: " compressed", ext: "pdf")
        var options: [PDFDocumentWriteOption: Any] = [:]
        let filterURL = URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")
        if FileManager.default.fileExists(atPath: filterURL.path), let filter = QuartzFilter(url: filterURL) {
            options[PDFDocumentWriteOption(rawValue: "QuartzFilter")] = filter
        } else {
            options[.saveImagesAsJPEGOption] = true
            options[.optimizeImagesForScreenOption] = true
        }
        guard document.write(to: out, withOptions: options) else { throw ConvertError("Couldn't write the PDF") }
        return out
    }

    /// Each page as its own PDF in a new folder.
    static func splitPDF(_ url: URL) throws -> URL {
        guard let document = PDFDocument(url: url) else { throw ConvertError("Can't open \(url.lastPathComponent)") }
        let folder = try Output.folder(for: url, suffix: " pages")
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            single.write(to: Output.unique(folder, name: "\(Output.baseName(url)) \(index + 1)", ext: "pdf"))
        }
        return folder
    }

    static func merge(_ urls: [URL]) throws -> URL {
        guard let first = urls.first else { throw ConvertError("Nothing to merge") }
        let merged = PDFDocument()
        for url in urls {
            guard let document = PDFDocument(url: url) else { throw ConvertError("Can't open \(url.lastPathComponent)") }
            for index in 0..<document.pageCount {
                if let page = document.page(at: index)?.copy() as? PDFPage { merged.insert(page, at: merged.pageCount) }
            }
        }
        let out = Output.file(for: first, suffix: " merged", ext: "pdf")
        guard merged.write(to: out) else { throw ConvertError("Couldn't write the PDF") }
        return out
    }
}
