import AppKit

/// EPUB 3 reading and writing.
enum EPUB {
    static func write(_ text: StructuredText, title: String, to output: URL) async throws {
        let chapters = text.chapters(defaultTitle: title)
        var files: [(path: String, data: Data)] = [
            ("mimetype", "application/epub+zip".utf8Data),
            ("META-INF/container.xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\
            <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
            """.utf8Data),
        ]

        var manifest = "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>"
        var spine = ""
        var toc = ""
        for (index, chapter) in chapters.enumerated() {
            let file = "chapter\(index + 1).xhtml"
            manifest += "<item id=\"c\(index + 1)\" href=\"\(file)\" media-type=\"application/xhtml+xml\"/>"
            spine += "<itemref idref=\"c\(index + 1)\"/>"
            toc += "<li><a href=\"\(file)\">\(chapter.title.xmlEscaped)</a></li>"
            files.append(("OEBPS/\(file)", page(title: chapter.title, body: chapter.text.xhtmlBody).utf8Data))
        }
        files.append(("OEBPS/nav.xhtml", page(title: title, body: "<nav epub:type=\"toc\" id=\"toc\"><h1>Contents</h1><ol>\(toc)</ol></nav>").utf8Data))

        let modified = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        files.append(("OEBPS/content.opf", """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">\
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\
        <dc:identifier id="uid">urn:uuid:\(UUID().uuidString.lowercased())</dc:identifier>\
        <dc:title>\(title.xmlEscaped)</dc:title><dc:language>en</dc:language>\
        <meta property="dcterms:modified">\(modified)</meta></metadata>\
        <manifest>\(manifest)</manifest><spine>\(spine)</spine></package>
        """.utf8Data))

        try await ZipPackage.write(files, to: output, storedFirst: "mimetype")
    }

    private static func page(title: String, body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><meta charset="UTF-8"/><title>\(title.xmlEscaped)</title>\
        <style>body{font-family:serif;line-height:1.5;margin:1em}h1,h2,h3{font-family:sans-serif}</style></head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    /// The book's spine documents, in reading order, as one attributed string.
    @MainActor
    static func read(_ url: URL) async throws -> NSAttributedString {
        let root = try await ZipPackage.extract(url)
        defer { try? FileManager.default.removeItem(at: root) }

        guard let container = try? XMLDocument(contentsOf: root.appendingPathComponent("META-INF/container.xml"), options: []),
              let opfPath = container.elements("rootfile").first?.attribute(forName: "full-path")?.stringValue,
              let opf = try? XMLDocument(contentsOf: root.appendingPathComponent(opfPath), options: [])
        else { throw ConvertError("\(url.lastPathComponent) isn't a valid EPUB") }

        let base = root.appendingPathComponent(opfPath).deletingLastPathComponent()
        var hrefs: [String: String] = [:]
        for item in opf.elements("item") {
            if let id = item.attribute(forName: "id")?.stringValue, let href = item.attribute(forName: "href")?.stringValue {
                hrefs[id] = href.removingPercentEncoding ?? href
            }
        }

        let result = NSMutableAttributedString()
        for itemref in opf.elements("itemref") {
            guard let id = itemref.attribute(forName: "idref")?.stringValue, let href = hrefs[id] else { continue }
            let file = base.appendingPathComponent(href)
            guard let data = try? Data(contentsOf: file),
                  let chapter = try? NSAttributedString(data: data, options: [
                      .documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue,
                      .baseURL: file,
                  ], documentAttributes: nil)
            else { continue }
            result.append(chapter)
            result.append(NSAttributedString(string: "\n"))
        }
        guard result.length > 0 else { throw ConvertError("No readable chapters in \(url.lastPathComponent)") }
        return result
    }
}
