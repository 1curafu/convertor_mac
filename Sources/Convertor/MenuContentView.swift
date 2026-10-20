import SwiftUI
import UniformTypeIdentifiers

/// The menu bar window: a drop zone fallback for the gesture plus recent results.
struct MenuContentView: View {
    /// Closes the menu bar panel holding this view.
    var close: () -> Void = {}
    @EnvironmentObject private var center: ConversionCenter
    @State private var dropped: [URL] = []
    @State private var mode: Mode = .convert
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(Color.tangerine).frame(width: 12, height: 12)
                Text("Convertor").font(.headline)
                Spacer()
                if !FFmpeg.isAvailable {
                    Text("Some formats unavailable")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("ffmpeg wasn't found, so formats Apple can't read or write (MKV, WebM, OGG, …) won't convert.")
                }
            }

            Text("Drag a file, tap ⇧ and drop it on a format.\n⌘ opens tools, ⌃ opens actions.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if dropped.isEmpty { dropZone } else { picker }

            if !center.jobs.isEmpty {
                Divider()
                Text("Recent").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(center.jobs.prefix(6)) { JobRow(job: $0) }
            }

            Divider()
            HStack {
                Button("Settings…") {
                    close()
                    SettingsWindow.show()
                }
                Spacer()
                Button("Quit Convertor") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 320)
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
            .foregroundStyle(targeted ? Color.tangerine : Color.secondary.opacity(0.5))
            .background(RoundedRectangle(cornerRadius: 12).fill(targeted ? Color.tangerine.opacity(0.08) : .clear))
            .frame(height: 80)
            .overlay {
                VStack(spacing: 4) {
                    Text("…or drop files here").font(.callout).foregroundStyle(.secondary)
                    Button("Choose Files…", action: chooseFiles).buttonStyle(.link).font(.callout)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        DispatchQueue.main.async { dropped.append(url) }
                    }
                }
                return true
            }
    }

    private func chooseFiles() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        dropped = panel.urls
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(dropped.count == 1 ? dropped[0].lastPathComponent : "\(dropped.count) files")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    dropped = []
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }

            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text("\($0.key) \($0.title)").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            let actions = Catalog.actions(for: dropped, mode: mode)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(actions) { action in
                    Button {
                        center.perform(action, on: dropped)
                    } label: {
                        VStack(spacing: 3) {
                            if !action.symbol.isEmpty { Image(systemName: action.symbol) }
                            Text(action.title).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                }
            }
            if actions.isEmpty {
                Text("Nothing here for these files.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct JobRow: View {
    let job: ConversionCenter.Job

    var body: some View {
        HStack(spacing: 8) {
            switch job.state {
            case .running:
                ProgressView().controlSize(.small).frame(width: 16)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).frame(width: 16)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(job.title).font(.caption).lineLimit(1).truncationMode(.middle)
                if case .failed(let message) = job.state {
                    Text(message).font(.caption2).foregroundStyle(.secondary).lineLimit(2).help(message)
                }
            }
            Spacer(minLength: 0)
            if case .done(let outputs) = job.state {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(outputs)
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            }
        }
    }
}
