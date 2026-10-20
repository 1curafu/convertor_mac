import Foundation

/// Zip-based document packages (XLSX, PPTX, ODS, EPUB) built with the system `zip`/`ditto`.
enum ZipPackage {
    /// Writes `files` (path inside the archive → contents) to `output`.
    /// `storedFirst` names an entry that must come first and uncompressed (ODF/EPUB `mimetype`).
    static func write(_ files: [(path: String, data: Data)], to output: URL, storedFirst: String? = nil) async throws {
        let temp = try Output.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        for file in files {
            let url = temp.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: url)
        }
        try? FileManager.default.removeItem(at: output)
        do {
            if let storedFirst {
                try await Shell.run("/usr/bin/zip", ["-X", "-0", "-q", output.path, storedFirst], cwd: temp)
                try await Shell.run("/usr/bin/zip", ["-X", "-r", "-q", output.path, ".", "-x", storedFirst], cwd: temp)
            } else {
                try await Shell.run("/usr/bin/zip", ["-X", "-r", "-q", output.path, "."], cwd: temp)
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    /// Extracts a package into a fresh temp folder; the caller removes it.
    static func extract(_ url: URL) async throws -> URL {
        let temp = try Output.temporaryDirectory()
        do {
            try await Shell.run("/usr/bin/ditto", ["-x", "-k", url.path, temp.path])
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw ConvertError("\(url.lastPathComponent) isn't a valid package")
        }
        return temp
    }
}

extension String {
    var xmlEscaped: String {
        var result = ""
        result.reserveCapacity(count)
        for char in self {
            switch char {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default:
                // Drop control characters that are illegal in XML 1.0.
                if let scalar = char.unicodeScalars.first, scalar.value < 0x20, !"\t\n\r".contains(char) { continue }
                result.append(char)
            }
        }
        return result
    }

    var utf8Data: Data { Data(utf8) }
}

extension XMLNode {
    /// XPath that ignores namespaces: `//*[local-name()='name']`.
    func elements(_ localName: String, deep: Bool = true) -> [XMLElement] {
        ((try? nodes(forXPath: "\(deep ? ".//" : "./")*[local-name()='\(localName)']")) ?? []).compactMap { $0 as? XMLElement }
    }
}
