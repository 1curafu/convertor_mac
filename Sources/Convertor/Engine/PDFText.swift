import AppKit
import PDFKit
import Vision

/// Getting usable text out of PDFs: selectable text where it exists, on-device OCR for
/// scanned pages, and re-flowing of the hard line breaks PDFs put at the end of every line.
enum PDFText {
    /// One attributed string per page.
    static func pages(_ document: PDFDocument) async -> [NSAttributedString] {
        var pages: [NSAttributedString] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let selectable = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if selectable.count >= 20, let text = page.attributedString {
                pages.append(reflow(text))
            } else if let image = render(page, dpi: 200) {
                let paragraphs = ocr(image)
                let body = paragraphs.isEmpty ? selectable : paragraphs.joined(separator: "\n")
                pages.append(NSAttributedString(string: body, attributes: [.font: DocumentFont.regular(12)]))
            }
        }
        return pages
    }

    /// All pages as one attributed string, separated by blank lines.
    static func text(_ document: PDFDocument) async -> NSAttributedString {
        let result = NSMutableAttributedString()
        for page in await pages(document) {
            result.append(page)
            result.append(NSAttributedString(string: "\n\n", attributes: [.font: DocumentFont.regular(12)]))
        }
        return result
    }

    /// Recognised paragraphs, top to bottom.
    static func ocr(_ image: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            return []
        }
        let lines = (request.results ?? [])
            .compactMap { observation -> (box: CGRect, text: String)? in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                return (observation.boundingBox, text)
            }
            .sorted { $0.box.midY > $1.box.midY }   // Vision's origin is bottom-left

        var paragraphs: [String] = []
        var current: [String] = []
        var previous: CGRect?
        for line in lines {
            if let previous, previous.minY - line.box.maxY > line.box.height * 0.8 {
                paragraphs.append(current.joined(separator: " "))
                current = []
            }
            current.append(line.text)
            previous = line.box
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
        return paragraphs
    }

    /// Joins lines that belong to the same paragraph and undoes end-of-line hyphenation.
    static func reflow(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        let lines = text.string.components(separatedBy: "\n")
        let longest = lines.map { $0.count }.max() ?? 0
        guard lines.count > 1, longest > 0 else { return result }

        // (utf16 offset of the newline, line before, line after)
        var breaks: [(offset: Int, before: String, after: String)] = []
        var offset = 0
        for index in 0..<(lines.count - 1) {
            offset += lines[index].utf16.count
            breaks.append((offset, lines[index], lines[index + 1]))
            offset += 1
        }

        // Edit from the end so earlier offsets stay valid.
        for item in breaks.reversed() {
            let before = item.before.trimmingCharacters(in: .whitespaces)
            let after = item.after.trimmingCharacters(in: .whitespaces)
            guard !before.isEmpty, !after.isEmpty else { continue }
            let startsList = after.hasPrefix("•") || after.hasPrefix("- ") || after.first?.isNumber == true && after.dropFirst().first == "."
            if startsList { continue }

            if before.hasSuffix("-"), after.first?.isLowercase == true, item.offset > 0 {
                result.replaceCharacters(in: NSRange(location: item.offset - 1, length: 2), with: "")
                continue
            }
            let endsSentence = before.last.map { ".!?:;".contains($0) } ?? false
            let continues = after.first?.isLowercase == true || (!endsSentence && item.before.count > longest * 6 / 10)
            if continues {
                result.replaceCharacters(in: NSRange(location: item.offset, length: 1), with: " ")
            }
        }
        return result
    }

    /// Draws a page onto white at the given resolution.
    static func render(_ page: PDFPage, dpi: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let scale = dpi / 72
        let width = Int((rotated ? bounds.height : bounds.width) * scale)
        let height = Int((rotated ? bounds.width : bounds.height) * scale)
        guard width > 0, height > 0, width * height < 400_000_000,
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
}
