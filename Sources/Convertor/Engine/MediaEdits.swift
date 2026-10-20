import AVFoundation
import Foundation

/// The operations behind the audio/video editor windows. Mostly ffmpeg filter graphs;
/// AVFoundation passthrough is used for plain cuts of MP4/MOV/M4A because it's lossless and fast.
enum MediaEdits {
    enum RedactStyle: String, CaseIterable, Identifiable {
        case blur = "Blur", pixelate = "Pixelate", solid = "Solid"
        var id: String { rawValue }
    }

    enum BleepSound: String, CaseIterable, Identifiable {
        case beep = "Beep", silence = "Silence"
        var id: String { rawValue }
    }

    enum Canvas: String, CaseIterable, Identifiable {
        case landscape = "Landscape", portrait = "Portrait", square = "Square"
        var id: String { rawValue }
        var size: (Int, Int) {
            switch self {
            case .landscape: return (1280, 720)
            case .portrait: return (720, 1280)
            case .square: return (1080, 1080)
            }
        }
    }

    enum VisualStyle: String, CaseIterable, Identifiable {
        case waveform = "Waveform", bars = "Bars", image = "Still image"
        var id: String { rawValue }
    }

    private static func seconds(_ value: Double) -> String { String(format: "%.3f", max(0, value)) }

    /// Encoder flags for re-encoding a file of this kind into its own format.
    private static func codecArgs(for url: URL) -> [String] {
        let ext = Catalog.normalize(url)
        return FileKind.of(url) == .audio ? MediaEngine.audioCodec(for: ext) : FFmpeg.arguments(for: ext)
    }

    // MARK: Cutting

    /// Copies `start…end` of a file. Lossless passthrough when AVFoundation can do it.
    static func cut(_ url: URL, start: Double, end: Double, to out: URL, filters: [String] = []) async throws {
        let ext = Catalog.normalize(url)
        if filters.isEmpty, MediaEngine.appleReadable(url), ["mp4", "mov", "m4v", "m4a"].contains(ext) {
            let asset = AVURLAsset(url: url)
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                throw ConvertError("Can't cut this file")
            }
            session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                            end: CMTime(seconds: end, preferredTimescale: 600))
            do {
                try await session.export(to: out, as: MediaEngine.fileType(for: ext))
            } catch {
                try? FileManager.default.removeItem(at: out)
                throw ConvertError(error.localizedDescription)
            }
            return
        }
        try await FFmpeg.run(input: url, output: out,
                             args: ["-t", seconds(end - start)] + filters + codecArgs(for: url),
                             inputArgs: ["-ss", seconds(start)])
    }

    static func trim(_ url: URL, start: Double, end: Double, removeSilence: Bool) async throws -> URL {
        let out = Output.file(for: url, suffix: " trimmed", ext: Catalog.normalize(url))
        // Strip silence at both ends only, keeping pauses inside the recording.
        let silence = "silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.1,areverse,"
            + "silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.1,areverse"
        try await cut(url, start: start, end: end, to: out, filters: removeSilence ? ["-af", silence] : [])
        return out
    }

    /// Every section between split points as its own file in a new folder.
    static func split(_ url: URL, at points: [Double], duration: Double) async throws -> URL {
        let ext = Catalog.normalize(url)
        let edges = [0] + points.filter { $0 > 0.05 && $0 < duration - 0.05 }.sorted() + [duration]
        let folder = try Output.folder(for: url, suffix: " clips")
        for index in 0..<(edges.count - 1) {
            let out = Output.unique(folder, name: "\(Output.baseName(url)) \(index + 1)", ext: ext)
            try await cut(url, start: edges[index], end: edges[index + 1], to: out)
        }
        return folder
    }

    static func snapshot(_ url: URL, at time: Double, into folder: URL) async throws -> URL {
        guard let frame = await Media.frame(url, at: time) else { throw ConvertError("Couldn't read that frame") }
        let stamp = String(format: "%02d-%02d-%03d", Int(time) / 60, Int(time) % 60, Int((time - floor(time)) * 1000))
        let out = Output.unique(folder, name: "\(Output.baseName(url)) \(stamp)", ext: "png")
        try ImageEngine.write(frame, to: out, ext: "png", quality: 1, metadata: nil)
        return out
    }

    // MARK: Audio

    static func bleep(_ url: URL, ranges: [ClosedRange<Double>], sound: BleepSound, duration: Double) async throws -> URL {
        guard !ranges.isEmpty else { throw ConvertError("Mark at least one range to bleep") }
        let out = Output.file(for: url, suffix: " bleeped", ext: Catalog.normalize(url))
        let condition = ranges.map { "between(t,\(seconds($0.lowerBound)),\(seconds($0.upperBound)))" }.joined(separator: "+")
        let muted = "volume=enable='\(condition)':volume=0"

        switch sound {
        case .silence:
            try await FFmpeg.run(input: url, output: out, args: ["-vn", "-af", muted] + codecArgs(for: url))
        case .beep:
            let graph = "[0:a]\(muted)[m];"
                + "sine=frequency=1000:sample_rate=48000:duration=\(seconds(duration + 1)),volume=0.35,"
                + "volume=enable='not(\(condition))':volume=0[b];"
                + "[m][b]amix=inputs=2:duration=first:normalize=0[out]"
            try await FFmpeg.run(input: url, output: out, args: ["-filter_complex", graph, "-map", "[out]"] + codecArgs(for: url))
        }
        return out
    }

    static func channels(_ url: URL, mono: Bool) async throws -> URL {
        let out = Output.file(for: url, suffix: mono ? " mono" : " stereo", ext: Catalog.normalize(url))
        try await FFmpeg.run(input: url, output: out, args: ["-vn", "-ac", mono ? "1" : "2"] + codecArgs(for: url))
        return out
    }

    static func visualize(_ url: URL, canvas: Canvas, style: VisualStyle, color: String, image: URL?) async throws -> URL {
        let (width, height) = canvas.size
        let out = Output.file(for: url, suffix: " visualized", ext: "mp4")
        let encode = ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-shortest", "-movflags", "+faststart"]

        switch style {
        case .image:
            guard let image else { throw ConvertError("Choose an image first") }
            let graph = "[0:v]scale=\(width):\(height):force_original_aspect_ratio=decrease,"
                + "pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2:color=black,format=yuv420p[v]"
            try await FFmpeg.run(inputs: [image, url], output: out,
                                 args: ["-filter_complex", graph, "-map", "[v]", "-map", "1:a", "-tune", "stillimage", "-r", "30"] + encode,
                                 inputArgs: ["-loop", "1"])
        case .waveform, .bars:
            let source = style == .waveform
                ? "showwaves=s=\(width)x\(height):mode=cline:scale=sqrt:colors=0x\(color)"
                : "showfreqs=s=\(width)x\(height):mode=bar:ascale=sqrt:colors=0x\(color)"
            try await FFmpeg.run(input: url, output: out,
                                 args: ["-filter_complex", "[0:a]\(source),format=yuv420p[v]", "-map", "[v]", "-map", "0:a"] + encode)
        }
        return out
    }

    // MARK: Video

    /// `rect` is normalised (0…1, origin top-left) against the displayed frame.
    static func crop(_ url: URL, rect: CGRect, width: Int, height: Int) async throws -> URL {
        let box = pixelBox(rect, width: width, height: height)
        let out = Output.file(for: url, suffix: " cropped", ext: Catalog.normalize(url))
        try await FFmpeg.run(input: url, output: out,
                             args: ["-vf", "crop=\(box.w):\(box.h):\(box.x):\(box.y)"] + FFmpeg.arguments(for: Catalog.normalize(url)))
        return out
    }

    static func redact(_ url: URL, rects: [CGRect], style: RedactStyle, range: ClosedRange<Double>?, width: Int, height: Int) async throws -> URL {
        guard !rects.isEmpty else { throw ConvertError("Draw at least one area to cover") }
        let enable = range.map { ":enable='between(t,\(seconds($0.lowerBound)),\(seconds($0.upperBound)))'" } ?? ""
        let boxes = rects.map { pixelBox($0, width: width, height: height) }
        var graph: String

        if style == .solid {
            graph = "[0:v]" + boxes.map { "drawbox=x=\($0.x):y=\($0.y):w=\($0.w):h=\($0.h):color=black:t=fill\(enable)" }
                .joined(separator: ",") + "[vout]"
        } else {
            graph = "[0:v]split=\(boxes.count + 1)[base]" + boxes.indices.map { "[r\($0)]" }.joined() + ";"
            for (index, box) in boxes.enumerated() {
                let effect: String
                if style == .blur {
                    let radius = max(2, min(30, min(box.w, box.h) / 4))
                    effect = "boxblur=\(radius):3:\(max(1, radius / 2)):3"
                } else {
                    effect = "scale=max(2\\,iw/16):max(2\\,ih/16),scale=\(box.w):\(box.h):flags=neighbor"
                }
                graph += "[r\(index)]crop=\(box.w):\(box.h):\(box.x):\(box.y),\(effect)[c\(index)];"
            }
            var current = "base"
            for (index, box) in boxes.enumerated() {
                let next = index == boxes.count - 1 ? "vout" : "o\(index)"
                graph += "[\(current)][c\(index)]overlay=\(box.x):\(box.y)\(enable)[\(next)]"
                if index < boxes.count - 1 { graph += ";" }
                current = next
            }
        }

        let out = Output.file(for: url, suffix: " redacted", ext: Catalog.normalize(url))
        try await FFmpeg.run(input: url, output: out,
                             args: ["-filter_complex", graph, "-map", "[vout]", "-map", "0:a?"] + FFmpeg.arguments(for: Catalog.normalize(url)))
        return out
    }

    /// Changes speed while keeping the audio's pitch.
    static func speed(_ url: URL, factor: Double, hasAudio: Bool) async throws -> URL {
        var tempos: [Double] = []
        var remaining = factor
        while remaining > 2 { tempos.append(2); remaining /= 2 }
        while remaining < 0.5 { tempos.append(0.5); remaining /= 0.5 }
        tempos.append(remaining)

        var graph = "[0:v]setpts=PTS/\(factor)[v]"
        var maps = ["-map", "[v]"]
        if hasAudio {
            graph += ";[0:a]" + tempos.map { "atempo=\($0)" }.joined(separator: ",") + "[a]"
            maps += ["-map", "[a]"]
        }
        let label = factor == factor.rounded() ? "\(Int(factor))x" : "\(factor)x"
        let out = Output.file(for: url, suffix: " \(label)", ext: Catalog.normalize(url))
        try await FFmpeg.run(input: url, output: out, args: ["-filter_complex", graph] + maps + FFmpeg.arguments(for: Catalog.normalize(url)))
        return out
    }

    /// Joins clips in order into one MP4, scaling everything to the first clip's frame.
    static func join(_ urls: [URL]) async throws -> URL {
        guard let first = urls.first, urls.count > 1 else { throw ConvertError("Pick at least two videos") }
        var infos: [Media.Info] = []
        for url in urls { infos.append(await Media.probe(url)) }
        let width = max(2, infos[0].width / 2 * 2), height = max(2, infos[0].height / 2 * 2)
        let withAudio = infos.allSatisfy(\.hasAudio)

        var graph = ""
        var inputs = ""
        for index in urls.indices {
            graph += "[\(index):v]scale=\(width):\(height):force_original_aspect_ratio=decrease,"
                + "pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,format=yuv420p[v\(index)];"
            inputs += "[v\(index)]"
            if withAudio {
                graph += "[\(index):a]aresample=48000,aformat=channel_layouts=stereo[a\(index)];"
                inputs += "[a\(index)]"
            }
        }
        graph += "\(inputs)concat=n=\(urls.count):v=1:a=\(withAudio ? 1 : 0)[v]" + (withAudio ? "[a]" : "")
        let out = Output.file(for: first, suffix: " joined", ext: "mp4")
        try await FFmpeg.run(inputs: urls, output: out,
                             args: ["-filter_complex", graph, "-map", "[v]"] + (withAudio ? ["-map", "[a]"] : []) + FFmpeg.arguments(for: "mp4"))
        return out
    }

    // MARK: Metadata

    static let metadataKeys = ["title", "artist", "album", "genre", "date", "comment"]

    static func writeMetadata(_ url: URL, fields: [String: String], removeAll: Bool) async throws -> URL {
        let out = Output.file(for: url, suffix: removeAll ? " clean" : " edited", ext: Catalog.normalize(url))
        var args = ["-map", "0:v?", "-map", "0:a?", "-c", "copy"]
        if removeAll {
            args += ["-map_metadata", "-1"]
        } else {
            for key in metadataKeys {
                args += ["-metadata", "\(key)=\(fields[key] ?? "")"]
            }
        }
        try await FFmpeg.run(input: url, output: out, args: args)
        return out
    }

    /// Even-sized pixel box for ffmpeg (most encoders need even dimensions).
    private static func pixelBox(_ rect: CGRect, width: Int, height: Int) -> (x: Int, y: Int, w: Int, h: Int) {
        let x = max(0, Int(rect.minX * CGFloat(width))) / 2 * 2
        let y = max(0, Int(rect.minY * CGFloat(height))) / 2 * 2
        let w = max(2, min(width - x, Int(rect.width * CGFloat(width))) / 2 * 2)
        let h = max(2, min(height - y, Int(rect.height * CGFloat(height))) / 2 * 2)
        return (x, y, w, h)
    }
}

extension Media {
    /// Container-level tags (title, artist, …) as ffmpeg reports them.
    static func metadata(_ url: URL) async -> [String: String] {
        guard let ffmpeg = FFmpeg.path, let result = try? await Shell.capture(ffmpeg, ["-hide_banner", "-i", url.path]) else { return [:] }
        var fields: [String: String] = [:]
        var inBlock = false
        for line in result.errorText.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Metadata:") { inBlock = true; continue }
            if trimmed.hasPrefix("Duration:") || trimmed.hasPrefix("Stream #") { if !fields.isEmpty { break }; inBlock = false; continue }
            guard inBlock, let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if fields[key] == nil { fields[key] = value }
        }
        return fields
    }
}
