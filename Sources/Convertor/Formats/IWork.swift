import AppKit

/// Pages, Keynote and Numbers do the heavy lifting for Apple's own formats and for
/// layout-faithful Office rendering. They're driven through AppleScript (`osascript`), which
/// triggers a one-time "Convertor wants to control Pages" prompt. LibreOffice, when installed,
/// is the fallback for slides and spreadsheets.
enum IWork {
    enum App: String {
        case pages = "Pages", keynote = "Keynote", numbers = "Numbers"

        var bundleIDs: [String] {
            switch self {
            case .pages: return ["com.apple.iWork.Pages", "com.apple.Pages"]
            case .keynote: return ["com.apple.iWork.Keynote", "com.apple.Keynote"]
            case .numbers: return ["com.apple.iWork.Numbers", "com.apple.Numbers"]
            }
        }

        var isInstalled: Bool {
            bundleIDs.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        }
    }

    /// Export formats as named in each app's AppleScript dictionary.
    enum Format: String {
        case pdf = "PDF"
        case word = "Microsoft Word"
        case epub = "EPUB"
        case plainText = "unformatted text"
        case richText = "formatted text"
        case powerPoint = "Microsoft PowerPoint"
        case excel = "Microsoft Excel"
        case csv = "CSV"
    }

    /// Opens `input` in `app` and exports it to `output`.
    static func export(_ input: URL, with app: App, as format: Format, to output: URL) async throws {
        try await runScript(app: app, input: input, output: output, action: "export d to outFile as \(format.rawValue)")
    }

    /// Opens `input` (e.g. a .docx) in `app` and saves it in the app's native format.
    static func saveNative(_ input: URL, with app: App, to output: URL) async throws {
        try await runScript(app: app, input: input, output: output, action: "save d in outFile")
    }

    private static func runScript(app: App, input: URL, output: URL, action: String) async throws {
        guard app.isInstalled else {
            throw ConvertError("\(app.rawValue) is needed for this conversion. It's free on the Mac App Store.")
        }
        let script = """
        set inFile to POSIX file "\(escape(input.path))"
        set outFile to POSIX file "\(escape(output.path))"
        tell application "\(app.rawValue)"
            set d to open inFile
            \(action)
            close d saving no
        end tell
        """
        do {
            try await Shell.run("/usr/bin/osascript", ["-e", script])
        } catch {
            try? FileManager.default.removeItem(at: output)
            let message = error.localizedDescription
            if message.contains("-1743") || message.contains("Not authorized") {
                throw ConvertError("Allow Convertor to control \(app.rawValue) in System Settings → Privacy & Security → Automation.")
            }
            throw error
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw ConvertError("\(app.rawValue) didn't produce \(output.lastPathComponent)")
        }
    }

    private static func escape(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

enum LibreOffice {
    static var path: String? {
        let candidate = "/Applications/LibreOffice.app/Contents/MacOS/soffice"
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    /// `soffice --convert-to`, writing into a temp folder and moving the result to `output`.
    static func convert(_ input: URL, to filter: String, output: URL) async throws {
        guard let path else { throw ConvertError("LibreOffice isn't installed") }
        let temp = try Output.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        try await Shell.run(path, ["--headless", "--convert-to", filter, "--outdir", temp.path, input.path])
        guard let produced = try FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil).first else {
            throw ConvertError("LibreOffice didn't produce a file")
        }
        try FileManager.default.moveItem(at: produced, to: output)
    }
}
