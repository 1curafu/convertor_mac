import AppKit

/// Fonts for generated documents. The system UI font has a private name (".SFNS…") that
/// Word and Pages can't resolve, so documents use Helvetica Neue instead.
enum DocumentFont {
    static func regular(_ size: CGFloat) -> NSFont {
        NSFont(name: "Helvetica Neue", size: size) ?? NSFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size)
    }

    static func bold(_ size: CGFloat) -> NSFont {
        NSFontManager.shared.convert(regular(size), toHaveTrait: .boldFontMask)
    }
}

/// Headings and paragraphs with bold/italic runs: the common ground between rich text,
/// Markdown, EPUB chapters and text pulled out of PDFs.
struct StructuredText {
    struct Run {
        var text: String
        var bold = false
        var italic = false
    }

    enum Block {
        case heading(level: Int, runs: [Run])
        case paragraph([Run])

        var plainText: String {
            switch self {
            case .heading(_, let runs), .paragraph(let runs): return runs.map(\.text).joined()
            }
        }
    }

    var blocks: [Block]

    // MARK: From rich text

    /// Infers headings from font size relative to the body text (and short all-bold lines).
    init(_ text: NSAttributedString) {
        let string = text.string as NSString
        var sizes: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            let size = ((value as? NSFont)?.pointSize ?? 12).rounded()
            sizes[size, default: 0] += range.length
        }
        let body = sizes.max { $0.value < $1.value }?.key ?? 12

        var blocks: [Block] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byParagraphs) { _, range, _, _ in
            var runs: [Run] = []
            var largest: CGFloat = 0
            text.enumerateAttribute(.font, in: range) { value, runRange, _ in
                let font = value as? NSFont
                let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
                largest = max(largest, font?.pointSize ?? body)
                let piece = string.substring(with: runRange)
                if let last = runs.last, last.bold == traits.contains(.boldFontMask), last.italic == traits.contains(.italicFontMask) {
                    runs[runs.count - 1].text += piece
                } else {
                    runs.append(Run(text: piece, bold: traits.contains(.boldFontMask), italic: traits.contains(.italicFontMask)))
                }
            }
            let plain = runs.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            guard !plain.isEmpty else { return }

            let ratio = largest / body
            let allBold = runs.allSatisfy { $0.bold || $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            if ratio >= 1.6 {
                blocks.append(.heading(level: 1, runs: runs.map { Run(text: $0.text) }))
            } else if ratio >= 1.3 {
                blocks.append(.heading(level: 2, runs: runs.map { Run(text: $0.text) }))
            } else if ratio >= 1.12 || (allBold && plain.count < 80 && !plain.hasSuffix(".")) {
                blocks.append(.heading(level: 3, runs: runs.map { Run(text: $0.text) }))
            } else {
                blocks.append(.paragraph(runs))
            }
        }
        self.blocks = blocks
    }

    init(blocks: [Block]) { self.blocks = blocks }

    // MARK: From Markdown

    /// Headings, paragraphs and list items by line; inline styles via Foundation's parser.
    init(markdown source: String) {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var blocks: [Block] = []
        var paragraph: [String] = []

        func runs(_ line: String) -> [Run] {
            guard let parsed = try? AttributedString(markdown: line, options: options) else { return [Run(text: line)] }
            return parsed.runs.map { run in
                let intent = run.inlinePresentationIntent ?? []
                return Run(text: String(parsed[run.range].characters),
                           bold: intent.contains(.stronglyEmphasized), italic: intent.contains(.emphasized))
            }
        }
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(runs(paragraph.joined(separator: " ")))) }
            paragraph = []
        }

        for raw in source.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            let hashes = line.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), line.dropFirst(hashes).first == " " {
                flush()
                blocks.append(.heading(level: hashes, runs: runs(String(line.dropFirst(hashes + 1)))))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.first?.isNumber == true && line.contains(". ") {
                flush()
                blocks.append(.paragraph(runs(line.hasPrefix("- ") || line.hasPrefix("* ") ? "• " + line.dropFirst(2) : line)))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        self.blocks = blocks
    }

    // MARK: Output

    var markdown: String {
        blocks.map { block in
            switch block {
            case .heading(let level, let runs):
                return String(repeating: "#", count: level) + " " + runs.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            case .paragraph(let runs):
                return runs.map { run in
                    let trimmed = run.text.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty, run.bold || run.italic else { return run.text }
                    let mark = run.bold && run.italic ? "***" : run.bold ? "**" : "*"
                    // Keep surrounding spaces outside the markers so Markdown still parses.
                    let leading = String(run.text.prefix { $0 == " " })
                    let trailing = String(run.text.reversed().prefix { $0 == " " })
                    return leading + mark + trimmed + mark + trailing
                }.joined()
            }
        }.joined(separator: "\n\n") + "\n"
    }

    /// Well-formed XHTML body content (EPUB requires XML, not tag soup).
    var xhtmlBody: String {
        blocks.map { block in
            switch block {
            case .heading(let level, let runs):
                return "<h\(level)>\(Self.xhtml(runs))</h\(level)>"
            case .paragraph(let runs):
                return "<p>\(Self.xhtml(runs))</p>"
            }
        }.joined(separator: "\n")
    }

    private static func xhtml(_ runs: [Run]) -> String {
        runs.map { run in
            var html = run.text.xmlEscaped
            if run.italic { html = "<em>\(html)</em>" }
            if run.bold { html = "<strong>\(html)</strong>" }
            return html
        }.joined()
    }

    /// Back to rich text, for writers built on NSAttributedString (DOCX, RTF, PDF).
    var attributedString: NSAttributedString {
        let result = NSMutableAttributedString()
        let sizes: [CGFloat] = [24, 20, 16, 14, 13, 12]
        for block in blocks {
            var runs: [Run] = []
            var size: CGFloat = 12
            var heading = false
            switch block {
            case .heading(let level, let r):
                runs = r
                size = sizes[min(max(level, 1), 6) - 1]
                heading = true
            case .paragraph(let r):
                runs = r
            }
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = heading ? 6 : 8
            style.paragraphSpacingBefore = heading ? 10 : 0
            for run in runs {
                var font = heading || run.bold ? DocumentFont.bold(size) : DocumentFont.regular(size)
                if run.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                result.append(NSAttributedString(string: run.text, attributes: [.font: font, .paragraphStyle: style]))
            }
            result.append(NSAttributedString(string: "\n", attributes: [.font: DocumentFont.regular(size), .paragraphStyle: style]))
        }
        return result
    }

    /// Splits at level-1 headings into chapters (title, blocks); used for EPUB.
    func chapters(defaultTitle: String) -> [(title: String, text: StructuredText)] {
        var chapters: [(title: String, text: StructuredText)] = []
        for block in blocks {
            if case .heading(1, _) = block {
                chapters.append((block.plainText.trimmingCharacters(in: .whitespaces), StructuredText(blocks: [block])))
            } else if chapters.isEmpty {
                chapters.append((defaultTitle, StructuredText(blocks: [block])))
            } else {
                chapters[chapters.count - 1].text.blocks.append(block)
            }
        }
        return chapters.isEmpty ? [(defaultTitle, StructuredText(blocks: []))] : chapters
    }
}
