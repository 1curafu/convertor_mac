import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage(Prefs.gestureEnabled) private var gestureEnabled = true
    @AppStorage(Prefs.outputLocation) private var outputLocation = "beside"
    @AppStorage(Prefs.customFolder) private var customFolder = ""
    @AppStorage(Prefs.imageQuality) private var imageQuality = 0.9
    @AppStorage(Prefs.compressQuality) private var compressQuality = 0.6
    @AppStorage(Prefs.revealAfter) private var revealAfter = false
    @AppStorage(Prefs.playSound) private var playSound = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Gesture") {
                Toggle("Open the wheel while dragging files", isOn: $gestureEnabled)
                Text("While dragging, tap ⇧ for formats, ⌘ for tools or ⌃ for actions, then drop on a segment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Output") {
                Picker("Save results", selection: $outputLocation) {
                    Text("Next to the original").tag("beside")
                    Text("Downloads").tag("downloads")
                    Text("Custom folder").tag("custom")
                }
                if outputLocation == "custom" {
                    HStack {
                        Text(customFolder.isEmpty ? "No folder chosen" : customFolder)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Toggle("Reveal results in Finder", isOn: $revealAfter)
                Toggle("Play a sound when done", isOn: $playSound)
            }

            Section("Quality") {
                LabeledContent("Image quality") {
                    Slider(value: $imageQuality, in: 0.5...1) { Text("\(Int(imageQuality * 100))%") }
                }
                LabeledContent("Compression quality") {
                    Slider(value: $compressQuality, in: 0.2...0.9) { Text("\(Int(compressQuality * 100))%") }
                }
            }

            Section("System") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            NSAlert(error: error).runModal()
                        }
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                ))
                LabeledContent("ffmpeg") {
                    Text(FFmpeg.path ?? "Not found – run scripts/build_app.sh or brew install ffmpeg")
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { customFolder = url.path }
    }
}
