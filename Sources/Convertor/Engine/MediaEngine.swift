import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Video and audio. AVFoundation handles what it can read and write; ffmpeg covers the rest.
enum MediaEngine {
    static let appleVideoInputs: Set<String> = ["mp4", "mov", "m4v"]
    static let appleAudioInputs: Set<String> = ["m4a", "wav", "aiff", "caf", "mp3", "aac"]

    static func appleReadable(_ url: URL) -> Bool {
        let ext = Catalog.normalize(url)
        return appleVideoInputs.contains(ext) || appleAudioInputs.contains(ext)
    }

    static func fileType(for ext: String) -> AVFileType {
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

    // MARK: One-tap tools

    static func compress(_ url: URL) async throws -> URL {
        let ext = Catalog.normalize(url)
        if FileKind.of(url) == .audio {
            let outExt = ext == "mp3" ? "mp3" : "m4a"
            let out = Output.file(for: url, suffix: " compressed", ext: outExt)
            let codec = outExt == "mp3" ? ["-c:a", "libmp3lame"] : ["-c:a", "aac"]
            try await FFmpeg.run(input: url, output: out, args: ["-vn"] + codec + ["-b:a", "128k"])
            return out
        }
        let out = Output.file(for: url, suffix: " compressed", ext: "mp4")
        if FFmpeg.isAvailable {
            try await FFmpeg.run(input: url, output: out, args: [
                "-c:v", "libx264", "-crf", "28", "-preset", "slow", "-pix_fmt", "yuv420p",
                "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart",
            ])
        } else {
            try await export(AVURLAsset(url: url), preset: AVAssetExportPresetHEVCHighestQuality, to: out, type: .mp4)
        }
        return out
    }

    static func mute(_ url: URL) async throws -> URL {
        let ext = Catalog.normalize(url)
        let out = Output.file(for: url, suffix: " muted", ext: ext)
        if appleReadable(url) && !FFmpeg.isAvailable {
            let composition = AVMutableComposition()
            try await insertTracks(of: AVURLAsset(url: url), into: composition, at: .zero, includeAudio: false)
            try await export(composition, preset: AVAssetExportPresetPassthrough, to: out, type: fileType(for: ext))
        } else {
            try await FFmpeg.run(input: url, output: out, args: ["-map", "0:v", "-c", "copy", "-an"])
        }
        return out
    }

    static func normalize(_ url: URL) async throws -> URL {
        let ext = Catalog.normalize(url)
        let out = Output.file(for: url, suffix: " normalized", ext: ext)
        try await FFmpeg.run(input: url, output: out, args: ["-vn", "-af", "loudnorm=I=-16:TP=-1.5:LRA=11"] + audioCodec(for: ext))
        return out
    }

    /// Audio encoder flags for writing `ext`, without the video/stream flags `FFmpeg.arguments` adds.
    static func audioCodec(for ext: String) -> [String] {
        FFmpeg.arguments(for: ext).filter { $0 != "-vn" }
    }

    // MARK: AVFoundation helpers

    static func export(_ asset: AVAsset, preset: String, to url: URL, type: AVFileType,
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

    static func insertTracks(of asset: AVAsset, into composition: AVMutableComposition,
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
