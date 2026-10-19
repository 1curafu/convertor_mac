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
        if case .file(let fileAction) = action.kind {
            FileActions.perform(fileAction, on: urls)
            return
        }

        let name = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        let job = Job(title: "\(name) → \(action.title)", state: .running)
        jobs.insert(job, at: 0)
        if jobs.count > 30 { jobs.removeLast(jobs.count - 30) }

        Task {
            do {
                let outputs = try await Engine.perform(action, on: urls)
                update(job.id, .done(outputs))
                if Prefs.defaults.bool(forKey: Prefs.revealAfter) {
                    NSWorkspace.shared.activateFileViewerSelecting(outputs)
                }
                if Prefs.defaults.bool(forKey: Prefs.playSound) { NSSound(named: "Pop")?.play() }
            } catch {
                update(job.id, .failed(error.localizedDescription))
                NSSound.beep()
            }
        }
    }

    private func update(_ id: UUID, _ state: Job.State) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = state
    }
}
