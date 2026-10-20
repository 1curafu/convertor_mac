import Foundation

/// Bridge to ffmpeg for everything Apple's frameworks can't encode or decode.
/// The build script bundles a static ffmpeg in Contents/MacOS; Homebrew's is the fallback.
enum FFmpeg {
    static var path: String? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let override = ProcessInfo.processInfo.environment["CONVERTOR_FFMPEG"] { candidates.append(override) }
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "ffmpeg") { candidates.append(bundled.path) }
        candidates += ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    static var isAvailable: Bool { path != nil }

    static func run(input: URL, output: URL, args: [String], inputArgs: [String] = []) async throws {
        try await run(inputs: [input], output: output, args: args, inputArgs: inputArgs)
    }

    static func run(inputs: [URL], output: URL, args: [String], inputArgs: [String] = []) async throws {
        guard let path else {
            throw ConvertError("This format needs ffmpeg. Rebuild the app with scripts/build_app.sh or run `brew install ffmpeg`.")
        }
        var arguments = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y"] + inputArgs
        for input in inputs { arguments += ["-i", input.path] }
        arguments += evenDimensions(args) + [output.path]
        do {
            try await Shell.run(path, arguments)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    /// libx264 with yuv420p rejects odd widths and heights, which screen recordings often have.
    /// Rounds the video down to even dimensions: on the mapped filter graph output, the `-vf`
    /// chain, or a new `-vf`.
    static func evenDimensions(_ args: [String]) -> [String] {
        guard args.contains("libx264") else { return args }
        let even = "scale=trunc(iw/2)*2:trunc(ih/2)*2,setsar=1"   // square pixels, so players show the new size
        var args = args
        if let graph = args.firstIndex(of: "-filter_complex"), graph + 1 < args.count,
           let map = args.indices.first(where: { $0 > 0 && args[$0 - 1] == "-map" && args[$0].hasPrefix("[") }) {
            let label = args[map].dropFirst().dropLast()
            args[graph + 1] += ";[\(label)]\(even)[\(label)even]"
            args[map] = "[\(label)even]"
        } else if let filter = args.firstIndex(of: "-vf"), filter + 1 < args.count {
            args[filter + 1] += ",\(even)"
        } else {
            args = ["-vf", even] + args
        }
        return args
    }

    /// Encoder settings per output extension.
    static func arguments(for ext: String) -> [String] {
        switch ext {
        // audio
        case "mp3": return ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case "m4a": return ["-vn", "-c:a", "aac", "-b:a", "256k"]
        case "wav": return ["-vn", "-c:a", "pcm_s16le"]
        case "aiff": return ["-vn", "-c:a", "pcm_s16be"]
        case "flac": return ["-vn", "-c:a", "flac"]
        case "ogg": return ["-vn", "-c:a", "libvorbis", "-q:a", "5"]
        case "opus": return ["-vn", "-c:a", "libopus", "-b:a", "128k"]
        case "wma": return ["-vn", "-c:a", "wmav2", "-b:a", "192k"]
        // video
        case "mp4", "m4v":
            return ["-c:v", "libx264", "-crf", "20", "-preset", "medium", "-pix_fmt", "yuv420p",
                    "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
        case "mov", "mkv":
            return ["-c:v", "libx264", "-crf", "20", "-preset", "medium", "-pix_fmt", "yuv420p",
                    "-c:a", "aac", "-b:a", "192k"]
        case "webm":
            return ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-c:a", "libopus"]
        case "avi": return ["-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame", "-q:a", "3"]
        case "wmv": return ["-c:v", "wmv2", "-q:v", "3", "-c:a", "wmav2", "-b:a", "192k"]
        case "gif":
            return ["-vf", "fps=12,scale='min(640,iw)':-2:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse",
                    "-loop", "0"]
        // still images
        case "webp": return ["-frames:v", "1", "-quality", "85"]
        case "avif": return ["-frames:v", "1"]
        default: return []
        }
    }
}
