import Foundation
import UniformTypeIdentifiers

enum FileKind {
    case image, video, audio, pdf, document, archive, folder, other

    static func of(_ url: URL) -> FileKind {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true && values?.isPackage != true { return .folder }
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .zip) { return .archive }
        let documentTypes: [UTType] = [
            .plainText, .rtf, .rtfd, .html,
            UTType("org.openxmlformats.wordprocessingml.document"),
            UTType("com.microsoft.word.doc"),
            UTType("org.oasis-open.opendocument.text"),
        ].compactMap { $0 }
        if documentTypes.contains(where: { type.conforms(to: $0) }) { return .document }
        return .other
    }
}

enum Tool: String, Hashable {
    case compressImage, resizeHalf, rotateImage, flipImage, monoImage, stripMetadata, combineToPDF
    case compressVideo, video720, video1080, muteVideo, videoFrame
    case splitPDF, rotatePDF, mergePDF
    case zip, unzip

    /// Batch tools take every dropped file at once and produce a single output.
    var isBatch: Bool { [.combineToPDF, .mergePDF, .zip].contains(self) }
}

struct Action: Identifiable, Hashable {
    enum Kind: Hashable {
        case convert(String)   // target file extension
        case tool(Tool)
    }

    let kind: Kind
    let title: String
    let symbol: String

    var id: String {
        switch kind {
        case .convert(let ext): return "convert.\(ext)"
        case .tool(let tool): return "tool.\(tool.rawValue)"
        }
    }

    static func convert(_ ext: String, _ symbol: String) -> Action {
        Action(kind: .convert(ext), title: ext.uppercased(), symbol: symbol)
    }

    static func tool(_ tool: Tool, _ title: String, _ symbol: String) -> Action {
        Action(kind: .tool(tool), title: title, symbol: symbol)
    }
}

enum Mode { case convert, tools }

enum Catalog {
    static func actions(for urls: [URL], mode: Mode) -> [Action] {
        guard !urls.isEmpty else { return [] }
        let kinds = Set(urls.map(FileKind.of))
        let kind = kinds.count == 1 ? kinds.first! : .other
        let multiple = urls.count > 1
        let zip = Action.tool(.zip, "ZIP", "doc.zipper")

        switch mode {
        case .convert:
            let targets: [Action]
            switch kind {
            case .image:
                targets = ["jpg", "png", "heic", "tiff", "gif", "bmp", "pdf"].map { .convert($0, "photo") }
            case .video:
                targets = ["mp4", "mov", "m4v"].map { .convert($0, "film") }
                    + [.convert("gif", "photo.stack"), .convert("m4a", "waveform")]
            case .audio:
                targets = ["m4a", "wav", "aiff", "caf"].map { .convert($0, "waveform") }
            case .pdf:
                targets = ["png", "jpg", "tiff"].map { .convert($0, "photo") } + [.convert("txt", "doc.plaintext")]
            case .document:
                targets = ["pdf", "docx", "rtf", "txt", "html", "odt"].map { .convert($0, "doc.text") }
            case .archive:
                targets = [.tool(.unzip, "Unzip", "archivebox")]
            case .folder, .other:
                targets = [zip]
            }
            let sourceExts = Set(urls.map { normalize($0.pathExtension) })
            return targets.filter { action in
                guard case .convert(let ext) = action.kind, sourceExts.count == 1 else { return true }
                return sourceExts.first != ext
            }

        case .tools:
            var tools: [Action]
            switch kind {
            case .image:
                tools = [
                    .tool(.compressImage, "Compress", "arrow.down.right.and.arrow.up.left"),
                    .tool(.resizeHalf, "Resize ½", "aspectratio"),
                    .tool(.rotateImage, "Rotate", "rotate.right"),
                    .tool(.flipImage, "Flip", "arrow.left.and.right"),
                    .tool(.monoImage, "Mono", "circle.lefthalf.filled"),
                    .tool(.stripMetadata, "No EXIF", "eye.slash"),
                ]
                if multiple { tools.append(.tool(.combineToPDF, "To 1 PDF", "doc.on.doc")) }
            case .video:
                tools = [
                    .tool(.compressVideo, "Compress", "arrow.down.right.and.arrow.up.left"),
                    .tool(.video720, "720p", "tv"),
                    .tool(.video1080, "1080p", "tv"),
                    .tool(.muteVideo, "Mute", "speaker.slash"),
                    .tool(.videoFrame, "Frame", "camera"),
                ]
            case .pdf:
                tools = [
                    .tool(.splitPDF, "Split", "scissors"),
                    .tool(.rotatePDF, "Rotate", "rotate.right"),
                ]
                if multiple { tools.append(.tool(.mergePDF, "Merge", "rectangle.stack")) }
            case .audio, .document, .archive, .folder, .other:
                tools = []
            }
            if kind != .folder && kind != .other { tools.append(zip) }
            return tools
        }
    }

    static func normalize(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpeg": return "jpg"
        case "tif": return "tiff"
        case "aif": return "aiff"
        case "htm": return "html"
        default: return ext.lowercased()
        }
    }
}
