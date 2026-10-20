import SwiftUI
import CoreImage

/// Loads the upright image once for an editor, plus a smaller copy for live previews.
@MainActor
final class ImageSource: ObservableObject {
    @Published var image: CGImage?
    @Published var preview: CGImage?
    var size: CGSize { image.map { CGSize(width: $0.width, height: $0.height) } ?? CGSize(width: 1, height: 1) }

    func load(_ url: URL) async {
        let loaded = await Task.detached { try? ImageEngine.load(url).0 }.value
        image = loaded
        if let loaded {
            let longest = max(loaded.width, loaded.height)
            preview = longest > 1400 ? (try? ImageEngine.resized(loaded, scale: 1400 / CGFloat(longest))) : loaded
        }
    }
}

// MARK: - Crop

struct CropImageEditor: View {
    let context: EditorContext
    @StateObject private var source = ImageSource()
    @State private var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var aspect = CropAspect.free
    @State private var outputWidth = ""
    @State private var outputHeight = ""

    var body: some View {
        EditorScaffold(title: "Crop", context: context, canSave: source.image != nil, onSave: save) {
            if let image = source.preview {
                ImageStage(image: image) { frame in
                    CropOverlay(rect: $rect, frame: frame, pixelSize: source.size, ratio: aspect.ratio(original: source.size))
                }
            } else {
                LoadingStage()
            }
        } controls: {
            ControlGroup("Aspect ratio") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(CropAspect.allCases) { option in
                        OptionButton(selected: aspect == option, action: { aspect = option }) {
                            Text(option.rawValue).frame(maxWidth: .infinity)
                        }
                        .controlSize(.small)
                    }
                }
            }
            ControlGroup("Selection") {
                let w = Int(rect.width * source.size.width), h = Int(rect.height * source.size.height)
                Text("\(w) × \(h) px").font(.callout.monospacedDigit())
            }
            ControlGroup("Output size (optional)") {
                HStack {
                    TextField("Width", text: $outputWidth).frame(width: 80)
                    Text("×")
                    TextField("Height", text: $outputHeight).frame(width: 80)
                }
                .textFieldStyle(.roundedBorder)
                Text("Fill in one side to scale in proportion, or leave both empty to keep the cropped pixels.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Reset") {
                aspect = .free
                rect = CGRect(x: 0, y: 0, width: 1, height: 1)
            }
            if context.urls.count > 1 {
                Text("The same crop is applied to all \(context.urls.count) images.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await source.load(context.url) }
        .onChange(of: aspect) { _, newValue in
            guard let ratio = newValue.ratio(original: source.size) else { return }
            // Largest centred rectangle with that pixel aspect.
            let imageRatio = source.size.width / source.size.height
            let size = ratio > imageRatio ? CGSize(width: 1, height: imageRatio / ratio) : CGSize(width: ratio / imageRatio, height: 1)
            rect = CGRect(x: (1 - size.width) / 2, y: (1 - size.height) / 2, width: size.width, height: size.height)
        }
    }

    private func save() {
        let urls = context.urls, rect = rect
        // One typed side is enough: the other follows the crop's shape.
        let crop = CGSize(width: rect.width * source.size.width, height: rect.height * source.size.height)
        let typedWidth = Double(outputWidth).flatMap { $0 >= 1 ? $0 : nil }
        let typedHeight = Double(outputHeight).flatMap { $0 >= 1 ? $0 : nil }
        let size: CGSize? = {
            switch (typedWidth, typedHeight) {
            case let (w?, h?): return CGSize(width: w, height: h)
            case let (w?, nil): return CGSize(width: w, height: (w * crop.height / max(crop.width, 1)).rounded())
            case let (nil, h?): return CGSize(width: (h * crop.width / max(crop.height, 1)).rounded(), height: h)
            default: return nil
            }
        }()
        context.save("Crop") {
            var outputs: [URL] = []
            for url in urls { outputs += try await EditJobs.cropImage(url, rect: rect, size: size) }
            return outputs
        }
    }
}

// MARK: - Annotate

struct AnnotateEditor: View {
    let context: EditorContext
    @StateObject private var source = ImageSource()
    @State private var annotations: [ImageEdits.Annotation] = []
    @State private var current: ImageEdits.Annotation?
    @State private var tool = ImageEdits.Annotation.Kind.arrow
    @State private var color = RGBA.tangerine
    @State private var thickness = 0.006
    @State private var text = "Text"

    var body: some View {
        EditorScaffold(title: "Annotate", context: context, canSave: source.image != nil && !annotations.isEmpty, onSave: save) {
            if let image = source.preview {
                ImageStage(image: image) { frame in
                    let shown = annotations + (current.map { [$0] } ?? [])
                    Canvas { canvas, _ in
                        canvas.withCGContext { cg in
                            cg.translateBy(x: frame.minX, y: frame.minY)
                            ImageEdits.draw(shown, in: cg, size: frame.size)
                        }
                    }
                    .allowsHitTesting(false)

                    Color.white.opacity(0.001)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("stage"))
                            .onChanged { value in drag(value, in: frame) }
                            .onEnded { value in finish(value, in: frame) })
                }
            } else {
                LoadingStage()
            }
        } controls: {
            ControlGroup("Tool") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(ImageEdits.Annotation.Kind.allCases) { kind in
                        OptionButton(selected: tool == kind, action: { tool = kind }) {
                            Image(systemName: kind.symbol).frame(maxWidth: .infinity, minHeight: 22)
                        }
                        .help(kind.rawValue.capitalized)
                    }
                }
            }
            if tool == .text {
                ControlGroup("Text") {
                    TextField("Text to place", text: $text).textFieldStyle(.roundedBorder)
                    Text("Click on the image to place it.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if tool == .callout {
                Text("Click to drop numbered callouts: 1, 2, 3…").font(.caption).foregroundStyle(.secondary)
            }
            ControlGroup("Colour") { ColorSwatches(selection: $color) }
            ControlGroup("Size") {
                ValueSlider(title: "Thickness", value: $thickness, range: 0.002...0.02) { String(format: "%.0f", $0 * 1000) }
            }
            HStack {
                Button("Undo") { _ = annotations.popLast() }
                    .keyboardShortcut("z")
                    .disabled(annotations.isEmpty)
                Button("Clear") { annotations.removeAll() }.disabled(annotations.isEmpty)
            }
        }
        .task { await source.load(context.url) }
    }

    private func drag(_ value: DragGesture.Value, in frame: CGRect) {
        let point = frame.normalize(value.location)
        guard tool != .text, tool != .callout else { return }
        if current == nil {
            current = ImageEdits.Annotation(kind: tool, points: [frame.normalize(value.startLocation), point],
                                            color: color, width: thickness)
        } else if tool == .pen || tool == .highlight {
            current?.points.append(point)
        } else {
            current?.points[1] = point
        }
    }

    private func finish(_ value: DragGesture.Value, in frame: CGRect) {
        let point = frame.normalize(value.location)
        switch tool {
        case .text:
            guard !text.isEmpty else { return }
            annotations.append(ImageEdits.Annotation(kind: .text, points: [point], color: color, width: thickness, text: text))
        case .callout:
            let number = annotations.filter { $0.kind == .callout }.count + 1
            annotations.append(ImageEdits.Annotation(kind: .callout, points: [point], color: color, width: thickness, number: number))
        default:
            // A plain click would leave a zero-size shape, such as a lone arrowhead.
            if let current, let first = current.points.first, let last = current.points.last,
               hypot((last.x - first.x) * frame.width, (last.y - first.y) * frame.height) >= 3 || current.points.count > 2 {
                annotations.append(current)
            }
        }
        current = nil
    }

    private func save() {
        let url = context.url, annotations = annotations
        context.save("Annotate") { try await EditJobs.annotate(url, annotations) }
    }
}

// MARK: - Redact

struct RedactImageEditor: View {
    let context: EditorContext
    @StateObject private var source = ImageSource()
    @State private var areas: [CGRect] = []
    @State private var style = MediaEdits.RedactStyle.blur
    @State private var showResult = false
    @State private var result: CGImage?
    @State private var detecting = false

    var body: some View {
        EditorScaffold(title: "Redact", context: context, canSave: !areas.isEmpty, onSave: save) {
            if let image = source.preview {
                if showResult, let result {
                    ImageStage(image: result) { _ in EmptyView() }
                } else {
                    ImageStage(image: image) { frame in AreasOverlay(areas: $areas, frame: frame) }
                }
            } else {
                LoadingStage()
            }
        } controls: {
            ControlGroup("Detect on this Mac") {
                HStack {
                    Button("Faces") { detect(faces: true, text: false) }
                    Button("Text") { detect(faces: false, text: true) }
                    if detecting { ProgressView().controlSize(.small) }
                }
                Text("Or drag on the image to cover any area. Click × to remove one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ControlGroup("Style") {
                Picker("", selection: $style) {
                    ForEach(MediaEdits.RedactStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Toggle("Preview result", isOn: $showResult)
            Text("\(areas.count) area\(areas.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            Button("Remove all areas") { areas.removeAll() }.disabled(areas.isEmpty)
        }
        .task { await source.load(context.url) }
        .task(id: PreviewKey(areas: areas, style: style, on: showResult)) {
            guard showResult, let preview = source.preview else { return }
            let areas = areas, style = style
            result = await Task.detached { try? ImageEdits.redact(preview, areas: areas, style: style) }.value
        }
    }

    private struct PreviewKey: Equatable {
        let areas: [CGRect]
        let style: MediaEdits.RedactStyle
        let on: Bool
    }

    private func detect(faces: Bool, text: Bool) {
        guard let image = source.preview else { return }
        detecting = true
        Task {
            let found = await Task.detached { ImageEdits.detectSensitiveAreas(image, faces: faces, text: text) }.value
            areas += found
            detecting = false
        }
    }

    private func save() {
        let url = context.url, areas = areas, style = style
        context.save("Redact") { try await EditJobs.redact(url, areas: areas, style: style) }
    }
}

// MARK: - Add background

struct BackgroundEditor: View {
    let context: EditorContext
    @StateObject private var source = ImageSource()
    @State private var options = ImageEdits.Background()
    @State private var preview: CGImage?

    var body: some View {
        EditorScaffold(title: "Add Background", context: context, canSave: source.image != nil, onSave: save) {
            if let preview {
                ImageStage(image: preview) { _ in EmptyView() }
            } else {
                LoadingStage()
            }
        } controls: {
            ControlGroup("Background") {
                Picker("", selection: $options.style) {
                    ForEach(ImageEdits.Background.Style.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                ColorSwatches(selection: $options.color1)
                if options.style == .gradient { ColorSwatches(selection: $options.color2) }
            }
            ControlGroup("Aspect ratio") {
                Picker("", selection: $options.aspect) {
                    ForEach(ImageEdits.Background.Aspect.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ControlGroup("Layout") {
                ValueSlider(title: "Spacing", value: Binding(get: { Double(options.padding) }, set: { options.padding = CGFloat($0) }),
                            range: 0...0.4) { "\(Int($0 * 100))%" }
                ValueSlider(title: "Corner radius", value: Binding(get: { Double(options.cornerRadius) }, set: { options.cornerRadius = CGFloat($0) }),
                            range: 0...0.2) { "\(Int($0 * 100))%" }
                Toggle("Shadow", isOn: $options.shadow)
            }
        }
        .task { await source.load(context.url) }
        .task(id: PreviewKey(options: options, loaded: source.preview != nil)) {
            guard let image = source.preview else { return }
            let options = options
            preview = await Task.detached { try? ImageEdits.addBackground(image, options) }.value
        }
    }

    private struct PreviewKey: Equatable {
        let options: ImageEdits.Background
        let loaded: Bool
    }

    private func save() {
        let urls = context.urls, options = options
        context.save("Add Background") {
            var outputs: [URL] = []
            for url in urls { outputs += try await EditJobs.addBackground(url, options) }
            return outputs
        }
    }
}

// MARK: - Edit

struct PhotoEditor: View {
    let context: EditorContext
    @StateObject private var source = ImageSource()
    @State private var adjustments = ImageEdits.Adjustments()
    @State private var preview: CGImage?
    @State private var showOriginal = false

    var body: some View {
        EditorScaffold(title: "Edit", context: context, canSave: source.image != nil && adjustments != ImageEdits.Adjustments(), onSave: save) {
            if let shown = showOriginal ? source.preview : (preview ?? source.preview) {
                ImageStage(image: shown) { _ in EmptyView() }
            } else {
                LoadingStage()
            }
        } controls: {
            // Orientation, compare and reset first: below the sliders they ran off the window.
            HStack(spacing: 6) {
                Button { adjustments.quarterTurns -= 1 } label: { Image(systemName: "rotate.left") }.help("Rotate left")
                Button { adjustments.quarterTurns += 1 } label: { Image(systemName: "rotate.right") }.help("Rotate right")
                Button { adjustments.flipped.toggle() } label: {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .help("Flip horizontally")
                Spacer()
                Toggle("Original", isOn: $showOriginal).toggleStyle(.button).help("Compare with the original")
                Button("Reset") { adjustments = ImageEdits.Adjustments() }
                    .disabled(adjustments == ImageEdits.Adjustments())
            }
            ControlGroup("Effect") {
                Picker("", selection: $adjustments.effect) {
                    ForEach(ImageEdits.Effect.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
            }
            ControlGroup("Light") {
                ValueSlider(title: "Exposure", value: $adjustments.exposure, range: -2...2) { String(format: "%+.1f EV", $0) }
                ValueSlider(title: "Contrast", value: $adjustments.contrast, range: 0.5...1.5, format: percentFrom(1))
                ValueSlider(title: "Highlights", value: $adjustments.highlights, range: 0...1, format: percentFrom(1))
                ValueSlider(title: "Shadows", value: $adjustments.shadows, range: -1...1, format: percentFrom(0))
            }
            ControlGroup("Colour") {
                ValueSlider(title: "Saturation", value: $adjustments.saturation, range: 0...2, format: percentFrom(1))
                ValueSlider(title: "Vibrance", value: $adjustments.vibrance, range: -1...1, format: percentFrom(0))
                ValueSlider(title: "Warmth", value: $adjustments.warmth, range: -1...1, format: percentFrom(0))
            }
            ControlGroup("Detail") {
                ValueSlider(title: "Sharpness", value: $adjustments.sharpness, range: 0...1, format: percentFrom(0))
                ValueSlider(title: "Vignette", value: $adjustments.vignette, range: 0...2, format: percentFrom(0))
            }
        }
        .task { await source.load(context.url) }
        .task(id: PreviewKey(adjustments: adjustments, loaded: source.preview != nil)) {
            guard let image = source.preview else { return }
            let adjustments = adjustments
            preview = await Task.detached { try? ImageEdits.render(ImageEdits.adjust(CIImage(cgImage: image), adjustments)) }.value
        }
    }

    /// Shows a slider as a signed change from its neutral value: "+25 %", "0 %".
    private func percentFrom(_ neutral: Double) -> (Double) -> String {
        { value in
            let change = Int(((value - neutral) * 100).rounded())
            return change == 0 ? "0 %" : String(format: "%+d %%", change)
        }
    }

    private struct PreviewKey: Equatable {
        let adjustments: ImageEdits.Adjustments
        let loaded: Bool
    }

    private func save() {
        let urls = context.urls, adjustments = adjustments
        context.save("Edit") {
            var outputs: [URL] = []
            for url in urls { outputs += try await EditJobs.editPhoto(url, adjustments) }
            return outputs
        }
    }
}

// MARK: - Collage

struct CollageEditor: View {
    let context: EditorContext
    @State private var order: [URL] = []
    @State private var thumbnails: [URL: CGImage] = [:]
    @State private var layout = ImageEdits.Layout.grid
    @State private var spacing = 0.015
    @State private var corners = 0.03
    @State private var background = RGBA(red: 1, green: 1, blue: 1)
    @State private var preview: CGImage?

    var body: some View {
        EditorScaffold(title: "Make a Collage", context: context, canSave: order.count > 1, onSave: save) {
            if let preview {
                ImageStage(image: preview) { _ in EmptyView() }
            } else {
                LoadingStage()
            }
        } controls: {
            ControlGroup("Layout") {
                Picker("", selection: $layout) {
                    ForEach(ImageEdits.Layout.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                ValueSlider(title: "Spacing", value: $spacing, range: 0...0.05) { "\(Int($0 * 1000))" }
                ValueSlider(title: "Corners", value: $corners, range: 0...0.2) { "\(Int($0 * 100))%" }
            }
            ControlGroup("Background") { ColorSwatches(selection: $background) }
            ControlGroup("Order") {
                ForEach(Array(order.enumerated()), id: \.element) { index, url in
                    HStack {
                        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle).font(.callout)
                        Spacer()
                        Button { order.swapAt(index, index - 1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0)
                        Button { order.swapAt(index, index + 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == order.count - 1)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .task {
            order = context.urls
            for url in context.urls {
                if let image = await Task.detached(operation: { () -> CGImage? in
                    guard let full = try? ImageEngine.load(url).0 else { return nil }
                    let longest = max(full.width, full.height)
                    return longest > 900 ? (try? ImageEngine.resized(full, scale: 900 / CGFloat(longest))) : full
                }).value {
                    thumbnails[url] = image
                }
            }
        }
        .task(id: PreviewKey(order: order, layout: layout, spacing: spacing, corners: corners, background: background, count: thumbnails.count)) {
            let images = order.compactMap { thumbnails[$0] }
            guard images.count == order.count, !images.isEmpty else { return }
            let layout = layout, spacing = spacing, corners = corners, background = background
            preview = await Task.detached {
                try? ImageEdits.collage(images, layout: layout, spacing: spacing, cornerRadius: corners, background: background, width: 1200)
            }.value
        }
    }

    private struct PreviewKey: Equatable {
        let order: [URL]
        let layout: ImageEdits.Layout
        let spacing: Double, corners: Double
        let background: RGBA
        let count: Int
    }

    private func save() {
        let order = order, layout = layout, spacing = spacing, corners = corners, background = background
        context.save("Collage") {
            try await EditJobs.collage(order, layout: layout, spacing: spacing, cornerRadius: corners, background: background)
        }
    }
}
