import SwiftUI
import UniformTypeIdentifiers

/// The video picture (or a still for formats AVFoundation can't play), or a waveform icon for audio.
struct MediaPreview: View {
    @ObservedObject var session: MediaSession

    var body: some View {
        Group {
            if !session.loaded {
                LoadingStage()
            } else if session.info.hasVideo, let player = session.player {
                PlayerView(player: player).clipShape(RoundedRectangle(cornerRadius: 8))
            } else if session.info.hasVideo, let frame = session.frame {
                ImageStage(image: frame) { _ in EmptyView() }
                    .task(id: Int(session.playhead * 4)) { await session.refreshFrame() }
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: 80, weight: .light))
                    .foregroundStyle(Color.tangerine)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Preview, transport and timeline stacked, as every media editor uses them.
struct MediaStage<Overlay: View>: View {
    @ObservedObject var session: MediaSession
    var start: Binding<Double>?
    var end: Binding<Double>?
    @ViewBuilder var overlay: (_ x: @escaping (Double) -> CGFloat, _ width: CGFloat) -> Overlay

    var body: some View {
        VStack(spacing: 14) {
            MediaPreview(session: session)
            TransportBar(session: session, range: start.flatMap { s in end.map { s.wrappedValue...max(s.wrappedValue, $0.wrappedValue) } })
            Timeline(session: session, start: start, end: end, overlay: overlay)
                .frame(height: 64)
        }
        .padding(20)
    }
}

private func isVideo(_ url: URL) -> Bool { FileKind.of(url) == .video }

// MARK: - Trim

struct TrimEditor: View {
    let context: EditorContext
    @StateObject private var session: MediaSession
    @State private var start = 0.0
    @State private var end = 0.0
    @State private var removeSilence = false

    init(context: EditorContext) {
        self.context = context
        _session = StateObject(wrappedValue: MediaSession(url: context.url))
    }

    var body: some View {
        EditorScaffold(title: "Trim", context: context, canSave: session.loaded && end - start > 0.05, onSave: save) {
            MediaStage(session: session, start: $start, end: $end) { _, _ in EmptyView() }
        } controls: {
            ControlGroup("Selection") {
                LabeledContent("Start", value: timecode(start))
                LabeledContent("End", value: timecode(end))
                LabeledContent("Length", value: timecode(end - start))
                HStack {
                    Button("Start at playhead") { start = min(session.playhead, end - 0.1) }
                    Button("End at playhead") { end = max(session.playhead, start + 0.1) }
                }
                .controlSize(.small)
            }
            if !isVideo(context.url) {
                Toggle("Remove silence at the ends", isOn: $removeSilence)
                Text("Pauses inside the recording are kept.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task {
            await session.load(thumbnails: isVideo(context.url) ? 12 : 0, waveform: !isVideo(context.url), frame: session.player == nil)
            end = session.info.duration
        }
        .onDisappear { session.stop() }
    }

    private func save() {
        let url = context.url, start = start, end = end, silence = removeSilence
        context.save("Trim") { [try await MediaEdits.trim(url, start: start, end: end, removeSilence: silence)] }
    }
}

// MARK: - Bleep

struct BleepEditor: View {
    let context: EditorContext
    @StateObject private var session: MediaSession
    @State private var start = 0.0
    @State private var end = 1.0
    @State private var ranges: [ClosedRange<Double>] = []
    @State private var sound = MediaEdits.BleepSound.beep

    init(context: EditorContext) {
        self.context = context
        _session = StateObject(wrappedValue: MediaSession(url: context.url))
    }

    var body: some View {
        EditorScaffold(title: "Bleep", context: context, canSave: !ranges.isEmpty, onSave: save) {
            MediaStage(session: session, start: $start, end: $end) { x, _ in
                ForEach(ranges.indices, id: \.self) { index in
                    let range = ranges[index]
                    Rectangle()
                        .fill(Color.tangerine.opacity(0.5))
                        .overlay(Image(systemName: "waveform.badge.exclamationmark").foregroundStyle(.white))
                        .frame(width: max(3, x(range.upperBound) - x(range.lowerBound)))
                        .offset(x: x(range.lowerBound))
                        .allowsHitTesting(false)
                }
            }
        } controls: {
            ControlGroup("Mark") {
                Text("Drag the orange handles around a word, then add it.").font(.caption).foregroundStyle(.secondary)
                Button("Bleep \(timecode(start)) – \(timecode(end))") {
                    ranges.append(start...end)
                    ranges.sort { $0.lowerBound < $1.lowerBound }
                }
                .disabled(end - start < 0.05)
            }
            ControlGroup("Sound") {
                Picker("", selection: $sound) {
                    ForEach(MediaEdits.BleepSound.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ControlGroup("Ranges") {
                if ranges.isEmpty { Text("None yet").foregroundStyle(.secondary) }
                ForEach(ranges.indices, id: \.self) { index in
                    HStack {
                        Text("\(timecode(ranges[index].lowerBound)) – \(timecode(ranges[index].upperBound))").font(.callout.monospacedDigit())
                        Spacer()
                        Button { ranges.remove(at: index) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            }
        }
        .task {
            await session.load(waveform: true)
            end = min(1, session.info.duration)
        }
        .onDisappear { session.stop() }
    }

    private func save() {
        let url = context.url, ranges = ranges, sound = sound, duration = session.info.duration
        context.save("Bleep") { [try await MediaEdits.bleep(url, ranges: ranges, sound: sound, duration: duration)] }
    }
}

// MARK: - Split

struct SplitEditor: View {
    let context: EditorContext
    @StateObject private var session: MediaSession
    @State private var points: [Double] = []

    init(context: EditorContext) {
        self.context = context
        _session = StateObject(wrappedValue: MediaSession(url: context.url))
    }

    var body: some View {
        EditorScaffold(title: "Split", context: context, canSave: !points.isEmpty, onSave: save) {
            MediaStage(session: session) { x, _ in
                ForEach(points, id: \.self) { point in
                    Rectangle().fill(Color.tangerine).frame(width: 3).offset(x: x(point) - 1.5).allowsHitTesting(false)
                }
            }
        } controls: {
            ControlGroup("Split points") {
                Button("Split at \(timecode(session.playhead))") {
                    let point = session.playhead
                    guard point > 0.1, point < session.info.duration - 0.1, !points.contains(where: { abs($0 - point) < 0.1 }) else { return }
                    points.append(point)
                    points.sort()
                }
                ForEach(points, id: \.self) { point in
                    HStack {
                        Text(timecode(point)).font(.callout.monospacedDigit())
                        Spacer()
                        Button { points.removeAll { $0 == point } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
                Text("\(points.count + 1) clips will be saved in a new folder.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await session.load(thumbnails: 12, frame: session.player == nil) }
        .onDisappear { session.stop() }
    }

    private func save() {
        let url = context.url, points = points, duration = session.info.duration
        context.save("Split") { [try await MediaEdits.split(url, at: points, duration: duration)] }
    }
}

// MARK: - Snapshot

struct SnapshotEditor: View {
    let context: EditorContext
    @StateObject private var session: MediaSession
    @State private var folder: URL?
    @State private var saved = 0

    init(context: EditorContext) {
        self.context = context
        _session = StateObject(wrappedValue: MediaSession(url: context.url))
    }

    var body: some View {
        EditorScaffold(title: "Save Video Frames", context: context, saveTitle: "Done", onSave: { context.close() }) {
            MediaStage(session: session) { _, _ in EmptyView() }
        } controls: {
            ControlGroup("Snapshot") {
                Text("Scrub or step through frames, then save the ones you want as full-resolution PNGs.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Save frame at \(timecode(session.playhead))", action: snap)
                    .buttonStyle(.borderedProminent)
                    .tint(.tangerine)
                    .keyboardShortcut("s", modifiers: [])
                if saved > 0 {
                    Text("\(saved) saved").foregroundStyle(.secondary)
                    if let folder { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) } }
                }
            }
        }
        .task { await session.load(thumbnails: 12, frame: session.player == nil) }
        .onDisappear { session.stop() }
    }

    private func snap() {
        let url = context.url, time = session.playhead
        do {
            let target = try folder ?? Output.folder(for: url, suffix: " frames")
            folder = target
            saved += 1
            ConversionCenter.shared.run("\(url.lastPathComponent) → Frame \(timecode(time))") {
                [try await MediaEdits.snapshot(url, at: time, into: target)]
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

// MARK: - Crop / Redact video (work on a still frame)

struct FrameStage<Overlay: View>: View {
    @ObservedObject var session: MediaSession
    var start: Binding<Double>?
    var end: Binding<Double>?
    @ViewBuilder var overlay: (CGRect, CGImage) -> Overlay

    var body: some View {
        VStack(spacing: 14) {
            if let frame = session.frame {
                ImageStage(image: frame) { rect in overlay(rect, frame) }
            } else {
                LoadingStage()
            }
            Timeline(session: session, start: start, end: end) { _, _ in EmptyView() }
                .frame(height: 56)
        }
        .padding(20)
        .task(id: Int(session.playhead * 4)) { await session.refreshFrame() }
    }
}

struct CropVideoEditor: View {
    let context: EditorContext
    @StateObject private var session: MediaSession
    @State private var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var aspect = CropAspect.free

    init(context: EditorContext) {
        self.context = context
        _session = StateObject(wrappedValue: MediaSession(url: context.url))
    }

    private var pixelSize: CGSize {
        if session.info.width > 0 { return CGSize(width: session.info.width, height: session.info.height) }
        return session.frame.map { CGSize(width: $0.width, height: $0.height) } ?? CGSize(width: 16, height: 9)
    }

    var body: some View {
        EditorScaffold(title: "Crop Video", context: context, canSave: session.frame != nil, onSave: save) {
            FrameStage(session: session) { frame, _ in
                CropOverlay(rect: $rect, frame: frame, pixelSize: pixelSize, ratio: aspect.ratio(original: pixelSize))
            }
        } controls: {
            ControlGroup("Aspect ratio") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(CropAspect.allCases) { option in
                        Button(option.rawValue) { aspect = option }
                            .buttonStyle(.bordered)
                            .tint(aspect == option ? .tangerine : nil)
                    }
                }
            }
            ControlGroup("Output") {
                Text("\(Int(rect.width * pixelSize.width) / 2 * 2) × \(Int(rect.height * pixelSize.height) / 2 * 2) px")
                    .font(.callout.monospacedDigit())
                Text("Audio is kept.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await session.load(frame: true) }
        .onChange(of: aspect) { _, newValue in
            guard let ratio = newValue.ratio(original: pixelSize) else { return }
            let frameRatio = pixelSize.width / pixelSize.height
            let size = ratio > frameRatio ? CGSize(width: 1, height: frameRatio / ratio) : CGSize(width: ratio / frameRatio, height: 1)
            rect = CGRect(x: (1 - size.width) / 2, y: (1 - size.height) / 2, width: size.width, height: size.height)
        }
        .onDisappear { session.stop() }
    }

    private func save() {
        let url = context.url, rect = rect, size = pixelSize
        context.save("Crop") { [try await MediaEdits.crop(url, rect: rect, width: Int(size.width), height: Int(size.height))] }
    }
}

struct RedactVideoEditor: View {
    let context: EditorContext
    @StateObject private var session: MediaSession
    @State private var areas: [CGRect] = []
    @State private var style = MediaEdits.RedactStyle.blur
    @State private var wholeVideo = true
    @State private var start = 0.0
    @State private var end = 0.0

    init(context: EditorContext) {
        self.context = context
        _session = StateObject(wrappedValue: MediaSession(url: context.url))
    }

    var body: some View {
        EditorScaffold(title: "Redact Video", context: context, canSave: !areas.isEmpty, onSave: save) {
            FrameStage(session: session, start: wholeVideo ? nil : $start, end: wholeVideo ? nil : $end) { frame, _ in
                AreasOverlay(areas: $areas, frame: frame)
            }
        } controls: {
            ControlGroup("Areas") {
                Text("Drag on the frame to cover sensitive areas.").font(.caption).foregroundStyle(.secondary)
                Button("Remove all") { areas.removeAll() }.disabled(areas.isEmpty)
            }
            ControlGroup("Style") {
                Picker("", selection: $style) {
                    ForEach(MediaEdits.RedactStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ControlGroup("When") {
                Toggle("Entire video", isOn: $wholeVideo)
                if !wholeVideo {
                    Text("\(timecode(start)) – \(timecode(end))").font(.callout.monospacedDigit())
                    Text("Use the timeline handles to pick the part to cover.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task {
            await session.load(frame: true)
            end = session.info.duration
        }
        .onDisappear { session.stop() }
    }

    private func save() {
        let url = context.url, areas = areas, style = style
        let range: ClosedRange<Double>? = wholeVideo ? nil : start...end
        let width = session.info.width > 0 ? session.info.width : (session.frame?.width ?? 0)
        let height = session.info.height > 0 ? session.info.height : (session.frame?.height ?? 0)
        context.save("Redact") {
            [try await MediaEdits.redact(url, rects: areas, style: style, range: range, width: width, height: height)]
        }
    }
}

// MARK: - Speed

struct SpeedEditor: View {
    let context: EditorContext
    @StateObject private var session: MediaSession
    @State private var factor = 2.0
    private let options: [Double] = [0.25, 0.5, 0.75, 1.25, 1.5, 2, 3, 4]

    init(context: EditorContext) {
        self.context = context
        _session = StateObject(wrappedValue: MediaSession(url: context.url))
    }

    var body: some View {
        EditorScaffold(title: "Playback Speed", context: context, canSave: session.loaded, onSave: save) {
            MediaStage(session: session) { _, _ in EmptyView() }
        } controls: {
            ControlGroup("Speed") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(options, id: \.self) { option in
                        Button(label(option)) { factor = option }
                            .buttonStyle(.bordered)
                            .tint(factor == option ? .tangerine : nil)
                    }
                }
                Text("Audio keeps its pitch. Press play to preview at this speed.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await session.load(thumbnails: 12, frame: session.player == nil) }
        .onChange(of: factor) { _, newValue in session.setRate(Float(newValue)) }
        .onChange(of: session.isPlaying) { _, playing in if playing { session.setRate(Float(factor)) } }
        .onDisappear { session.stop() }
    }

    private func label(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))×" : "\(value)×"
    }

    private func save() {
        let urls = context.urls, factor = factor
        context.save("Speed \(label(factor))") {
            var outputs: [URL] = []
            for url in urls {
                let audio = await Media.probe(url).hasAudio
                outputs.append(try await MediaEdits.speed(url, factor: factor, hasAudio: audio))
            }
            return outputs
        }
    }
}

// MARK: - Visualize

struct VisualizeEditor: View {
    let context: EditorContext
    @StateObject private var session: MediaSession
    @State private var canvas = MediaEdits.Canvas.landscape
    @State private var style = MediaEdits.VisualStyle.waveform
    @State private var color = RGBA.tangerine
    @State private var image: URL?

    init(context: EditorContext) {
        self.context = context
        _session = StateObject(wrappedValue: MediaSession(url: context.url))
    }

    var body: some View {
        EditorScaffold(title: "Visualize Audio", context: context, canSave: style != .image || image != nil, onSave: save) {
            let size = canvas.size
            ZStack {
                Color.black
                if style == .image, let image, let picture = NSImage(contentsOf: image) {
                    Image(nsImage: picture).resizable().scaledToFit()
                } else {
                    Canvas { context, size in
                        let bars = session.waveform.isEmpty ? Array(repeating: Float(0.5), count: 120) : session.waveform
                        let count = style == .bars ? 48 : bars.count
                        let step = size.width / CGFloat(count)
                        for index in 0..<count {
                            let level = CGFloat(bars[index * bars.count / count])
                            let height = max(2, level * size.height * (style == .bars ? 0.8 : 0.6))
                            let y = style == .bars ? size.height - height : (size.height - height) / 2
                            let rect = CGRect(x: CGFloat(index) * step, y: y, width: max(1, step * 0.6), height: height)
                            context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(Color(cgColor: color.cgColor)))
                        }
                    }
                    .padding(24)
                }
            }
            .aspectRatio(CGFloat(size.0) / CGFloat(size.1), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(24)
        } controls: {
            ControlGroup("Format") {
                Picker("", selection: $canvas) {
                    ForEach(MediaEdits.Canvas.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ControlGroup("Style") {
                Picker("", selection: $style) {
                    ForEach(MediaEdits.VisualStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if style == .image {
                    Button(image == nil ? "Choose image…" : image!.lastPathComponent, action: chooseImage)
                } else {
                    ColorSwatches(selection: $color)
                }
            }
            Text("Creates an MP4 with your audio, ready for social posts.").font(.caption).foregroundStyle(.secondary)
        }
        .task { await session.load(waveform: true) }
        .onDisappear { session.stop() }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK { image = panel.url }
    }

    private func save() {
        let urls = context.urls, canvas = canvas, style = style, hex = color.hex, image = image
        context.save("Visualize") {
            var outputs: [URL] = []
            for url in urls { outputs.append(try await MediaEdits.visualize(url, canvas: canvas, style: style, color: hex, image: image)) }
            return outputs
        }
    }
}

// MARK: - Channels

struct ChannelsEditor: View {
    let context: EditorContext
    @State private var mono = true

    var body: some View {
        EditorScaffold(title: "Audio Channels", context: context, onSave: save) {
            HStack(spacing: 24) {
                choice("Mono", detail: "Both channels mixed into one.", symbol: "circle.fill", selected: mono) { mono = true }
                choice("Stereo", detail: "Mono is duplicated into left and right.", symbol: "circle.lefthalf.filled", selected: !mono) { mono = false }
            }
            .padding(40)
        } controls: {
            Text("Saves a copy with the chosen channel layout in the same format.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func choice(_ title: String, detail: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 40))
                Text(title).font(.title3.bold())
                Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(width: 200, height: 170)
            .background(RoundedRectangle(cornerRadius: 14).fill(selected ? Color.tangerine.opacity(0.15) : Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? Color.tangerine : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    private func save() {
        let urls = context.urls, mono = mono
        context.save(mono ? "Mono" : "Stereo") {
            var outputs: [URL] = []
            for url in urls { outputs.append(try await MediaEdits.channels(url, mono: mono)) }
            return outputs
        }
    }
}

// MARK: - Join

struct JoinEditor: View {
    let context: EditorContext
    @State private var order: [URL] = []
    @State private var thumbnails: [URL: CGImage] = [:]
    @State private var durations: [URL: Double] = [:]

    var body: some View {
        EditorScaffold(title: "Join Videos", context: context, canSave: order.count > 1, onSave: save) {
            List {
                ForEach(order, id: \.self) { url in
                    HStack(spacing: 12) {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                        Group {
                            if let thumb = thumbnails[url] {
                                Image(decorative: thumb, scale: 1).resizable().aspectRatio(contentMode: .fill)
                            } else {
                                Color.primary.opacity(0.1)
                            }
                        }
                        .frame(width: 96, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading) {
                            Text(url.lastPathComponent).lineLimit(1)
                            Text(timecode(durations[url] ?? 0)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onMove { order.move(fromOffsets: $0, toOffset: $1) }
            }
            .padding(12)
        } controls: {
            Text("Drag clips to change the playback order. Every clip is scaled to the first one's frame size and saved as one MP4.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task {
            order = context.urls
            for url in context.urls {
                let info = await Media.probe(url)
                durations[url] = info.duration
                thumbnails[url] = await Media.frame(url, at: min(1, info.duration / 2), maxSize: 240)
            }
        }
    }

    private func save() {
        let order = order
        context.save("Join") { [try await MediaEdits.join(order)] }
    }
}
