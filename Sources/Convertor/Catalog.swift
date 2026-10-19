import Foundation
import UniformTypeIdentifiers

enum FileKind {
    case image, video, audio, pdf, document, slides, spreadsheet, epub, subtitle, archive, folder, other

    /// The kind shared by every file, or `.other` for a mixed selection.
    static func common(_ urls: [URL]) -> FileKind {
        let kinds = Set(urls.map(FileKind.of))
        return kinds.count == 1 ? kinds.first! : .other
    }

    static func of(_ url: URL) -> FileKind {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true && values?.isPackage != true { return .folder }

        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") { return .archive }
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "webp", "heic", "heif", "tiff", "tif", "avif", "bmp", "gif", "svg":
            return .image
        case "mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv":
            return .video
        case "mp3", "m4a", "wav", "flac", "ogg", "oga", "opus", "aiff", "aif", "wma", "aac", "caf":
            return .audio
        case "pdf":
            return .pdf
        case "docx", "doc", "pages", "md", "markdown", "txt", "rtf", "rtfd", "html", "htm", "odt":
            return .document
        case "pptx", "ppt", "key", "odp":
            return .slides
        case "xlsx", "xls", "ods", "numbers", "csv", "tsv":
            return .spreadsheet
        case "epub":
            return .epub
        case "srt", "vtt":
            return .subtitle
        case "zip", "tar", "gz", "tgz", "rar":
            return .archive
        default:
            guard let type = UTType(filenameExtension: url.pathExtension) else { return .other }
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .movie) { return .video }
            if type.conforms(to: .audio) { return .audio }
            if type.conforms(to: .plainText) { return .document }
            return .other
        }
    }
}

/// The three wheels, mirroring Tangerine: ⇧ convert, ⌘ tools, ⌃ actions.
enum Mode: CaseIterable {
    case convert, tools, actions

    var title: String {
        switch self {
        case .convert: return "Convert"
        case .tools: return "Tools"
        case .actions: return "Actions"
        }
    }

    var key: String {
        switch self {
        case .convert: return "⇧"
        case .tools: return "⌘"
        case .actions: return "⌃"
        }
    }
}

enum Tool: String, Hashable {
    case compress, metadata, edit, annotate, addBackground, crop, redact, createPDF, collage
    case mute, trim, speed, snapshot, split, join
    case normalize, visualize, channels, bleep
    case organize, merge
    case extract, zip

    /// Tools that open an editor window instead of running straight away.
    func needsEditor(for kind: FileKind) -> Bool {
        switch self {
        case .compress, .createPDF, .mute, .normalize, .merge, .extract, .zip: return false
        case .split: return kind != .pdf
        default: return true
        }
    }
}

enum FileAction: String, Hashable, CaseIterable {
    case airDrop, copy, copyPath, move, float, terminal
}

struct Action: Identifiable, Hashable {
    enum Kind: Hashable {
        case convert(String)   // target file extension
        case tool(Tool)
        case file(FileAction)
    }

    let kind: Kind
    let title: String
    let symbol: String

    var id: String {
        switch kind {
        case .convert(let ext): return "convert.\(ext)"
        case .tool(let tool): return "tool.\(tool.rawValue)"
        case .file(let action): return "file.\(action.rawValue)"
        }
    }

    /// Caption under the wheel, e.g. "Convert to PNG".
    var caption: String {
        switch kind {
        case .convert: return "Convert to \(title)"
        case .tool, .file: return title
        }
    }

    static func convert(_ ext: String, title: String? = nil) -> Action {
        Action(kind: .convert(ext), title: title ?? ext.uppercased(), symbol: "")
    }

    static func tool(_ tool: Tool, _ title: String, _ symbol: String) -> Action {
        Action(kind: .tool(tool), title: title, symbol: symbol)
    }

    static func file(_ action: FileAction, _ title: String, _ symbol: String) -> Action {
        Action(kind: .file(action), title: title, symbol: symbol)
    }
}

enum Catalog {
    static func actions(for urls: [URL], mode: Mode) -> [Action] {
        guard !urls.isEmpty else { return [] }
        let kind = FileKind.common(urls)
        let multiple = urls.count > 1

        switch mode {
        case .convert:
            let sourceExts = Set(urls.map { normalize($0) })
            return convertTargets(for: kind, from: sourceExts).filter { action in
                guard case .convert(let ext) = action.kind, sourceExts.count == 1 else { return true }
                return sourceExts.first != ext
            }
        case .tools:
            return tools(for: kind, multiple: multiple)
        case .actions:
            return [
                .file(.airDrop, "AirDrop", "airplayaudio"),
                .file(.copy, "Copy", "doc.on.doc"),
                .file(.copyPath, "Copy Path", "link"),
                .file(.move, "Move", "folder"),
                .file(.float, "Float", "pin"),
                .file(.terminal, "Terminal", "terminal"),
            ]
        }
    }

    private static func convertTargets(for kind: FileKind, from sources: Set<String>) -> [Action] {
        let targets: [String]
        switch kind {
        case .image: targets = ["jpg", "png", "webp", "heic", "avif", "tiff", "bmp", "pdf"]
        case .video: targets = ["mp4", "mov", "mkv", "webm", "avi", "wmv", "gif", "mp3"]
        case .audio: targets = ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"]
        case .pdf: targets = ["docx", "pages", "pptx", "xlsx", "jpg", "png", "epub", "txt", "md"]
        case .document: targets = ["pages", "pdf", "docx", "txt", "md", "html", "epub", "png", "jpg"]
        case .slides: targets = ["pdf", "png", "jpg"] + (sources == ["key"] ? ["pptx"] : [])
        case .spreadsheet: targets = ["xlsx", "ods", "csv", "tsv", "pdf"]
        case .epub: targets = ["pdf", "docx", "pages", "txt", "md", "html"]
        case .subtitle: targets = ["srt", "vtt", "txt"]
        case .archive, .folder, .other:
            return [.convert("zip"), .convert("tar"), .convert("tar.gz", title: "GZIP")]
        }
        return targets.map { .convert($0) }
    }

    private static let compress = Action.tool(.compress, "Compress", "arrow.down.right.and.arrow.up.left")
    private static let metadata = Action.tool(.metadata, "Metadata", "tag")

    /// Same order as Tangerine's wheels, clockwise from the top.
    private static func tools(for kind: FileKind, multiple: Bool) -> [Action] {
        switch kind {
        case .image:
            var tools: [Action] = [
                compress, metadata,
                .tool(.edit, "Edit", "slider.horizontal.3"),
                .tool(.annotate, "Annotate", "pencil.tip"),
                .tool(.addBackground, "Add BG", "photo.artframe"),
                .tool(.crop, "Crop", "crop"),
                .tool(.redact, "Redact", "eye.slash"),
            ]
            if multiple {
                tools += [.tool(.createPDF, "Create PDF", "doc.richtext"), .tool(.collage, "Collage", "square.grid.2x2")]
            }
            return tools
        case .video:
            var tools: [Action] = [
                compress, metadata,
                .tool(.mute, "Mute", "speaker.slash"),
                .tool(.trim, "Trim", "scissors"),
                .tool(.crop, "Crop", "crop"),
                .tool(.speed, "Speed", "gauge.with.dots.needle.67percent"),
                .tool(.snapshot, "Snapshot", "camera"),
                .tool(.split, "Split", "square.split.2x1"),
                .tool(.redact, "Redact", "eye.slash"),
            ]
            if multiple { tools.append(.tool(.join, "Join", "film.stack")) }
            return tools
        case .audio:
            return [
                compress, metadata,
                .tool(.normalize, "Normalize", "waveform"),
                .tool(.visualize, "Visualize", "waveform.path.ecg.rectangle"),
                .tool(.trim, "Trim", "scissors"),
                .tool(.channels, "Channels", "rectangle.split.2x1"),
                .tool(.bleep, "Bleep", "waveform.badge.exclamationmark"),
            ]
        case .pdf:
            var tools: [Action] = [
                compress, metadata,
                .tool(.split, "Split", "rectangle.split.3x1"),
                .tool(.organize, "Organize", "square.grid.3x2"),
            ]
            if multiple { tools.append(.tool(.merge, "Merge", "rectangle.stack")) }
            return tools
        case .archive:
            return [.tool(.extract, "Extract", "archivebox")]
        case .document, .slides, .spreadsheet, .epub, .subtitle, .folder, .other:
            return [.tool(.zip, "ZIP", "doc.zipper")]
        }
    }

    /// Lower-cased extension with common aliases folded together (jpeg → jpg, …).
    static func normalize(_ url: URL) -> String {
        if url.lastPathComponent.lowercased().hasSuffix(".tar.gz") { return "tar.gz" }
        switch url.pathExtension.lowercased() {
        case "jpeg": return "jpg"
        case "tif": return "tiff"
        case "aif": return "aiff"
        case "htm": return "html"
        case "markdown": return "md"
        case "tgz": return "tar.gz"
        case let ext: return ext
        }
    }
}
