import AppKit

/// Runs actions picked on the wheel and keeps a short history for the menu bar.
@MainActor
final class ConversionCenter: ObservableObject {
    static let shared = ConversionCenter()

    struct Job: Identifiable {
        enum State {
            case running
            case done([URL])
            case failed(String)
        }

        let id = UUID()
        let title: String
        var state: State
    }

    @Published private(set) var jobs: [Job] = []

    func perform(_ action: Action, on urls: [URL]) {
        guard !urls.isEmpty else { return }
        switch action.kind {
        case .file(let fileAction):
            FileActions.perform(fileAction, on: urls)
        case .tool(let tool) where tool.needsEditor(for: FileKind.common(urls)):
            // Let the drag session end before a window takes focus.
            Task { @MainActor in Editors.open(tool, title: action.title, urls: urls) }
        default:
            let name = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
            run("\(name) → \(action.title)") { try await Engine.perform(action, on: urls) }
        }
    }

    /// Runs work in the background as a job in the menu bar history. `reveal: false` skips
    /// "Reveal results in Finder" for jobs fired in quick succession (saving video frames).
    func run(_ title: String, reveal: Bool = true, completion: @escaping (Bool) -> Void = { _ in },
             _ work: @escaping () async throws -> [URL]) {
        let job = Job(title: title, state: .running)
        jobs.insert(job, at: 0)
        if jobs.count > 30 { jobs.removeLast(jobs.count - 30) }

        Task {
            do {
                let outputs = try await work()
                update(job.id, .done(outputs))
                completion(true)
                if reveal, Prefs.defaults.bool(forKey: Prefs.revealAfter) {
                    NSWorkspace.shared.activateFileViewerSelecting(outputs)
                }
                if Prefs.defaults.bool(forKey: Prefs.playSound) { NSSound(named: "Pop")?.play() }
            } catch {
                update(job.id, .failed(error.localizedDescription))
                completion(false)
                NSSound.beep()
            }
        }
    }

    private func update(_ id: UUID, _ state: Job.State) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = state
    }
}
