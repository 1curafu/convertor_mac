import Foundation

struct ConvertError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Decides where results are written and keeps names from colliding.
enum Output {
    static func directory(for source: URL) -> URL {
        let fm = FileManager.default
        switch Prefs.defaults.string(forKey: Prefs.outputLocation) {
        case "downloads":
            if let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first { return downloads }
        case "custom":
            let path = Prefs.defaults.string(forKey: Prefs.customFolder) ?? ""
            var isDir: ObjCBool = false
            if !path.isEmpty, fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        default:
            break
        }
        return source.deletingLastPathComponent()
    }

    /// File name without its extension; "x.tar.gz" becomes "x".
    static func baseName(_ url: URL) -> String {
        let name = url.lastPathComponent
        if name.lowercased().hasSuffix(".tar.gz") { return String(name.dropLast(7)) }
        return url.deletingPathExtension().lastPathComponent
    }

    /// A free file URL next to `source` (or in the configured folder).
    static func file(for source: URL, suffix: String = "", ext: String) -> URL {
        unique(directory(for: source), name: baseName(source) + suffix, ext: ext)
    }

    /// A newly created, empty folder for multi-file results.
    static func folder(for source: URL, suffix: String) throws -> URL {
        let url = unique(directory(for: source), name: baseName(source) + suffix, ext: nil)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func unique(_ dir: URL, name: String, ext: String?) -> URL {
        func make(_ n: String) -> URL {
            dir.appendingPathComponent(ext.map { "\(n).\($0)" } ?? n)
        }
        var candidate = make(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = make("\(name) \(counter)")
            counter += 1
        }
        return candidate
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Convertor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

enum Shell {
    /// Runs a command line tool. stderr goes to a temp file (a pipe could fill up and stall
    /// long ffmpeg runs) and its tail becomes the error message on failure.
    static func run(_ executable: String, _ arguments: [String], cwd: URL? = nil, stdout: URL? = nil) async throws {
        let errURL = FileManager.default.temporaryDirectory.appendingPathComponent("convertor-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        process.standardInput = FileHandle.nullDevice
        process.standardError = try FileHandle(forWritingTo: errURL)
        if let stdout {
            FileManager.default.createFile(atPath: stdout.path, contents: nil)
            process.standardOutput = try FileHandle(forWritingTo: stdout)
        } else {
            process.standardOutput = FileHandle.nullDevice
        }

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }

        guard status == 0 else {
            let log = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
            let tail = log.split(separator: "\n").suffix(3).joined(separator: "\n")
            let tool = URL(fileURLWithPath: executable).lastPathComponent
            throw ConvertError(tail.isEmpty ? "\(tool) failed (exit \(status))" : "\(tool): \(tail)")
        }
    }
}
