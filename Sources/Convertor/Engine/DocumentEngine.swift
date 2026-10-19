import AppKit
import PDFKit
import Quartz

/// Text documents and PDFs, built on NSAttributedString and PDFKit.
/// Runs on the main actor because the HTML importer and the print system require it.
@MainActor
enum DocumentEngine {
    private static let richTypes: [String: NSAttributedString.DocumentType] = [
        "docx": .officeOpenXML, "rtf": .rtf, "html": .html, "odt": .openDocument, "doc": .docFormat,
    ]

    // MARK: Documents

    static func convert(_ url: URL, to ext: String) throws -> URL {
        let text = try read(url)
        let out = Output.file(for: url, ext: ext)
        try write(text, to: out, ext: ext)
        return out
    }

    private static func read(_ url: URL) throws -> NSAttributedString {
        if ["md", "markdown"].contains(url.pathExtension.lowercased()) {
            return markdown(try String(contentsOf: url, encoding: .utf8))
        }
        return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
    }

    private static func write(_ text: NSAttributedString, to out: URL, ext: String) throws {
        switch ext {
        case "txt", "md":
            try text.string.write(to: out, atomically: true, encoding: .utf8)
        case "pdf":
            try printToPDF(text, output: out)
        default:
            guard let type = richTypes[ext] else { throw ConvertError("Can't write \(ext.uppercased()) documents") }
            var attributes: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
            if type == .html { attributes[.characterEncoding] = String.Encoding.utf8.rawValue }
            let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attributes)
            try data.write(to: out)
        }
    }

    /// Small Markdown renderer: headings by line, inline styles via Foundation's parser.
    private static func markdown(_ source: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)

        for line in source.components(separatedBy: .newlines) {
            var content = Substring(line)
            var size: CGFloat = 13
            var heading = false
            if let level = line.firstIndex(where: { $0 != "#" }).map({ line.distance(from: line.startIndex, to: $0) }),
               (1...6).contains(level), line.dropFirst(level).first == " " {
                content = line.dropFirst(level + 1)
                size = ([26, 22, 18, 16, 14, 13] as [CGFloat])[level - 1]
                heading = true
            }

            let parsed = (try? AttributedString(markdown: String(content), options: options)) ?? AttributedString(String(content))
            for run in parsed.runs {
                let intent = run.inlinePresentationIntent ?? []
                var font = intent.contains(.code)
                    ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
                    : NSFont.systemFont(ofSize: size, weight: heading || intent.contains(.stronglyEmphasized) ? .bold : .regular)
                if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                var attributes: [NSAttributedString.Key: Any] = [.font: font]
                if let link = run.link { attributes[.link] = link }
                result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
            }
            result.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        }
        return result
    }

    private static func printToPDF(_ text: NSAttributedString, output: URL) throws {
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

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 612 - 108, height: 1))
        textView.textStorage?.setAttributedString(text)
        textView.isVerticallyResizable = true
        if let container = textView.textContainer { textView.layoutManager?.ensureLayout(for: container) }
        textView.sizeToFit()

        let operation = NSPrintOperation(view: textView, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else { throw ConvertError("Couldn't create the PDF") }
    }

    // MARK: PDF

    static func convertPDF(_ url: URL, to ext: String) throws -> [URL] {
        guard let document = PDFDocument(url: url) else { throw ConvertError("Can't open \(url.lastPathComponent)") }
        switch ext {
        case "jpg", "png":
            return try renderPages(document, source: url, ext: ext)
        case "txt", "md":
            let out = Output.file(for: url, ext: ext)
            try (document.string ?? "").write(to: out, atomically: true, encoding: .utf8)
            return [out]
        default:
            let text = NSMutableAttributedString()
            for index in 0..<document.pageCount {
                if let page = document.page(at: index)?.attributedString { text.append(page) }
                text.append(NSAttributedString(string: "\n\n"))
            }
            let out = Output.file(for: url, ext: ext)
            try write(text, to: out, ext: ext)
            return [out]
        }
    }

    /// Every page at 300 DPI; several pages land in their own folder.
    private static func renderPages(_ document: PDFDocument, source: URL, ext: String) throws -> [URL] {
        let count = document.pageCount
        let folder = count > 1 ? try Output.folder(for: source, suffix: " pages") : nil
        var outputs: [URL] = []
        for index in 0..<count {
            guard let page = document.page(at: index), let image = render(page, dpi: 300) else { continue }
            let out = folder.map { Output.unique($0, name: "Page \(index + 1)", ext: ext) } ?? Output.file(for: source, ext: ext)
            try ImageEngine.write(image, to: out, ext: ext, quality: 0.92, metadata: nil)
            outputs.append(out)
        }
        return folder.map { [$0] } ?? outputs
    }

    private static func render(_ page: PDFPage, dpi: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let scale = dpi / 72
        let width = Int((rotated ? bounds.height : bounds.width) * scale)
        let height = Int((rotated ? bounds.width : bounds.height) * scale)
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    static func applyPDF(_ tool: Tool, to url: URL) throws -> URL {
        guard let document = PDFDocument(url: url) else { throw ConvertError("Can't open \(url.lastPathComponent)") }
        switch tool {
        case .compressPDF:
            let out = Output.file(for: url, suffix: " compressed", ext: "pdf")
            var options: [PDFDocumentWriteOption: Any] = [:]
            if let filter = QuartzFilter(url: URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")) {
                options[PDFDocumentWriteOption(rawValue: "QuartzFilter")] = filter
            }
            guard document.write(to: out, withOptions: options) else { throw ConvertError("Couldn't write the PDF") }
            return out
        case .splitPDF:
            let folder = try Output.folder(for: url, suffix: " split")
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
                let single = PDFDocument()
                single.insert(page, at: 0)
                single.write(to: Output.unique(folder, name: "\(Output.baseName(url)) \(index + 1)", ext: "pdf"))
            }
            return folder
        case .rotatePDF:
            for index in 0..<document.pageCount {
                if let page = document.page(at: index) { page.rotation = (page.rotation + 90) % 360 }
            }
            let out = Output.file(for: url, suffix: " rotated", ext: "pdf")
            guard document.write(to: out) else { throw ConvertError("Couldn't write the PDF") }
            return out
        default:
            throw ConvertError("Not a PDF tool")
        }
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
