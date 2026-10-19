import Foundation

/// Routes an action from the wheel to the engine that implements it.
/// Tools that need a window (crop, trim, …) are opened by `ConversionCenter` instead.
enum Engine {
    static func perform(_ action: Action, on urls: [URL]) async throws -> [URL] {
        let kind = FileKind.common(urls)
        switch action.kind {
        case .convert(let ext):
            if [FileKind.archive, .folder, .other].contains(kind) {
                return [try await ArchiveEngine.pack(urls, as: ext)]
            }
            var outputs: [URL] = []
            for url in urls { outputs += try await convert(url, to: ext) }
            return outputs

        case .tool(let tool):
            switch tool {
            case .createPDF:
                let out = Output.unique(Output.directory(for: urls[0]), name: "Combined", ext: "pdf")
                try ImageEngine.imagesToPDF(urls, output: out)
                return [out]
            case .merge:
                return [try DocumentEngine.merge(urls)]
            case .zip:
                return [try await ArchiveEngine.pack(urls, as: "zip")]
            default:
                var outputs: [URL] = []
                for url in urls { outputs.append(try await apply(tool, to: url)) }
                return outputs
            }

        case .file:
            throw ConvertError("File actions are handled by FileActions")
        }
    }

    private static func convert(_ url: URL, to ext: String) async throws -> [URL] {
        switch FileKind.of(url) {
        case .image: return [try await ImageEngine.convert(url, to: ext)]
        case .video, .audio: return [try await MediaEngine.convert(url, to: ext)]
        case .pdf: return try await DocumentEngine.convertPDF(url, to: ext)
        case .document, .epub: return try await DocumentEngine.convert(url, to: ext)
        case .slides: return try await DocumentEngine.convertSlides(url, to: ext)
        case .spreadsheet:
            let out = Output.file(for: url, ext: ext)
            if ext == "pdf", ["xlsx", "xls", "numbers"].contains(Catalog.normalize(url)), IWork.App.numbers.isInstalled,
               (try? await IWork.export(url, with: .numbers, as: .pdf, to: out)) != nil {
                return [out]
            }
            try await Spreadsheet.write(try await Spreadsheet.read(url), to: out, ext: ext)
            return [out]
        case .subtitle: return [try TextEngine.convertSubtitles(url, to: ext)]
        case .archive, .folder, .other: return [try await ArchiveEngine.pack([url], as: ext)]
        }
    }

    /// The one-tap tools.
    private static func apply(_ tool: Tool, to url: URL) async throws -> URL {
        let kind = FileKind.of(url)
        switch tool {
        case .compress:
            switch kind {
            case .image: return try ImageEngine.compress(url)
            case .pdf: return try DocumentEngine.compressPDF(url)
            default: return try await MediaEngine.compress(url)
            }
        case .mute: return try await MediaEngine.mute(url)
        case .normalize: return try await MediaEngine.normalize(url)
        case .split where kind == .pdf: return try DocumentEngine.splitPDF(url)
        case .extract: return try await ArchiveEngine.extract(url)
        default: throw ConvertError("\(tool.rawValue) needs its editor window")
        }
    }
}
