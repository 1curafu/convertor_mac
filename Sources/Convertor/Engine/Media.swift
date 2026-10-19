import AVFoundation
import ImageIO

/// Inspection helpers shared by the media editors: duration, streams, frames, waveforms.
/// AVFoundation is used for formats it can read; ffmpeg for the rest (MKV, WebM, OGG, …).
enum Media {
    struct Info {
        var duration: Double = 0
        var hasVideo = false
        var hasAudio = false
        var width = 0
        var height = 0
    }

    static func isAppleReadable(_ url: URL) -> Bool { MediaEngine.appleReadable(url) }

    static func probe(_ url: URL) async -> Info {
        var info = Info()
        if isAppleReadable(url) {
            let asset = AVURLAsset(url: url)
            info.duration = (try? await asset.load(.duration).seconds) ?? 0
            if let video = try? await asset.loadTracks(withMediaType: .video).first {
                info.hasVideo = true
                let size = (try? await video.load(.naturalSize)) ?? .zero
                let transform = (try? await video.load(.preferredTransform)) ?? .identity
                let rotated = size.applying(transform)
                info.width = Int(abs(rotated.width))
                info.height = Int(abs(rotated.height))
            }
            info.hasAudio = !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty
            if info.duration > 0 { return info }
        }

        // `ffmpeg -i` with no output prints the stream summary to stderr.
        guard let ffmpeg = FFmpeg.path,
              let result = try? await Shell.capture(ffmpeg, ["-hide_banner", "-i", url.path])
        else { return info }
        let text = result.errorText
        if let match = text.firstMatch(of: #/Duration: (\d+):(\d+):(\d+(?:\.\d+)?)/#) {
            info.duration = (Double(match.1) ?? 0) * 3600 + (Double(match.2) ?? 0) * 60 + (Double(match.3) ?? 0)
        }
        for line in text.split(separator: "\n") where line.contains("Stream #") {
            if line.contains("Video:") {
                info.hasVideo = true
                if let size = line.firstMatch(of: #/, (\d{2,5})x(\d{2,5})/#) {
                    info.width = Int(size.1) ?? 0
                    info.height = Int(size.2) ?? 0
                }
            }
            if line.contains("Audio:") { info.hasAudio = true }
        }
        return info
    }

    /// Peak levels (0…1) in `buckets` slices, for drawing a waveform.
    static func waveform(_ url: URL, buckets: Int = 400) async -> [Float] {
        guard let ffmpeg = FFmpeg.path,
              let result = try? await Shell.capture(ffmpeg, [
                  "-hide_banner", "-loglevel", "error", "-i", url.path,
                  "-vn", "-ac", "1", "-ar", "2000", "-f", "f32le", "-",
              ]),
              result.status == 0
        else { return [] }

        var samples = [Float](repeating: 0, count: result.output.count / MemoryLayout<Float>.size)
        _ = samples.withUnsafeMutableBytes { result.output.copyBytes(to: $0) }
        guard !samples.isEmpty else { return [] }
        let size = max(1, samples.count / buckets)
        var peaks: [Float] = stride(from: 0, to: samples.count, by: size).map { start in
            samples[start..<min(start + size, samples.count)].reduce(0) { max($0, abs($1)) }
        }
        let loudest = peaks.max() ?? 1
        if loudest > 0 { peaks = peaks.map { $0 / loudest } }
        return peaks
    }

    /// One full-resolution frame at `time` seconds.
    static func frame(_ url: URL, at time: Double, maxSize: CGFloat? = nil) async -> CGImage? {
        if isAppleReadable(url) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            if let maxSize { generator.maximumSize = CGSize(width: maxSize, height: maxSize) }
            if let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image {
                return image
            }
        }
        guard let ffmpeg = FFmpeg.path else { return nil }
        var args = ["-hide_banner", "-loglevel", "error", "-ss", String(format: "%.3f", time), "-i", url.path, "-frames:v", "1"]
        if let maxSize { args += ["-vf", "scale='min(\(Int(maxSize)),iw)':-2"] }
        args += ["-f", "image2pipe", "-vcodec", "png", "-"]
        guard let result = try? await Shell.capture(ffmpeg, args), result.status == 0,
              let source = CGImageSourceCreateWithData(result.output as CFData, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Evenly spaced small frames for a timeline strip.
    static func thumbnails(_ url: URL, count: Int, duration: Double) async -> [CGImage] {
        guard duration > 0 else { return [] }
        var images: [CGImage] = []
        for index in 0..<count {
            let time = duration * (Double(index) + 0.5) / Double(count)
            if let image = await frame(url, at: time, maxSize: 240) { images.append(image) }
        }
        return images
    }
}
