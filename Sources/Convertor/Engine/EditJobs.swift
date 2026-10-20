import AppKit
import CoreImage
import PDFKit

/// Save actions for the image and document editors. They're `async` and not tied to the main
/// actor, so the pixel work runs in the background while the editor window closes.
enum EditJobs {
    private static func writeImage(_ image: CGImage, like url: URL, suffix: String, metadata: [CFString: Any]?) throws -> URL {
        let ext = ImageEngine.writableExtension(for: url)
        let out = Output.file(for: url, suffix: suffix, ext: ext)
        try ImageEngine.write(image, to: out, ext: ext, quality: ImageEngine.quality, metadata: metadata)
        return out
    }

    static func cropImage(_ url: URL, rect: CGRect, size: CGSize?) async throws -> [URL] {
        let (image, props) = try ImageEngine.load(url)
        return [try writeImage(ImageEdits.crop(image, rect: rect, outputSize: size), like: url, suffix: " cropped", metadata: props)]
    }

    static func annotate(_ url: URL, _ annotations: [ImageEdits.Annotation]) async throws -> [URL] {
        let (image, props) = try ImageEngine.load(url)
        return [try writeImage(ImageEdits.annotate(image, with: annotations), like: url, suffix: " annotated", metadata: props)]
    }

    static func redact(_ url: URL, areas: [CGRect], style: MediaEdits.RedactStyle) async throws -> [URL] {
        let (image, _) = try ImageEngine.load(url)
        // Redacted copies drop metadata too: location tags would defeat the point.
        return [try writeImage(ImageEdits.redact(image, areas: areas, style: style), like: url, suffix: " redacted", metadata: nil)]
    }

    static func addBackground(_ url: URL, _ options: ImageEdits.Background) async throws -> [URL] {
        let (image, _) = try ImageEngine.load(url)
        let out = Output.file(for: url, suffix: " background", ext: "png")
        try ImageEngine.write(ImageEdits.addBackground(image, options), to: out, ext: "png", quality: 1, metadata: nil)
        return [out]
    }

    static func editPhoto(_ url: URL, _ adjustments: ImageEdits.Adjustments) async throws -> [URL] {
        let (image, props) = try ImageEngine.load(url)
        let edited = try ImageEdits.render(ImageEdits.adjust(CIImage(cgImage: image), adjustments))
        return [try writeImage(edited, like: url, suffix: " edited", metadata: props)]
    }

    static func collage(_ urls: [URL], layout: ImageEdits.Layout, spacing: CGFloat, cornerRadius: CGFloat, background: RGBA) async throws -> [URL] {
        let images = try urls.map { try ImageEngine.load($0).0 }
        let collage = try ImageEdits.collage(images, layout: layout, spacing: spacing, cornerRadius: cornerRadius, background: background)
        let out = Output.unique(Output.directory(for: urls[0]), name: "Collage", ext: "png")
        try ImageEngine.write(collage, to: out, ext: "png", quality: 1, metadata: nil)
        return [out]
    }

    static func imageMetadata(_ url: URL, _ metadata: ImageEdits.Metadata, removeLocation: Bool) async throws -> [URL] {
        [try ImageEdits.writeMetadata(url, metadata, removeLocation: removeLocation)]
    }

    /// Strips tags from any mix of images, audio, video and PDFs.
    static func removeMetadata(_ urls: [URL]) async throws -> [URL] {
        var outputs: [URL] = []
        for url in urls {
            switch FileKind.of(url) {
            case .image: outputs.append(try ImageEdits.stripMetadata(url))
            case .pdf: outputs.append(try await pdfMetadata(url, fields: [:], removeAll: true))
            default: outputs.append(try await MediaEdits.writeMetadata(url, fields: [:], removeAll: true))
            }
        }
        return outputs
    }

    static let pdfKeys: [(label: String, key: PDFDocumentAttribute)] = [
        ("Title", .titleAttribute), ("Author", .authorAttribute), ("Subject", .subjectAttribute), ("Keywords", .keywordsAttribute),
    ]

    /// Async so it runs off the main actor even when an editor calls it: big PDFs take a while.
    static func pdfMetadata(_ url: URL, fields: [String: String], removeAll: Bool) async throws -> URL {
        guard let document = PDFDocument(url: url) else { throw ConvertError("Can't open \(url.lastPathComponent)") }
        var attributes: [AnyHashable: Any] = removeAll ? [:] : (document.documentAttributes ?? [:])
        if !removeAll {
            for (label, key) in pdfKeys {
                let value = fields[label] ?? ""
                if key == .keywordsAttribute {
                    attributes[key.rawValue] = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                } else {
                    attributes[key.rawValue] = value
                }
            }
        }
        document.documentAttributes = attributes
        let out = Output.file(for: url, suffix: removeAll ? " clean" : " edited", ext: "pdf")
        guard document.write(to: out) else { throw ConvertError("Couldn't write the PDF") }
        return out
    }

    /// Writes pages in the given order, each with its own extra rotation.
    static func organizePDF(_ url: URL, pages: [(index: Int, rotation: Int)]) async throws -> [URL] {
        guard let source = PDFDocument(url: url) else { throw ConvertError("Can't open \(url.lastPathComponent)") }
        guard !pages.isEmpty else { throw ConvertError("Keep at least one page") }
        let result = PDFDocument()
        for item in pages {
            guard let page = source.page(at: item.index)?.copy() as? PDFPage else { continue }
            page.rotation = ((page.rotation + item.rotation) % 360 + 360) % 360
            result.insert(page, at: result.pageCount)
        }
        let out = Output.file(for: url, suffix: " organized", ext: "pdf")
        guard result.write(to: out) else { throw ConvertError("Couldn't write the PDF") }
        return [out]
    }
}
