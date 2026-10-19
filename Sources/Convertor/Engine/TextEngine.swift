import Foundation

/// Plain-text formats: subtitles (SRT/VTT) and delimited tables (CSV/TSV).
enum TextEngine {
    // MARK: Subtitles

    private struct Cue {
        var start: Double
        var end: Double
        var text: String
    }

    static func convertSubtitles(_ url: URL, to ext: String) throws -> URL {
        let cues = parseCues(try String(contentsOf: url, encoding: .utf8))
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

    // MARK: Tables

    static func convertTable(_ url: URL, to ext: String) throws -> URL {
        let source = try String(contentsOf: url, encoding: .utf8)
        let rows = parse(source, delimiter: Catalog.normalize(url) == "tsv" ? "\t" : ",")
        let delimiter: Character = ext == "tsv" ? "\t" : ","
        let body = rows.map { row in
            row.map { escape($0, delimiter: delimiter) }.joined(separator: String(delimiter))
        }.joined(separator: "\n") + "\n"
        let out = Output.file(for: url, ext: ext)
        try body.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    /// RFC 4180 style parser: quoted fields may contain delimiters, quotes ("") and newlines.
    private static func parse(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = text.makeIterator()

        func handle(_ char: Character) {
            switch char {
            case "\"" where field.isEmpty: quoted = true
            case delimiter: row.append(field); field = ""
            case "\n", "\r\n": row.append(field); rows.append(row); row = []; field = ""
            case "\r": break
            default: field.append(char)
            }
        }

        while let char = iterator.next() {
            if quoted {
                if char == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else {
                            quoted = false
                            handle(next)
                        }
                    } else { quoted = false }
                } else { field.append(char) }
            } else {
                handle(char)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    private static func escape(_ field: String, delimiter: Character) -> String {
        if delimiter == "\t" {
            // TSV has no quoting, so flatten anything that would break the layout.
            return field.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        }
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
