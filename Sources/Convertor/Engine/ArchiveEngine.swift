import Foundation

/// ZIP / TAR / GZIP via the archivers that ship with macOS (ditto, zip, bsdtar, gunzip).
/// bsdtar also reads RAR, which covers "RAR input only".
enum ArchiveEngine {
    static func isArchive(_ url: URL) -> Bool { FileKind.of(url) == .archive }

    /// Packs files or folders into `ext` ("zip", "tar" or "tar.gz").
    /// A single archive is repacked: extracted to a temp folder, then archived again.
    static func pack(_ urls: [URL], as ext: String) async throws -> URL {
        guard let first = urls.first else { throw ConvertError("Nothing to archive") }

        if urls.count == 1, isArchive(first) {
            let temp = try Output.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: temp) }
            try await extract(first, into: temp)
            let items = try FileManager.default.contentsOfDirectory(atPath: temp.path)
            let out = Output.file(for: first, ext: ext)
            try await archive(items, in: temp, to: out, ext: ext)
            return out
        }

        let out = urls.count == 1
            ? Output.file(for: first, ext: ext)
            : Output.unique(Output.directory(for: first), name: "Archive", ext: ext)

        // Items are passed relative to one folder so the archive has no absolute paths.
        // A selection spanning several folders (search results, Recents) is gathered into one first.
        let parents = Set(urls.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        if parents.count == 1 {
            try await archive(urls.map(\.lastPathComponent), in: first.deletingLastPathComponent(), to: out, ext: ext)
        } else {
            let staging = try Output.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: staging) }
            var names: [String] = []
            for url in urls {
                let fileExt = url.pathExtension
                let name = fileExt.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
                let target = Output.unique(staging, name: name, ext: fileExt.isEmpty ? nil : fileExt)
                try FileManager.default.copyItem(at: url, to: target)
                names.append(target.lastPathComponent)
            }
            try await archive(names, in: staging, to: out, ext: ext)
        }
        return out
    }

    static func extract(_ url: URL) async throws -> URL {
        let folder = try Output.folder(for: url, suffix: "")
        do {
            try await extract(url, into: folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return folder
    }

    private static func extract(_ url: URL, into folder: URL) async throws {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".zip") {
            try await Shell.run("/usr/bin/ditto", ["-x", "-k", url.path, folder.path])
        } else if name.hasSuffix(".gz") && !name.hasSuffix(".tar.gz") {
            // A lone gzipped file, not a tarball.
            let out = folder.appendingPathComponent(String(url.lastPathComponent.dropLast(3)))
            try await Shell.run("/usr/bin/gunzip", ["-c", url.path], stdout: out)
        } else {
            try await Shell.run("/usr/bin/tar", ["-xf", url.path, "-C", folder.path])
        }
    }

    private static func archive(_ items: [String], in directory: URL, to out: URL, ext: String) async throws {
        // A name like "-v.txt" would be read as an option.
        let items = items.map { $0.hasPrefix("-") ? "./" + $0 : $0 }
        do {
            switch ext {
            case "zip":
                try await Shell.run("/usr/bin/zip", ["-r", "-y", "-q", out.path] + items + ["-x", "*.DS_Store"], cwd: directory)
            case "tar":
                try await Shell.run("/usr/bin/tar", ["-cf", out.path, "-C", directory.path] + items)
            default:
                try await Shell.run("/usr/bin/tar", ["-czf", out.path, "-C", directory.path] + items)
            }
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        guard FileManager.default.fileExists(atPath: out.path) else { throw ConvertError("Couldn't create the archive") }
    }
}
