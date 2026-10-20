import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Metadata

/// View and edit tags on an image, audio/video file or PDF, or strip them from a selection.
struct MetadataEditor: View {
    let context: EditorContext
    @State private var image = ImageEdits.Metadata()
    @State private var removeLocation = false
    @State private var fields: [String: String] = [:]
    @State private var loaded = false

    private var kind: FileKind { FileKind.common(context.urls) }
    private var single: Bool { context.urls.count == 1 }

    var body: some View {
        EditorScaffold(title: "Metadata", context: context, saveTitle: single ? "Save" : "Remove Metadata", canSave: loaded, onSave: save) {
            Group {
                if !single {
                    VStack(spacing: 12) {
                        Image(systemName: "tag.slash").font(.system(size: 48)).foregroundStyle(Color.tangerine)
                        Text("Remove all metadata from \(context.urls.count) files").font(.title3)
                        Text("Clean copies are saved next to the originals.").foregroundStyle(.secondary)
                    }
                } else {
                    Form { formFields }
                        .formStyle(.grouped)
                        .frame(maxWidth: 520)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } controls: {
            if single {
                ControlGroup("Privacy") {
                    Text("Save a copy without any tags at all.").font(.caption).foregroundStyle(.secondary)
                    Button("Remove all metadata", role: .destructive) {
                        let urls = context.urls
                        context.save("Remove Metadata") { try await EditJobs.removeMetadata(urls) }
                    }
                }
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var formFields: some View {
        switch kind {
        case .image:
            Section("Description") {
                TextField("Title", text: $image.title)
                TextField("Author", text: $image.author)
                TextField("Copyright", text: $image.copyright)
                TextField("Comment", text: $image.comment)
                TextField("Date taken", text: $image.date, prompt: Text("YYYY:MM:DD HH:MM:SS"))
            }
            Section("Location") {
                TextField("Latitude", text: $image.latitude)
                TextField("Longitude", text: $image.longitude)
                Toggle("Remove location", isOn: $removeLocation)
            }
            if !image.camera.isEmpty {
                Section("Camera") { Text(image.camera).foregroundStyle(.secondary) }
            }
        case .pdf:
            Section("Document") {
                ForEach(EditJobs.pdfKeys.map { $0.label }, id: \.self) { label in
                    TextField(label, text: binding(label))
                }
            }
        default:
            Section("Tags") {
                ForEach(MediaEdits.metadataKeys, id: \.self) { key in
                    TextField(key.capitalized, text: binding(key))
                }
            }
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { fields[key] ?? "" }, set: { fields[key] = $0 })
    }

    private func load() async {
        guard single else { loaded = true; return }
        let url = context.url
        switch kind {
        case .image:
            image = ImageEdits.readMetadata(url)
        case .pdf:
            let attributes = PDFDocument(url: url)?.documentAttributes ?? [:]
            for (label, key) in EditJobs.pdfKeys {
                let value = attributes[key] ?? attributes[key.rawValue]
                fields[label] = (value as? [String])?.joined(separator: ", ") ?? (value as? String) ?? ""
            }
        default:
            let tags = await Media.metadata(url)
            for key in MediaEdits.metadataKeys { fields[key] = tags[key] ?? "" }
        }
        loaded = true
    }

    private func save() {
        let urls = context.urls
        guard single else {
            context.save("Remove Metadata") { try await EditJobs.removeMetadata(urls) }
            return
        }
        let url = context.url, image = image, removeLocation = removeLocation, fields = fields
        switch kind {
        case .image:
            context.save("Metadata") { try await EditJobs.imageMetadata(url, image, removeLocation: removeLocation) }
        case .pdf:
            context.save("Metadata") { [try EditJobs.pdfMetadata(url, fields: fields, removeAll: false)] }
        default:
            context.save("Metadata") { [try await MediaEdits.writeMetadata(url, fields: fields, removeAll: false)] }
        }
    }
}

// MARK: - Organize PDF pages

struct OrganizePDFEditor: View {
    struct PageItem: Identifiable, Equatable {
        let id = UUID()
        let index: Int
        var rotation = 0
    }

    let context: EditorContext
    @State private var document: PDFDocument?
    @State private var pages: [PageItem] = []
    @State private var thumbnails: [Int: NSImage] = [:]
    @State private var selection: Set<UUID> = []

    var body: some View {
        EditorScaffold(title: "Organize Pages", context: context, canSave: !pages.isEmpty, onSave: save) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 16)], spacing: 16) {
                    ForEach(pages) { page in tile(page) }
                }
                .padding(20)
            }
        } controls: {
            ControlGroup("Selected pages") {
                HStack {
                    Button { rotate(-90) } label: { Image(systemName: "rotate.left") }.help("Rotate left")
                    Button { rotate(90) } label: { Image(systemName: "rotate.right") }.help("Rotate right")
                    Button { duplicate() } label: { Image(systemName: "plus.square.on.square") }.help("Duplicate")
                    Button(role: .destructive) { delete() } label: { Image(systemName: "trash") }.help("Delete")
                }
                .disabled(selection.isEmpty)
                HStack {
                    Button("Move earlier") { move(-1) }
                    Button("Move later") { move(1) }
                }
                .controlSize(.small)
                .disabled(selection.isEmpty)
            }
            Text("Click to select, ⌘-click for more. Drag pages to reorder.").font(.caption).foregroundStyle(.secondary)
            Text("\(pages.count) pages").font(.caption).foregroundStyle(.secondary)
        }
        .task {
            guard let document = PDFDocument(url: context.url) else { return }
            self.document = document
            pages = (0..<document.pageCount).map { PageItem(index: $0) }
            for index in 0..<document.pageCount {
                thumbnails[index] = document.page(at: index)?.thumbnail(of: CGSize(width: 240, height: 300), for: .mediaBox)
            }
        }
    }

    private func tile(_ page: PageItem) -> some View {
        let selected = selection.contains(page.id)
        return VStack(spacing: 6) {
            Group {
                if let thumb = thumbnails[page.index] {
                    Image(nsImage: thumb).resizable().scaledToFit()
                } else {
                    Color.primary.opacity(0.08)
                }
            }
            .frame(width: 120, height: 150)
            .rotationEffect(.degrees(Double(page.rotation)))
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.tangerine.opacity(0.18) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.tangerine : .clear, lineWidth: 2))
            Text("\(page.index + 1)").font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                if selected { selection.remove(page.id) } else { selection.insert(page.id) }
            } else {
                selection = [page.id]
            }
        }
        .draggable(page.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.first.flatMap(UUID.init(uuidString:)),
                  let from = pages.firstIndex(where: { $0.id == dragged }),
                  let to = pages.firstIndex(where: { $0.id == page.id }), from != to else { return false }
            let item = pages.remove(at: from)
            pages.insert(item, at: to)
            return true
        }
    }

    private func rotate(_ degrees: Int) {
        for index in pages.indices where selection.contains(pages[index].id) {
            pages[index].rotation = (pages[index].rotation + degrees + 360) % 360
        }
    }

    private func duplicate() {
        var result: [PageItem] = []
        for page in pages {
            result.append(page)
            if selection.contains(page.id) { result.append(PageItem(index: page.index, rotation: page.rotation)) }
        }
        pages = result
    }

    private func delete() {
        pages.removeAll { selection.contains($0.id) }
        selection.removeAll()
    }

    private func move(_ offset: Int) {
        let indices = pages.indices.filter { selection.contains(pages[$0].id) }
        let ordered = offset < 0 ? indices : indices.reversed()
        for index in ordered {
            let target = index + offset
            guard pages.indices.contains(target), !selection.contains(pages[target].id) else { continue }
            pages.swapAt(index, target)
        }
    }

    private func save() {
        let url = context.url, order = pages.map { (index: $0.index, rotation: $0.rotation) }
        context.save("Organize") { try await EditJobs.organizePDF(url, pages: order) }
    }
}

// MARK: - Opening editors

@MainActor
enum Editors {
    static private(set) var windows: [NSWindow] = []

    static func open(_ tool: Tool, title: String, urls: [URL]) {
        let context = EditorContext(urls: urls)
        guard let content = view(for: tool, kind: FileKind.common(urls), context: context) else { return }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.center()
        context.close = { [weak window] in window?.close() }

        windows.append(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { note in
            MainActor.assumeIsolated { windows.removeAll { $0 === note.object as? NSWindow } }
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private static func view(for tool: Tool, kind: FileKind, context: EditorContext) -> AnyView? {
        switch (tool, kind) {
        case (.crop, .image): return AnyView(CropImageEditor(context: context))
        case (.annotate, _): return AnyView(AnnotateEditor(context: context))
        case (.redact, .image): return AnyView(RedactImageEditor(context: context))
        case (.addBackground, _): return AnyView(BackgroundEditor(context: context))
        case (.edit, _): return AnyView(PhotoEditor(context: context))
        case (.collage, _): return AnyView(CollageEditor(context: context))
        case (.metadata, _): return AnyView(MetadataEditor(context: context))
        case (.trim, _): return AnyView(TrimEditor(context: context))
        case (.bleep, _): return AnyView(BleepEditor(context: context))
        case (.split, _): return AnyView(SplitEditor(context: context))
        case (.snapshot, _): return AnyView(SnapshotEditor(context: context))
        case (.crop, _): return AnyView(CropVideoEditor(context: context))
        case (.redact, _): return AnyView(RedactVideoEditor(context: context))
        case (.speed, _): return AnyView(SpeedEditor(context: context))
        case (.visualize, _): return AnyView(VisualizeEditor(context: context))
        case (.channels, _): return AnyView(ChannelsEditor(context: context))
        case (.join, _): return AnyView(JoinEditor(context: context))
        case (.organize, _): return AnyView(OrganizePDFEditor(context: context))
        default: return nil
        }
    }
}
