import Foundation
import UniformTypeIdentifiers

enum FileKind {
    case image, video, audio, pdf, document, spreadsheet, subtitle, archive, folder, other

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
        case "docx", "doc", "md", "markdown", "txt", "rtf", "rtfd", "html", "htm", "odt":
            return .document
        case "csv", "tsv":
            return .spreadsheet
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
    // images
    case compressImage, resizeHalf, rotateImage, flipImage, monoImage, stripMetadata, combineToPDF
    // video
    case compressVideo, video720, muteVideo, videoFrame, speedUp, joinVideos
    // audio
    case compressAudio, normalizeAudio, monoAudio, trimSilence, visualizeAudio
    // pdf
    case compressPDF, splitPDF, rotatePDF, mergePDF
    // archives
    case extract, zip

    /// Batch tools take every dropped file at once and produce a single output.
    var isBatch: Bool { [.combineToPDF, .joinVideos, .mergePDF, .zip].contains(self) }
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
            return convertTargets(for: kind).filter { action in
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

    private static func convertTargets(for kind: FileKind) -> [Action] {
        switch kind {
        case .image:
            return ["jpg", "png", "webp", "heic", "tiff", "avif", "bmp", "pdf"].map { .convert($0) }
        case .video:
            return ["mp4", "mov", "mkv", "webm", "avi", "wmv", "gif", "mp3"].map { .convert($0) }
        case .audio:
            return ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"].map { .convert($0) }
        case .pdf:
            return ["docx", "jpg", "png", "txt", "md", "rtf"].map { .convert($0) }
        case .document:
            return ["pdf", "docx", "md", "txt", "html", "rtf", "odt"].map { .convert($0) }
        case .spreadsheet:
            return ["csv", "tsv"].map { .convert($0) }
        case .subtitle:
            return ["srt", "vtt", "txt"].map { .convert($0) }
        case .archive, .folder, .other:
            return [.convert("zip"), .convert("tar"), .convert("tar.gz", title: "GZIP")]
        }
    }

    private static func tools(for kind: FileKind, multiple: Bool) -> [Action] {
        let zip = Action.tool(.zip, "ZIP", "doc.zipper")
        switch kind {
        case .image:
            var tools: [Action] = [
                .tool(.compressImage, "Compress", "arrow.down.right.and.arrow.up.left"),
                .tool(.resizeHalf, "Resize ½", "aspectratio"),
                .tool(.rotateImage, "Rotate", "rotate.right"),
                .tool(.flipImage, "Flip", "arrow.left.and.right"),
                .tool(.monoImage, "Mono", "circle.lefthalf.filled"),
                .tool(.stripMetadata, "No EXIF", "eye.slash"),
            ]
            if multiple { tools.append(.tool(.combineToPDF, "To PDF", "doc.richtext")) }
            return tools
        case .video:
            var tools: [Action] = [
                .tool(.compressVideo, "Compress", "arrow.down.right.and.arrow.up.left"),
                .tool(.video720, "720p", "tv"),
                .tool(.muteVideo, "Mute", "speaker.slash"),
                .tool(.videoFrame, "Frame", "camera"),
                .tool(.speedUp, "2× Speed", "hare"),
            ]
            if multiple { tools.append(.tool(.joinVideos, "Join", "film.stack")) }
            return tools
        case .audio:
            return [
                .tool(.compressAudio, "Compress", "arrow.down.right.and.arrow.up.left"),
                .tool(.normalizeAudio, "Normalize", "speaker.wave.2"),
                .tool(.monoAudio, "Mono", "dot.radiowaves.left.and.right"),
                .tool(.trimSilence, "Trim Silence", "scissors"),
                .tool(.visualizeAudio, "Visualize", "waveform"),
            ]
        case .pdf:
            var tools: [Action] = [
                .tool(.compressPDF, "Compress", "arrow.down.right.and.arrow.up.left"),
                .tool(.splitPDF, "Split", "scissors"),
                .tool(.rotatePDF, "Rotate", "rotate.right"),
            ]
            if multiple { tools.append(.tool(.mergePDF, "Merge", "rectangle.stack")) }
            return tools
        case .archive:
            return [.tool(.extract, "Extract", "archivebox")]
        case .document, .spreadsheet, .subtitle, .folder, .other:
            return [zip]
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
