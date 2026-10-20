import AVFoundation
import AVKit
import SwiftUI

// MARK: - Window host

/// Shared by every editor: the files it works on, and a way to hand work to the job list.
@MainActor
final class EditorContext {
    let urls: [URL]
    var close: () -> Void = {}

    init(urls: [URL]) { self.urls = urls }

    var url: URL { urls[0] }

    /// Starts `work` as a background job and closes the editor.
    func save(_ title: String, _ work: @escaping () async throws -> [URL]) {
        let name = urls.count == 1 ? url.lastPathComponent : "\(urls.count) files"
        ConversionCenter.shared.run("\(name) → \(title)", work)
        close()
    }
}

// MARK: - Scaffold

/// Editor chrome: header, preview area, a controls column and Cancel/Save.
struct EditorScaffold<Main: View, Controls: View>: View {
    let title: String
    let context: EditorContext
    var saveTitle = "Save"
    var canSave = true
    var showsCancel = true
    let onSave: () -> Void
    @ViewBuilder let main: () -> Main
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(Color.tangerine).frame(width: 10, height: 10)
                Text(title).font(.headline)
                Text(context.urls.count == 1 ? context.url.lastPathComponent : "\(context.urls.count) files")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            // In the title bar, beside the traffic lights, instead of a row of its own below them.
            .padding(.leading, 84)
            .padding(.trailing, 18)
            .frame(height: 32)

            Divider()
            HStack(spacing: 0) {
                main()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.035))
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) { controls() }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 270)
            }
            Divider()
            HStack {
                Text("\(Output.destinationSummary). The original is never changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if showsCancel {
                    Button("Cancel") { context.close() }
                        .keyboardShortcut(.cancelAction)
                }
                Button(saveTitle, action: onSave)
                    .buttonStyle(.borderedProminent)
                    .tint(.tangerineDeep)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(14)
        }
        .frame(minWidth: 860, minHeight: 600)
        .ignoresSafeArea(edges: .top)
    }
}

/// A titled group in the controls column.
struct ControlGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

/// One choice in a grid of options. The selected one is filled in a deeper tangerine with white
/// text (AA contrast), drawn by hand so it shows even when the window isn't active.
struct OptionButton<Label: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action, label: label).buttonStyle(OptionStyle(selected: selected))
    }

    private struct OptionStyle: ButtonStyle {
        let selected: Bool

        func makeBody(configuration: Configuration) -> some View {
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            configuration.label
                .font(.callout.weight(selected ? .semibold : .regular))
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(shape.fill(selected ? Color.tangerineDeep : Color.primary.opacity(configuration.isPressed ? 0.16 : 0.08)))
                .contentShape(shape)
        }
    }
}

/// A labelled slider with its value.
struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(format(value)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}

struct ColorSwatches: View {
    @Binding var selection: RGBA

    var body: some View {
        HStack(spacing: 6) {
            ForEach(RGBA.palette, id: \.self) { color in
                Circle()
                    .fill(Color(cgColor: color.cgColor))
                    .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 0.5))
                    .overlay(Circle().stroke(Color.tangerine, lineWidth: selection == color ? 2.5 : 0).padding(-3))
                    .frame(width: 20, height: 20)
                    .onTapGesture { selection = color }
            }
            ColorPicker("", selection: Binding(
                get: { Color(cgColor: selection.cgColor) },
                set: { selection = RGBA(NSColor($0).cgColor) }
            ))
            .labelsHidden()
        }
    }
}

// MARK: - Image stage

/// An image scaled to fit, with an overlay that receives the image's on-screen frame.
struct ImageStage<Overlay: View>: View {
    let image: CGImage
    @ViewBuilder let overlay: (CGRect) -> Overlay

    var body: some View {
        GeometryReader { geometry in
            let frame = Self.fit(CGSize(width: image.width, height: image.height), in: geometry.size, padding: 24)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
                    .position(x: frame.midX, y: frame.midY)
                overlay(frame)
            }
            .coordinateSpace(.named("stage"))
        }
    }

    static func fit(_ size: CGSize, in bounds: CGSize, padding: CGFloat) -> CGRect {
        let available = CGSize(width: max(1, bounds.width - padding * 2), height: max(1, bounds.height - padding * 2))
        let scale = min(available.width / max(size.width, 1), available.height / max(size.height, 1))
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: (bounds.width - fitted.width) / 2, y: (bounds.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }
}

extension CGRect {
    /// Converts a normalised rect (0…1) into this frame's coordinates.
    func denormalize(_ rect: CGRect) -> CGRect {
        CGRect(x: minX + rect.minX * width, y: minY + rect.minY * height, width: rect.width * width, height: rect.height * height)
    }

    /// Converts a point in this frame to normalised (0…1) coordinates, clamped.
    func normalize(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max((point.x - minX) / max(width, 1), 0), 1), y: min(max((point.y - minY) / max(height, 1), 0), 1))
    }
}

/// Aspect ratios offered by the croppers.
enum CropAspect: String, CaseIterable, Identifiable {
    case free = "Free", original = "Original", square = "1:1", fourThree = "4:3", threeTwo = "3:2",
         sixteenNine = "16:9", nineSixteen = "9:16", fourFive = "4:5"
    var id: String { rawValue }

    /// Width / height in pixels, or nil for free-form.
    func ratio(original: CGSize) -> CGFloat? {
        switch self {
        case .free: return nil
        case .original: return original.width / max(original.height, 1)
        case .square: return 1
        case .fourThree: return 4.0 / 3
        case .threeTwo: return 3.0 / 2
        case .sixteenNine: return 16.0 / 9
        case .nineSixteen: return 9.0 / 16
        case .fourFive: return 4.0 / 5
        }
    }
}

/// A draggable crop rectangle with corner and edge handles over an `ImageStage`.
struct CropOverlay: View {
    @Binding var rect: CGRect           // normalised
    let frame: CGRect                   // image frame on screen
    let pixelSize: CGSize
    let ratio: CGFloat?

    @State private var dragStart: CGRect?

    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
        var moves: (left: Bool, top: Bool, right: Bool, bottom: Bool) {
            switch self {
            case .topLeft: return (true, true, false, false)
            case .top: return (false, true, false, false)
            case .topRight: return (false, true, true, false)
            case .right: return (false, false, true, false)
            case .bottomRight: return (false, false, true, true)
            case .bottom: return (false, false, false, true)
            case .bottomLeft: return (true, false, false, true)
            case .left: return (true, false, false, false)
            }
        }
        func point(in r: CGRect) -> CGPoint {
            switch self {
            case .topLeft: return CGPoint(x: r.minX, y: r.minY)
            case .top: return CGPoint(x: r.midX, y: r.minY)
            case .topRight: return CGPoint(x: r.maxX, y: r.minY)
            case .right: return CGPoint(x: r.maxX, y: r.midY)
            case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
            case .bottom: return CGPoint(x: r.midX, y: r.maxY)
            case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
            case .left: return CGPoint(x: r.minX, y: r.midY)
            }
        }
    }

    var body: some View {
        let box = frame.denormalize(rect)
        ZStack(alignment: .topLeading) {
            // Dim everything outside the crop.
            Path { path in
                path.addRect(frame)
                path.addRect(box)
            }
            .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(Color.white, lineWidth: 1.5)
                .background(Color.white.opacity(0.001))
                .overlay(thirds)
                .frame(width: box.width, height: box.height)
                .position(x: box.midX, y: box.midY)
                .gesture(DragGesture().onChanged { value in
                    let start = dragStart ?? rect
                    dragStart = start
                    var moved = start.offsetBy(dx: value.translation.width / frame.width, dy: value.translation.height / frame.height)
                    moved.origin.x = min(max(moved.minX, 0), 1 - moved.width)
                    moved.origin.y = min(max(moved.minY, 0), 1 - moved.height)
                    rect = moved
                }.onEnded { _ in dragStart = nil })

            ForEach(Handle.allCases, id: \.self) { handle in
                let point = handle.point(in: box)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white)
                    .shadow(radius: 1)
                    .frame(width: 12, height: 12)
                    .position(point)
                    .gesture(DragGesture().onChanged { value in
                        let start = dragStart ?? rect
                        dragStart = start
                        rect = resize(start, handle: handle, by: value.translation)
                    }.onEnded { _ in dragStart = nil })
            }
        }
    }

    private var thirds: some View {
        GeometryReader { geometry in
            Path { path in
                for i in 1...2 {
                    let x = geometry.size.width * CGFloat(i) / 3, y = geometry.size.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.4), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }

    private func resize(_ start: CGRect, handle: Handle, by translation: CGSize) -> CGRect {
        let dx = translation.width / frame.width, dy = translation.height / frame.height
        let minimum: CGFloat = 0.03
        var left = start.minX, top = start.minY, right = start.maxX, bottom = start.maxY
        let moves = handle.moves
        if moves.left { left = min(max(0, left + dx), right - minimum) }
        if moves.right { right = max(min(1, right + dx), left + minimum) }
        if moves.top { top = min(max(0, top + dy), bottom - minimum) }
        if moves.bottom { bottom = max(min(1, bottom + dy), top + minimum) }

        if let ratio, !moves.left && !moves.right {
            // Top or bottom edge: the height leads and the width follows, centred where it was.
            let pixelRatio = ratio * pixelSize.height / pixelSize.width
            var height = bottom - top
            let width = min(1, height * pixelRatio)
            height = width / pixelRatio
            if moves.top { top = bottom - height } else { bottom = top + height }
            let middle = min(max(start.midX, width / 2), 1 - width / 2)
            left = middle - width / 2
            right = middle + width / 2
        } else if let ratio {
            // Normalised height that gives the requested pixel aspect for this width.
            let width = right - left
            var height = width * pixelSize.width / (ratio * pixelSize.height)
            if moves.top && !moves.bottom {
                height = min(height, bottom)
                top = bottom - height
            } else {
                height = min(height, 1 - top)
                bottom = top + height
            }
            // If the height hit an edge, shrink the width to keep the ratio.
            let fittedWidth = height * ratio * pixelSize.height / pixelSize.width
            if moves.left { left = right - fittedWidth } else { right = left + fittedWidth }
        }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

/// Covers drawn by dragging; click an area's × to remove it. Used by the redactors.
struct AreasOverlay: View {
    @Binding var areas: [CGRect]        // normalised
    let frame: CGRect
    var tint: Color = .tangerine

    @State private var drawing: CGRect?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white.opacity(0.001)
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("areas")).onChanged { value in
                    drawing = CGRect(from: frame.normalize(value.startLocation), to: frame.normalize(value.location))
                }.onEnded { _ in
                    if let drawing, drawing.width > 0.005, drawing.height > 0.005 { areas.append(drawing) }
                    drawing = nil
                })

            ForEach(Array(areas.enumerated()), id: \.offset) { index, area in
                let box = frame.denormalize(area)
                Rectangle()
                    .fill(tint.opacity(0.25))
                    .overlay(Rectangle().strokeBorder(tint, lineWidth: 2))
                    .frame(width: box.width, height: box.height)
                    .position(x: box.midX, y: box.midY)
                    .allowsHitTesting(false)
                Button {
                    areas.remove(at: index)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white, tint)
                }
                .buttonStyle(.plain)
                .position(x: box.maxX, y: box.minY)
            }
            if let drawing {
                let box = frame.denormalize(drawing)
                Rectangle()
                    .strokeBorder(tint, style: StrokeStyle(lineWidth: 2, dash: [5]))
                    .frame(width: box.width, height: box.height)
                    .position(x: box.midX, y: box.midY)
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(.named("areas"))
    }
}

/// A placeholder while something loads.
struct LoadingStage: View {
    var message = "Loading…"
    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(message).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Media

/// Loads what the media editors need and drives preview playback.
@MainActor
final class MediaSession: ObservableObject {
    let url: URL
    @Published var info = Media.Info()
    @Published var thumbnails: [CGImage] = []
    @Published var waveform: [Float] = []
    @Published var frame: CGImage?
    @Published var playhead: Double = 0
    @Published var isPlaying = false
    @Published var loaded = false
    let player: AVPlayer?
    private var observer: Any?
    private var stopAt: Double?

    init(url: URL) {
        self.url = url
        // AVPlayer also plays FLAC, though AVAssetExportSession can't write it.
        player = Media.isAppleReadable(url) || Catalog.normalize(url) == "flac" ? AVPlayer(url: url) : nil
        observer = player?.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.playhead = time.seconds
                if let stop = self.stopAt, time.seconds >= stop { self.pause() }
            }
        }
    }

    var canPreview: Bool { player != nil }

    func load(thumbnails count: Int = 0, waveform: Bool = false, frame: Bool = false) async {
        info = await Media.probe(url)
        if count > 0 { thumbnails = await Media.thumbnails(url, count: count, duration: info.duration) }
        if waveform { self.waveform = await Media.waveform(url) }
        if frame { self.frame = await Media.frame(url, at: min(info.duration / 3, 1)) }
        loaded = true
    }

    func seek(_ time: Double) {
        playhead = min(max(time, 0), info.duration)
        player?.seek(to: CMTime(seconds: playhead, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Fetches a still for editors that work on a single frame (crop, redact) when there's no player.
    func refreshFrame() async {
        frame = await Media.frame(url, at: playhead)
    }

    func play(from start: Double, to end: Double? = nil) {
        guard let player else { return }
        seek(start)
        stopAt = end
        player.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopAt = nil
    }

    func setRate(_ rate: Float) {
        guard let player else { return }
        player.rate = isPlaying ? rate : 0
        player.defaultRate = rate
    }

    func stop() {
        pause()
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
    }
}

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}
}

func timecode(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "0:00.0" }
    let total = max(0, seconds)
    return String(format: "%d:%04.1f", Int(total) / 60, total.truncatingRemainder(dividingBy: 60))
}

/// A strip of thumbnails or a waveform, a playhead, and optional trim handles.
struct Timeline<Overlay: View>: View {
    @ObservedObject var session: MediaSession
    var start: Binding<Double>?
    var end: Binding<Double>?
    /// Receives the duration-to-x mapping for drawing ranges or markers on top.
    @ViewBuilder var overlay: (_ x: @escaping (Double) -> CGFloat, _ width: CGFloat) -> Overlay

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let duration = max(session.info.duration, 0.001)
            let x: (Double) -> CGFloat = { CGFloat($0 / duration) * width }

            ZStack(alignment: .topLeading) {
                background
                    .frame(width: width, height: geometry.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        session.pause()
                        session.seek(Double(value.location.x / width) * duration)
                    })

                if let start, let end {
                    // Dim outside the selection, frame it in tangerine.
                    Rectangle().fill(Color.black.opacity(0.45))
                        .frame(width: x(start.wrappedValue), height: geometry.size.height)
                        .allowsHitTesting(false)
                    Rectangle().fill(Color.black.opacity(0.45))
                        .frame(width: max(0, width - x(end.wrappedValue)), height: geometry.size.height)
                        .offset(x: x(end.wrappedValue))
                        .allowsHitTesting(false)
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.tangerine, lineWidth: 3)
                        .frame(width: max(8, x(end.wrappedValue) - x(start.wrappedValue)), height: geometry.size.height)
                        .offset(x: x(start.wrappedValue))
                        .allowsHitTesting(false)
                    handle(at: x(start.wrappedValue), height: geometry.size.height) { location in
                        start.wrappedValue = min(max(0, Double(location / width) * duration), end.wrappedValue - 0.1)
                        session.seek(start.wrappedValue)
                    }
                    handle(at: x(end.wrappedValue) - 12, height: geometry.size.height) { location in
                        end.wrappedValue = max(min(duration, Double((location + 12) / width) * duration), start.wrappedValue + 0.1)
                        session.seek(end.wrappedValue)
                    }
                }

                overlay(x, width)

                Rectangle()
                    .fill(Color.white)
                    .shadow(radius: 1)
                    .frame(width: 2, height: geometry.size.height + 8)
                    .offset(x: x(session.playhead) - 1, y: -4)
                    .allowsHitTesting(false)
            }
            .coordinateSpace(.named("timeline"))
        }
    }

    @ViewBuilder
    private var background: some View {
        if !session.thumbnails.isEmpty {
            HStack(spacing: 0) {
                ForEach(session.thumbnails.indices, id: \.self) { index in
                    Image(decorative: session.thumbnails[index], scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
            }
        } else if !session.waveform.isEmpty {
            Canvas { context, size in
                let bars = session.waveform
                let step = size.width / CGFloat(bars.count)
                for (index, level) in bars.enumerated() {
                    let height = max(1, CGFloat(level) * size.height * 0.9)
                    let rect = CGRect(x: CGFloat(index) * step, y: (size.height - height) / 2, width: max(1, step * 0.7), height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: step * 0.3), with: .color(.secondary))
                }
            }
            .background(Color.primary.opacity(0.06))
        } else {
            Color.primary.opacity(0.08)
        }
    }

    private func handle(at x: CGFloat, height: CGFloat, onDrag: @escaping (CGFloat) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.tangerine)
            .overlay(Capsule().fill(Color.white).frame(width: 2, height: height * 0.4))
            .frame(width: 12, height: height)
            .offset(x: x)
            .gesture(DragGesture(coordinateSpace: .named("timeline")).onChanged { value in onDrag(value.location.x) })
    }
}

/// Play/pause, frame stepping and the current time.
struct TransportBar: View {
    @ObservedObject var session: MediaSession
    var range: ClosedRange<Double>?

    var body: some View {
        HStack(spacing: 12) {
            Button {
                session.seek(session.playhead - 1 / session.info.frameRate)
            } label: { Image(systemName: "backward.frame.fill") }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .help("Previous frame (←)")
            Button {
                if session.isPlaying {
                    session.pause()
                } else if let range {
                    let from = (range.lowerBound..<range.upperBound).contains(session.playhead) ? session.playhead : range.lowerBound
                    session.play(from: from, to: range.upperBound)
                } else {
                    session.play(from: session.playhead >= session.info.duration - 0.05 ? 0 : session.playhead)
                }
            } label: { Image(systemName: session.isPlaying ? "pause.fill" : "play.fill").frame(width: 18) }
                .disabled(!session.canPreview)
                .keyboardShortcut(.space, modifiers: [])
                .help("Play or pause (Space)")
            Button {
                session.seek(session.playhead + 1 / session.info.frameRate)
            } label: { Image(systemName: "forward.frame.fill") }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .help("Next frame (→)")
            Text("\(timecode(session.playhead)) / \(timecode(session.info.duration))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            if !session.canPreview {
                Text("Preview isn't available for \(session.url.pathExtension.uppercased())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
    }
}
