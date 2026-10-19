import Foundation

/// Routes an action from the wheel to the engine that implements it.
enum Engine {
    static func perform(_ action: Action, on urls: [URL]) async throws -> [URL] {
        switch action.kind {
        case .convert(let ext):
            if [FileKind.archive, .folder, .other].contains(FileKind.common(urls)) {
                return [try await ArchiveEngine.pack(urls, as: ext)]
            }
            var outputs: [URL] = []
            for url in urls { outputs += try await convert(url, to: ext) }
            return outputs

        case .tool(let tool):
            switch tool {
            case .combineToPDF:
                let out = Output.unique(Output.directory(for: urls[0]), name: "Combined", ext: "pdf")
                try ImageEngine.imagesToPDF(urls, output: out)
                return [out]
            case .mergePDF:
                return [try await DocumentEngine.merge(urls)]
            case .joinVideos:
                return [try await MediaEngine.join(urls)]
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
        case .document: return [try await DocumentEngine.convert(url, to: ext)]
        case .spreadsheet: return [try TextEngine.convertTable(url, to: ext)]
        case .subtitle: return [try TextEngine.convertSubtitles(url, to: ext)]
        case .archive, .folder, .other: return [try await ArchiveEngine.pack([url], as: ext)]
        }
    }

    private static func apply(_ tool: Tool, to url: URL) async throws -> URL {
        switch tool {
        case .compressImage, .resizeHalf, .rotateImage, .flipImage, .monoImage, .stripMetadata:
            return try ImageEngine.apply(tool, to: url)
        case .compressPDF, .splitPDF, .rotatePDF:
            return try await DocumentEngine.applyPDF(tool, to: url)
        case .extract:
            return try await ArchiveEngine.extract(url)
        default:
            return try await MediaEngine.apply(tool, to: url)
        }
    }
}
