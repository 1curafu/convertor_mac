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
            return try await each(urls) { try await convert($0, to: ext) }

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
                return try await each(urls) { [try await apply(tool, to: $0)] }
            }

        case .file:
            throw ConvertError("File actions are handled by FileActions")
        }
    }

    /// Runs `work` on every file, carrying on past failures. If any failed, the error says how many
    /// results were saved, so a multi-file job never hides what it did write.
    private static func each(_ urls: [URL], _ work: (URL) async throws -> [URL]) async throws -> [URL] {
        var outputs: [URL] = []
        var failures: [(name: String, error: Error)] = []
        for url in urls {
            do { outputs += try await work(url) } catch { failures.append((url.lastPathComponent, error)) }
        }
        guard let first = failures.first else { return outputs }
        if urls.count == 1 { throw first.error }
        throw ConvertError("Saved \(urls.count - failures.count) of \(urls.count). "
            + failures.map { "\($0.name): \($0.error.localizedDescription)" }.joined(separator: " · "))
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
            return try await Spreadsheet.write(try await Spreadsheet.read(url), to: out, ext: ext)
        case .subtitle: return [try TextEngine.convertSubtitles(url, to: ext)]
        case .archive, .folder, .other: return [try await ArchiveEngine.pack([url], as: ext)]
        }
    }

    /// The one-tap tools.
    private static func apply(_ tool: Tool, to url: URL) async throws -> URL {
        let kind = FileKind.of(url)
        switch tool {
        case .compress:
            let out: URL
            switch kind {
            case .image: out = try ImageEngine.compress(url)
            case .pdf: out = try DocumentEngine.compressPDF(url)
            default: out = try await MediaEngine.compress(url)
            }
            // Already-optimised files can come out bigger; keep the original as the smaller copy.
            if let before = Output.fileSize(url), let after = Output.fileSize(out), after >= before {
                try? FileManager.default.removeItem(at: out)
                throw ConvertError("Already as small as it gets: compressing made it bigger, so nothing was saved")
            }
            return out
        case .mute: return try await MediaEngine.mute(url)
        case .normalize: return try await MediaEngine.normalize(url)
        case .split where kind == .pdf: return try DocumentEngine.splitPDF(url)
        case .extract: return try await ArchiveEngine.extract(url)
        default: throw ConvertError("\(tool.rawValue) needs its editor window")
        }
    }
}
