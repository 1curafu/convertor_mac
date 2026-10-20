import Foundation

/// Subtitles: SRT ↔ VTT, and plain text from either.
enum TextEngine {
    // MARK: Subtitles

    private struct Cue {
        var start: Double
        var end: Double
        var text: String
    }

    static func convertSubtitles(_ url: URL, to ext: String) throws -> URL {
        let cues = parseCues(try readText(url))
        guard !cues.isEmpty else { throw ConvertError("No subtitles found in \(url.lastPathComponent)") }

        let body: String
        switch ext {
        case "srt":
            body = cues.enumerated().map { index, cue in
                "\(index + 1)\n\(timestamp(cue.start, separator: ",")) --> \(timestamp(cue.end, separator: ","))\n\(cue.text)"
            }.joined(separator: "\n\n") + "\n"
        case "vtt":
            body = "WEBVTT\n\n" + cues.map { cue in
                "\(timestamp(cue.start, separator: ".")) --> \(timestamp(cue.end, separator: "."))\n\(cue.text)"
            }.joined(separator: "\n\n") + "\n"
        default:
            body = cues.map(\.text).joined(separator: "\n") + "\n"
        }
        let out = Output.file(for: url, ext: ext)
        try body.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    private static func parseCues(_ source: String) -> [Cue] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        return normalized.components(separatedBy: "\n\n").compactMap { block in
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let parts = lines[timing].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = seconds(parts[0]),
                  let end = seconds(parts[1].split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? "")
            else { return nil }
            let text = lines[(timing + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : Cue(start: start, end: end, text: text)
        }
    }

    /// UTF-8 or UTF-16 with a byte-order mark; older subtitle files are often Windows-1252 or Latin-1.
    private static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let bom = data.prefix(2) == Data([0xFF, 0xFE]) || data.prefix(2) == Data([0xFE, 0xFF])
        for encoding: String.Encoding in bom ? [.utf16] : [.utf8, .windowsCP1252, .isoLatin1] {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        throw ConvertError("Can't read the text of \(url.lastPathComponent)")
    }

    /// Accepts "01:02:03,456", "01:02:03.456" and "02:03.456".
    private static func seconds(_ raw: String) -> Double? {
        let fields = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
            .split(separator: ":")
            .compactMap { Double($0) }
        guard (2...3).contains(fields.count) else { return nil }
        return fields.reduce(0) { $0 * 60 + $1 }
    }

    private static func timestamp(_ value: Double, separator: String) -> String {
        let millis = Int((value * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d",
                      millis / 3_600_000, millis / 60_000 % 60, millis / 1000 % 60, separator, millis % 1000)
    }
}
