import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Video and audio. AVFoundation handles what it can read and write; ffmpeg covers the rest.
enum MediaEngine {
    static let appleVideoInputs: Set<String> = ["mp4", "mov", "m4v"]
    static let appleAudioInputs: Set<String> = ["m4a", "wav", "aiff", "caf", "mp3", "aac"]

    private static func appleReadable(_ url: URL) -> Bool {
        let ext = Catalog.normalize(url)
        return appleVideoInputs.contains(ext) || appleAudioInputs.contains(ext)
    }

    private static func fileType(for ext: String) -> AVFileType {
        switch ext {
        case "mp4": return .mp4
        case "m4v": return .m4v
        case "m4a": return .m4a
        default: return .mov
        }
    }

    // MARK: Convert

    static func convert(_ url: URL, to ext: String) async throws -> URL {
        let out = Output.file(for: url, ext: ext)
        let readable = appleReadable(url)
        let sourceIsVideo = appleVideoInputs.contains(Catalog.normalize(url))

        if readable && sourceIsVideo && ["mp4", "mov", "m4v"].contains(ext) {
            try await export(AVURLAsset(url: url), preset: AVAssetExportPresetHighestQuality, to: out, type: fileType(for: ext))
        } else if readable && ext == "m4a" {
            try await export(AVURLAsset(url: url), preset: AVAssetExportPresetAppleM4A, to: out, type: .m4a)
        } else if readable && !sourceIsVideo && ["wav", "aiff"].contains(ext) {
            try transcodePCM(url, to: out, bigEndian: ext == "aiff")
        } else if ext == "gif" && readable && !FFmpeg.isAvailable {
            try await videoToGIF(url, output: out)
        } else {
            try await FFmpeg.run(input: url, output: out, args: FFmpeg.arguments(for: ext))
        }
        return out
    }

    // MARK: Tools

    static func apply(_ tool: Tool, to url: URL) async throws -> URL {
        let ext = Catalog.normalize(url)
        let readable = appleReadable(url)
        let asset = AVURLAsset(url: url)

        switch tool {
        case .compressVideo:
            let out = Output.file(for: url, suffix: " compressed", ext: "mp4")
            if FFmpeg.isAvailable {
                try await FFmpeg.run(input: url, output: out, args: [
                    "-c:v", "libx264", "-crf", "28", "-preset", "slow", "-pix_fmt", "yuv420p",
                    "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart",
                ])
            } else {
                try await export(asset, preset: AVAssetExportPresetHEVCHighestQuality, to: out, type: .mp4)
            }
            return out

        case .video720:
            let out = Output.file(for: url, suffix: " 720p", ext: "mp4")
            if readable {
                try await export(asset, preset: AVAssetExportPreset1280x720, to: out, type: .mp4)
            } else {
                try await FFmpeg.run(input: url, output: out, args: ["-vf", "scale=-2:720"] + FFmpeg.arguments(for: "mp4"))
            }
            return out

        case .muteVideo:
            let outExt = readable ? (ext == "mp4" ? "mp4" : "mov") : ext
            let out = Output.file(for: url, suffix: " muted", ext: outExt)
            if readable {
                let composition = AVMutableComposition()
                try await insertTracks(of: asset, into: composition, at: .zero, includeAudio: false)
                try await export(composition, preset: AVAssetExportPresetPassthrough, to: out, type: fileType(for: outExt))
            } else {
                try await FFmpeg.run(input: url, output: out, args: ["-an", "-c:v", "copy"])
            }
            return out

        case .videoFrame:
            let out = Output.file(for: url, suffix: " frame", ext: "png")
            if readable {
                let duration = try await asset.load(.duration)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                let (image, _) = try await generator.image(at: CMTimeMultiplyByFloat64(duration, multiplier: 0.5))
                try ImageEngine.write(image, to: out, ext: "png", quality: 1, metadata: nil)
            } else {
                try await FFmpeg.run(input: url, output: out, args: ["-vf", "thumbnail", "-frames:v", "1"])
            }
            return out

        case .speedUp:
            let out = Output.file(for: url, suffix: " 2x", ext: readable ? "mov" : ext)
            if readable {
                let composition = AVMutableComposition()
                try await insertTracks(of: asset, into: composition, at: .zero, includeAudio: true)
                let duration = composition.duration
                composition.scaleTimeRange(CMTimeRange(start: .zero, duration: duration),
                                           toDuration: CMTimeMultiplyByFloat64(duration, multiplier: 0.5))
                try await export(composition, preset: AVAssetExportPresetHighestQuality, to: out, type: .mov,
                                 pitch: .spectral)
            } else {
                try await FFmpeg.run(input: url, output: out, args: [
                    "-filter_complex", "[0:v]setpts=0.5*PTS[v];[0:a]atempo=2.0[a]", "-map", "[v]", "-map", "[a]",
                ])
            }
            return out

        // Audio tools are filter graphs, so they always need ffmpeg.
        case .compressAudio:
            let outExt = ext == "mp3" ? "mp3" : "m4a"
            let out = Output.file(for: url, suffix: " compressed", ext: outExt)
            let codec = outExt == "mp3" ? ["-c:a", "libmp3lame"] : ["-c:a", "aac"]
            try await FFmpeg.run(input: url, output: out, args: ["-vn"] + codec + ["-b:a", "128k"])
            return out
        case .normalizeAudio:
            let out = Output.file(for: url, suffix: " normalized", ext: ext)
            try await FFmpeg.run(input: url, output: out, args: ["-vn", "-af", "loudnorm=I=-16:TP=-1.5:LRA=11"])
            return out
        case .monoAudio:
            let out = Output.file(for: url, suffix: " mono", ext: ext)
            try await FFmpeg.run(input: url, output: out, args: ["-vn", "-ac", "1"])
            return out
        case .trimSilence:
            let out = Output.file(for: url, suffix: " trimmed", ext: ext)
            try await FFmpeg.run(input: url, output: out, args: [
                "-vn", "-af",
                "silenceremove=start_periods=1:start_threshold=-50dB:stop_periods=-1:stop_duration=1:stop_threshold=-50dB",
            ])
            return out
        case .visualizeAudio:
            let out = Output.file(for: url, suffix: " waveform", ext: "mp4")
            try await FFmpeg.run(input: url, output: out, args: [
                "-filter_complex", "[0:a]showwaves=s=1280x720:mode=cline:colors=0xFF5A1F,format=yuv420p[v]",
                "-map", "[v]", "-map", "0:a", "-c:v", "libx264", "-c:a", "aac", "-b:a", "192k", "-shortest",
            ])
            return out

        default:
            throw ConvertError("Not a media tool")
        }
    }

    static func join(_ urls: [URL]) async throws -> URL {
        guard let first = urls.first else { throw ConvertError("Nothing to join") }
        guard urls.allSatisfy(appleReadable) else {
            throw ConvertError("Joining works with MP4, MOV and M4V files")
        }
        let composition = AVMutableComposition()
        for url in urls {
            try await insertTracks(of: AVURLAsset(url: url), into: composition, at: composition.duration, includeAudio: true)
        }
        let out = Output.file(for: first, suffix: " joined", ext: "mp4")
        try await export(composition, preset: AVAssetExportPresetHighestQuality, to: out, type: .mp4)
        return out
    }

    // MARK: AVFoundation helpers

    private static func export(_ asset: AVAsset, preset: String, to url: URL, type: AVFileType,
                               pitch: AVAudioTimePitchAlgorithm? = nil) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConvertError("This file can't be exported with AVFoundation")
        }
        session.outputURL = url
        session.outputFileType = type
        session.shouldOptimizeForNetworkUse = true
        if let pitch { session.audioTimePitchAlgorithm = pitch }
        await withCheckedContinuation { continuation in
            session.exportAsynchronously { continuation.resume() }
        }
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw ConvertError(session.error?.localizedDescription ?? "Export failed")
        }
    }

    private static func insertTracks(of asset: AVAsset, into composition: AVMutableComposition,
                                     at time: CMTime, includeAudio: Bool) async throws {
        let duration = try await asset.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        var types: [AVMediaType] = [.video]
        if includeAudio { types.append(.audio) }

        for type in types {
            guard let track = try await asset.loadTracks(withMediaType: type).first else { continue }
            // Reuse one composition track per media type so joined clips play back to back.
            let target = composition.tracks(withMediaType: type).first
                ?? composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)
            try target?.insertTimeRange(range, of: track, at: time)
            if type == .video { target?.preferredTransform = try await track.load(.preferredTransform) }
        }
    }

    private static func transcodePCM(_ url: URL, to out: URL, bigEndian: Bool) throws {
        let input = try AVAudioFile(forReading: url)
        let format = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: bigEndian,
        ]
        do {
            let output = try AVAudioFile(forWriting: out, settings: settings,
                                         commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768) else {
                throw ConvertError("Couldn't allocate an audio buffer")
            }
            while input.framePosition < input.length {
                try input.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
            }
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
    }

    /// Fallback GIF encoder for when ffmpeg isn't around.
    private static func videoToGIF(_ url: URL, output: URL) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let seconds = min(duration.seconds, 30)
        let fps = 12.0
        let frameCount = max(1, Int(seconds * fps))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let tolerance = CMTime(value: 1, timescale: 24)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, frameCount, nil)
        else { throw ConvertError("Couldn't create the GIF") }
        let loop = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        CGImageDestinationSetProperties(destination, loop as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary

        for index in 0..<frameCount {
            let (image, _) = try await generator.image(at: CMTime(seconds: Double(index) / fps, preferredTimescale: 600))
            CGImageDestinationAddImage(destination, image, frameProps)
        }
        guard CGImageDestinationFinalize(destination) else { throw ConvertError("Couldn't write the GIF") }
    }
}
