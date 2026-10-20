import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import Vision

/// A colour that can cross between SwiftUI previews and Core Graphics rendering.
struct RGBA: Hashable {
    var red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1

    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var hex: String { String(format: "%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255)) }

    init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: CGColor) {
        let srgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil) ?? color
        let c = srgb.components ?? [0, 0, 0, 1]
        if c.count >= 3 {
            self.init(red: c[0], green: c[1], blue: c[2], alpha: c.count > 3 ? c[3] : 1)
        } else {
            self.init(red: c[0], green: c[0], blue: c[0], alpha: c.count > 1 ? c[1] : 1)
        }
    }

    static let tangerine = RGBA(red: 1, green: 0.31, blue: 0)
    static let palette: [RGBA] = [
        .tangerine, RGBA(red: 0.92, green: 0.2, blue: 0.2), RGBA(red: 1, green: 0.8, blue: 0),
        RGBA(red: 0.2, green: 0.75, blue: 0.35), RGBA(red: 0.1, green: 0.5, blue: 1),
        RGBA(red: 0, green: 0, blue: 0), RGBA(red: 1, green: 1, blue: 1),
    ]
}

/// Pixel operations behind the image editors. All rectangles and points are normalised
/// (0…1, origin top-left) so the same values drive the on-screen preview and the export.
enum ImageEdits {
    /// Creating a CIContext is expensive; one shared, thread-safe context serves every render.
    static let ciContext = CIContext()
    // MARK: Crop

    static func crop(_ image: CGImage, rect: CGRect, outputSize: CGSize?) throws -> CGImage {
        let box = CGRect(x: rect.minX * CGFloat(image.width), y: rect.minY * CGFloat(image.height),
                         width: rect.width * CGFloat(image.width), height: rect.height * CGFloat(image.height)).integral
        guard var cropped = image.cropping(to: box) else { throw ConvertError("Couldn't crop the image") }
        if let outputSize, outputSize.width >= 1, outputSize.height >= 1 {
            guard let ctx = CGContext(data: nil, width: Int(outputSize.width), height: Int(outputSize.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: ImageEngine.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw ConvertError("Couldn't resize the image") }
            ctx.interpolationQuality = .high
            ctx.draw(cropped, in: CGRect(origin: .zero, size: outputSize))
            if let resized = ctx.makeImage() { cropped = resized }
        }
        return cropped
    }

    // MARK: Annotate

    struct Annotation: Identifiable {
        enum Kind: String, CaseIterable, Identifiable {
            case arrow, rectangle, ellipse, pen, highlight, text, callout
            var id: String { rawValue }
            var symbol: String {
                switch self {
                case .arrow: return "arrow.up.right"
                case .rectangle: return "rectangle"
                case .ellipse: return "circle"
                case .pen: return "scribble"
                case .highlight: return "highlighter"
                case .text: return "textformat"
                case .callout: return "1.circle"
                }
            }
        }

        let id = UUID()
        var kind: Kind
        var points: [CGPoint]
        var color: RGBA
        /// Stroke width as a fraction of the image width.
        var width: CGFloat
        var text = ""
        var number = 0
    }

    static func annotate(_ image: CGImage, with annotations: [Annotation]) throws -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: ImageEngine.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ConvertError("Couldn't draw on the image") }
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        // Annotations use top-left coordinates, like the editor.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        draw(annotations, in: ctx, size: size)
        guard let result = ctx.makeImage() else { throw ConvertError("Couldn't draw on the image") }
        return result
    }

    /// Draws into a y-down context of `size` (the editor's Canvas, or the flipped export context).
    static func draw(_ annotations: [Annotation], in ctx: CGContext, size: CGSize) {
        for item in annotations {
            let points = item.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
            guard let first = points.first else { continue }
            let last = points.last ?? first
            let lineWidth = max(1, item.width * size.width)

            ctx.saveGState()
            ctx.setStrokeColor(item.color.cgColor)
            ctx.setFillColor(item.color.cgColor)
            ctx.setLineWidth(lineWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)

            switch item.kind {
            case .arrow:
                let angle = atan2(last.y - first.y, last.x - first.x)
                let head = lineWidth * 4.5
                let base = CGPoint(x: last.x - cos(angle) * head * 0.8, y: last.y - sin(angle) * head * 0.8)
                ctx.move(to: first)
                ctx.addLine(to: base)
                ctx.strokePath()
                ctx.move(to: last)
                ctx.addLine(to: CGPoint(x: last.x - head * cos(angle - .pi / 7), y: last.y - head * sin(angle - .pi / 7)))
                ctx.addLine(to: CGPoint(x: last.x - head * cos(angle + .pi / 7), y: last.y - head * sin(angle + .pi / 7)))
                ctx.closePath()
                ctx.fillPath()
            case .rectangle:
                ctx.stroke(CGRect(from: first, to: last))
            case .ellipse:
                ctx.strokeEllipse(in: CGRect(from: first, to: last))
            case .pen, .highlight:
                if item.kind == .highlight {
                    ctx.setAlpha(0.35)
                    ctx.setLineWidth(lineWidth * 4)
                    ctx.setLineCap(.square)
                }
                ctx.move(to: first)
                points.dropFirst().forEach { ctx.addLine(to: $0) }
                if points.count == 1 { ctx.addLine(to: CGPoint(x: first.x + 0.1, y: first.y)) }
                ctx.strokePath()
            case .text:
                drawText(item.text, at: first, size: lineWidth * 7, color: item.color, in: ctx, centered: false)
            case .callout:
                let radius = lineWidth * 4
                ctx.fillEllipse(in: CGRect(x: first.x - radius, y: first.y - radius, width: radius * 2, height: radius * 2))
                let white = item.color.red + item.color.green + item.color.blue > 2.4
                drawText("\(item.number)", at: first, size: radius * 1.1, color: white ? RGBA(red: 0, green: 0, blue: 0) : RGBA(red: 1, green: 1, blue: 1),
                         in: ctx, centered: true)
            }
            ctx.restoreGState()
        }
    }

    private static func drawText(_ text: String, at point: CGPoint, size: CGFloat, color: RGBA, in ctx: CGContext, centered: Bool) {
        guard !text.isEmpty else { return }
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: NSColor(cgColor: color.cgColor) ?? .black,
        ])
        let bounds = string.size()
        let origin = centered ? CGPoint(x: point.x - bounds.width / 2, y: point.y - bounds.height / 2) : point
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        string.draw(at: origin)
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Redact

    /// Faces and/or text found on-device by Vision, padded slightly.
    static func detectSensitiveAreas(_ image: CGImage, faces: Bool, text: Bool) -> [CGRect] {
        var requests: [VNRequest] = []
        let faceRequest = VNDetectFaceRectanglesRequest()
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .fast
        if faces { requests.append(faceRequest) }
        if text { requests.append(textRequest) }
        guard !requests.isEmpty else { return [] }
        try? VNImageRequestHandler(cgImage: image).perform(requests)

        var boxes: [CGRect] = []
        if faces { boxes += (faceRequest.results ?? []).map(\.boundingBox) }
        if text { boxes += (textRequest.results ?? []).map(\.boundingBox) }
        // Vision's origin is bottom-left; flip and pad by 15%.
        return boxes.map { box in
            let padX = box.width * 0.15, padY = box.height * 0.15
            return CGRect(x: box.minX - padX, y: 1 - box.maxY - padY, width: box.width + padX * 2, height: box.height + padY * 2)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    static func redact(_ image: CGImage, areas: [CGRect], style: MediaEdits.RedactStyle) throws -> CGImage {
        let base = CIImage(cgImage: image)
        let width = CGFloat(image.width), height = CGFloat(image.height)
        // Minimum strength relative to the image, so the editor's downscaled preview and the
        // full-size result hide text equally well.
        let minimum = max(width, height) * 0.006
        var output = base
        for area in areas {
            // Core Image's origin is bottom-left.
            let rect = CGRect(x: area.minX * width, y: (1 - area.maxY) * height, width: area.width * width, height: area.height * height)
            let cover: CIImage
            switch style {
            case .blur:
                cover = base.clampedToExtent().applyingGaussianBlur(sigma: max(minimum, min(rect.width, rect.height) / 6))
            case .pixelate:
                let filter = CIFilter.pixellate()
                filter.inputImage = base.clampedToExtent()
                filter.scale = Float(max(minimum, min(rect.width, rect.height) / 8))
                filter.center = CGPoint(x: rect.midX, y: rect.midY)
                cover = filter.outputImage ?? base
            case .solid:
                cover = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            }
            output = cover.cropped(to: rect).composited(over: output)
        }
        guard let result = ciContext.createCGImage(output, from: base.extent) else { throw ConvertError("Couldn't redact the image") }
        return result
    }

    // MARK: Background

    struct Background: Equatable {
        enum Style: String, CaseIterable, Identifiable { case solid = "Solid", gradient = "Gradient"; var id: String { rawValue } }
        enum Aspect: String, CaseIterable, Identifiable {
            case original = "Fit", square = "1:1", portrait = "4:5", landscape = "16:9", story = "9:16"
            var id: String { rawValue }
            var ratio: CGFloat? {
                switch self {
                case .original: return nil
                case .square: return 1
                case .portrait: return 4.0 / 5
                case .landscape: return 16.0 / 9
                case .story: return 9.0 / 16
                }
            }
        }

        var style = Style.gradient
        var color1 = RGBA(red: 1, green: 0.55, blue: 0.2)
        var color2 = RGBA(red: 0.95, green: 0.25, blue: 0.4)
        var padding: CGFloat = 0.1      // of the longer side
        var cornerRadius: CGFloat = 0.04 // of the shorter side
        var shadow = true
        var aspect = Aspect.original
    }

    static func addBackground(_ image: CGImage, _ options: Background) throws -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let pad = options.padding * max(w, h)
        var canvas = CGSize(width: w + pad * 2, height: h + pad * 2)
        if let ratio = options.aspect.ratio {
            if canvas.width / canvas.height < ratio { canvas.width = canvas.height * ratio } else { canvas.height = canvas.width / ratio }
        }
        guard let ctx = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: ImageEngine.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ConvertError("Image too large") }

        let full = CGRect(origin: .zero, size: canvas)
        if options.style == .gradient,
           let gradient = CGGradient(colorsSpace: ImageEngine.sRGB, colors: [options.color1.cgColor, options.color2.cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: canvas.height), end: CGPoint(x: canvas.width, y: 0), options: [])
        } else {
            ctx.setFillColor(options.color1.cgColor)
            ctx.fill(full)
        }

        let frame = CGRect(x: (canvas.width - w) / 2, y: (canvas.height - h) / 2, width: w, height: h)
        let radius = options.cornerRadius * min(w, h)
        let shape = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if options.shadow {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -max(w, h) * 0.015), blur: max(w, h) * 0.04,
                          color: CGColor(gray: 0, alpha: 0.35))
            ctx.addPath(shape)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.draw(image, in: frame)
        ctx.restoreGState()
        guard let result = ctx.makeImage() else { throw ConvertError("Couldn't render the background") }
        return result
    }

    // MARK: Edit

    enum Effect: String, CaseIterable, Identifiable {
        case none = "None", mono = "Mono", noir = "Noir", chrome = "Chrome", fade = "Fade",
             instant = "Instant", process = "Process", tonal = "Tonal", transfer = "Transfer"
        var id: String { rawValue }
        var filterName: String? { self == .none ? nil : "CIPhotoEffect\(rawValue)" }
    }

    struct Adjustments: Equatable {
        var exposure: Double = 0      // EV, -2…2
        var contrast: Double = 1      // 0.5…1.5
        var saturation: Double = 1    // 0…2
        var warmth: Double = 0        // -1…1
        var vibrance: Double = 0      // -1…1
        var shadows: Double = 0       // -1…1
        var highlights: Double = 1    // 0…1
        var sharpness: Double = 0     // 0…1
        var vignette: Double = 0      // 0…2
        var effect = Effect.none
        var quarterTurns = 0
        var flipped = false
    }

    static func adjust(_ input: CIImage, _ a: Adjustments) -> CIImage {
        var image = input
        if a.flipped { image = image.oriented(.upMirrored) }
        for _ in 0..<((a.quarterTurns % 4 + 4) % 4) { image = image.oriented(.right) }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))

        if a.exposure != 0 { image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: a.exposure]) }
        if a.contrast != 1 || a.saturation != 1 {
            image = image.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: a.contrast, kCIInputSaturationKey: a.saturation])
        }
        if a.vibrance != 0 { image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": a.vibrance]) }
        if a.warmth != 0 {
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6500 - a.warmth * 2500, y: 0),
            ])
        }
        if a.shadows != 0 || a.highlights != 1 {
            image = image.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputShadowAmount": a.shadows, "inputHighlightAmount": a.highlights])
        }
        if a.sharpness > 0 { image = image.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: a.sharpness]) }
        if let name = a.effect.filterName { image = image.applyingFilter(name) }
        if a.vignette > 0 {
            image = image.applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: a.vignette, kCIInputRadiusKey: 2])
        }
        return image.cropped(to: CGRect(origin: .zero, size: image.extent.size))
    }

    static func render(_ image: CIImage) throws -> CGImage {
        guard let result = ciContext.createCGImage(image, from: image.extent) else { throw ConvertError("Couldn't render the image") }
        return result
    }

    // MARK: Collage

    enum Layout: String, CaseIterable, Identifiable {
        case grid = "Grid", row = "Row", column = "Column", featured = "Featured"
        var id: String { rawValue }
    }

    static func collage(_ images: [CGImage], layout: Layout, spacing: CGFloat, cornerRadius: CGFloat,
                        background: RGBA, width: CGFloat = 2400) throws -> CGImage {
        guard !images.isEmpty else { throw ConvertError("No images") }
        let gap = spacing * width
        var cells: [CGRect] = []   // top-left coordinates
        var height: CGFloat

        switch layout {
        case .grid:
            let columns = Int(ceil(sqrt(Double(images.count))))
            let rows = Int(ceil(Double(images.count) / Double(columns)))
            let side = (width - gap * CGFloat(columns + 1)) / CGFloat(columns)
            height = CGFloat(rows) * side + gap * CGFloat(rows + 1)
            for index in images.indices {
                cells.append(CGRect(x: gap + CGFloat(index % columns) * (side + gap), y: gap + CGFloat(index / columns) * (side + gap),
                                    width: side, height: side))
            }
        case .row:
            // Same height for every image, widths follow their aspect ratios.
            let ratios = images.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) }
            let rowHeight = (width - gap * CGFloat(images.count + 1)) / ratios.reduce(0, +)
            height = rowHeight + gap * 2
            var x = gap
            for ratio in ratios {
                cells.append(CGRect(x: x, y: gap, width: rowHeight * ratio, height: rowHeight))
                x += rowHeight * ratio + gap
            }
        case .column:
            let inner = width - gap * 2
            var y = gap
            for image in images {
                let h = inner * CGFloat(image.height) / CGFloat(max(image.width, 1))
                cells.append(CGRect(x: gap, y: y, width: inner, height: h))
                y += h + gap
            }
            height = y
        case .featured:
            height = width * 2 / 3
            let others = images.count - 1
            let bigWidth = others == 0 ? width - gap * 2 : (width - gap * 3) * 2 / 3
            cells.append(CGRect(x: gap, y: gap, width: bigWidth, height: height - gap * 2))
            if others > 0 {
                let side = (height - gap * CGFloat(others + 1)) / CGFloat(others)
                for index in 0..<others {
                    cells.append(CGRect(x: gap * 2 + bigWidth, y: gap + CGFloat(index) * (side + gap),
                                        width: width - bigWidth - gap * 3, height: side))
                }
            }
        }

        guard height >= 1, let ctx = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                                                space: ImageEngine.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ConvertError("Couldn't lay out the collage") }
        ctx.setFillColor(background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        for (image, cell) in zip(images, cells) {
            let frame = CGRect(x: cell.minX, y: height - cell.maxY, width: cell.width, height: cell.height)  // flip to CG
            let radius = cornerRadius * min(frame.width, frame.height)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.clip()
            // Aspect-fill the cell.
            let scale = max(frame.width / CGFloat(image.width), frame.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height))
            ctx.restoreGState()
        }
        guard let result = ctx.makeImage() else { throw ConvertError("Couldn't render the collage") }
        return result
    }

    // MARK: Metadata

    struct Metadata: Equatable {
        var title = "", author = "", copyright = "", comment = "", date = ""
        var latitude = "", longitude = ""
        var camera = ""   // read-only summary
    }

    static func readMetadata(_ url: URL) -> Metadata {
        var m = Metadata()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return m }
        var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        // PNG keeps its own text chunks.
        if let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFImageDescription] = tiff[kCGImagePropertyTIFFImageDescription] ?? png[kCGImagePropertyPNGTitle]
            tiff[kCGImagePropertyTIFFArtist] = tiff[kCGImagePropertyTIFFArtist] ?? png[kCGImagePropertyPNGAuthor]
            tiff[kCGImagePropertyTIFFCopyright] = tiff[kCGImagePropertyTIFFCopyright] ?? png[kCGImagePropertyPNGCopyright]
            exif[kCGImagePropertyExifUserComment] = exif[kCGImagePropertyExifUserComment] ?? png[kCGImagePropertyPNGDescription]
        }
        // PNG and others keep these in XMP rather than TIFF/EXIF fields, so check both.
        let xmp = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        func text(_ dictionary: CFString, _ key: CFString, _ value: Any?) -> String {
            if let value = value as? String, !value.isEmpty { return value }
            guard let xmp, let tag = CGImageMetadataCopyTagMatchingImageProperty(xmp, dictionary, key) else { return "" }
            return xmpString(CGImageMetadataTagCopyValue(tag)) ?? ""
        }
        m.title = text(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFImageDescription, tiff[kCGImagePropertyTIFFImageDescription])
        m.author = text(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFArtist, tiff[kCGImagePropertyTIFFArtist])
        m.copyright = text(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFCopyright, tiff[kCGImagePropertyTIFFCopyright])
        m.comment = text(kCGImagePropertyExifDictionary, kCGImagePropertyExifUserComment, exif[kCGImagePropertyExifUserComment])
        m.date = exif[kCGImagePropertyExifDateTimeOriginal] as? String ?? ""
        m.camera = [tiff[kCGImagePropertyTIFFMake] as? String, tiff[kCGImagePropertyTIFFModel] as? String, exif[kCGImagePropertyExifLensModel] as? String]
            .compactMap { $0 }.joined(separator: " · ")
        if let lat = gps[kCGImagePropertyGPSLatitude] as? Double, let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            m.latitude = String(format: "%.6f", (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat)
            m.longitude = String(format: "%.6f", (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon)
        }
        return m
    }

    /// XMP values are strings, arrays of tags (dc:creator) or language alternatives (dc:title).
    private static func xmpString(_ value: CFTypeRef?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        if CFGetTypeID(value) == CGImageMetadataTagGetTypeID() {
            return xmpString(CGImageMetadataTagCopyValue(unsafeDowncast(value, to: CGImageMetadataTag.self)))
        }
        if let array = value as? [AnyObject] { return array.lazy.compactMap { xmpString($0) }.first }
        if let dictionary = value as? [String: AnyObject] {
            return xmpString(dictionary["x-default"]) ?? dictionary.values.lazy.compactMap { xmpString($0) }.first
        }
        return nil
    }

    /// Rewrites the tags without re-encoding pixels where ImageIO allows it (JPEG, PNG, TIFF, HEIC);
    /// otherwise re-encodes at full quality (into PNG when ImageIO can't write the source format).
    static func writeMetadata(_ url: URL, _ m: Metadata, removeLocation: Bool) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw ConvertError("Can't read \(url.lastPathComponent)")
        }
        let latitude = Double(m.latitude), longitude = Double(m.longitude)

        if let type = CGImageSourceGetType(source) {
            let out = Output.file(for: url, suffix: " edited", ext: url.pathExtension.lowercased())
            // Start from the file's own metadata so nothing else is lost, then replace (not merge)
            // so stale EXIF values can't win over the edited ones.
            let tags = CGImageSourceCopyMetadataAtIndex(source, 0, nil).flatMap { CGImageMetadataCreateMutableCopy($0) }
                ?? CGImageMetadataCreateMutable()
            func set(_ dictionary: CFString, _ key: CFString, _ value: Any) {
                CGImageMetadataSetValueMatchingImageProperty(tags, dictionary, key, value as CFTypeRef)
            }
            set(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFImageDescription, m.title)
            set(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFArtist, m.author)
            set(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFCopyright, m.copyright)
            set(kCGImagePropertyExifDictionary, kCGImagePropertyExifUserComment, m.comment)
            if !m.date.isEmpty { set(kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal, m.date) }
            if !removeLocation, let latitude, let longitude {
                set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitude, abs(latitude))
                set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitudeRef, latitude < 0 ? "S" : "N")
                set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitude, abs(longitude))
                set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitudeRef, longitude < 0 ? "W" : "E")
            }
            if let destination = CGImageDestinationCreateWithURL(out as CFURL, type, CGImageSourceGetCount(source), nil) {
                let options: [CFString: Any] = [kCGImageDestinationMetadata: tags, kCGImageMetadataShouldExcludeGPS: removeLocation]
                // Keep the lossless copy only if every edited tag actually landed.
                if CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil),
                   matches(readMetadata(out), m, removeLocation: removeLocation) {
                    return out
                }
            }
            try? FileManager.default.removeItem(at: out)
        }

        return try reencode(url, suffix: " edited") { props in
            var merged = props
            var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            tiff[kCGImagePropertyTIFFImageDescription] = m.title
            tiff[kCGImagePropertyTIFFArtist] = m.author
            tiff[kCGImagePropertyTIFFCopyright] = m.copyright
            merged[kCGImagePropertyTIFFDictionary] = tiff
            var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            exif[kCGImagePropertyExifUserComment] = m.comment
            if !m.date.isEmpty { exif[kCGImagePropertyExifDateTimeOriginal] = m.date }
            merged[kCGImagePropertyExifDictionary] = exif
            var png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any] ?? [:]
            png[kCGImagePropertyPNGTitle] = m.title
            png[kCGImagePropertyPNGAuthor] = m.author
            png[kCGImagePropertyPNGCopyright] = m.copyright
            png[kCGImagePropertyPNGDescription] = m.comment
            merged[kCGImagePropertyPNGDictionary] = png
            if removeLocation {
                merged[kCGImagePropertyGPSDictionary] = nil
            } else if let latitude, let longitude {
                merged[kCGImagePropertyGPSDictionary] = [
                    kCGImagePropertyGPSLatitude: abs(latitude), kCGImagePropertyGPSLatitudeRef: latitude < 0 ? "S" : "N",
                    kCGImagePropertyGPSLongitude: abs(longitude), kCGImagePropertyGPSLongitudeRef: longitude < 0 ? "W" : "E",
                ]
            }
            return merged
        }
    }

    private static func matches(_ written: Metadata, _ wanted: Metadata, removeLocation: Bool) -> Bool {
        guard written.title == wanted.title, written.author == wanted.author, written.copyright == wanted.copyright,
              written.comment == wanted.comment, wanted.date.isEmpty || written.date == wanted.date
        else { return false }
        if removeLocation { return written.latitude.isEmpty }
        guard let lat = Double(wanted.latitude), let lon = Double(wanted.longitude) else { return true }
        return abs((Double(written.latitude) ?? .nan) - lat) < 1e-4 && abs((Double(written.longitude) ?? .nan) - lon) < 1e-4
    }

    /// A copy without metadata. JPEG, HEIC, PNG and TIFF keep their compressed data untouched (no
    /// quality loss or growth); anything else, or a copy that still carries tags, is re-encoded.
    static func stripMetadata(_ url: URL) throws -> URL {
        if let out = losslessStrip(url) { return out }
        return try reencode(url, suffix: " clean") { _ in nil }
    }

    private static func losslessStrip(_ url: URL) -> URL? {
        let ext = Catalog.normalize(url)
        guard ["jpg", "heic", "png", "tiff"].contains(ext),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source)
        else { return nil }
        let out = Output.file(for: url, suffix: " clean", ext: ext)
        guard let destination = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) else { return nil }

        // Keep only the orientation: the pixels aren't rotated, so the picture still shows upright.
        let metadata = CGImageMetadataCreateMutable()
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        if let orientation = props?[kCGImagePropertyOrientation] as? Int, orientation != 1 {
            CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary,
                                                         kCGImagePropertyTIFFOrientation, orientation as CFNumber)
        }
        let options: [CFString: Any] = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: false,
                                        kCGImageMetadataShouldExcludeGPS: true, kCGImageMetadataShouldExcludeXMP: true]
        let copied = CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil)
        let written = copied ? CGImageSourceCreateWithURL(out as CFURL, nil) : nil
        let back = written.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        let clean = back.map { $0[kCGImagePropertyGPSDictionary] == nil && readMetadata(out) == Metadata() } ?? false
        guard clean else {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        return out
    }

    /// Writes a fresh copy whose metadata comes from `metadata(originalProperties)`.
    /// Animated GIFs keep every frame and their timing.
    private static func reencode(_ url: URL, suffix: String, metadata: ([CFString: Any]) -> [CFString: Any]?) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ConvertError("Can't read \(url.lastPathComponent)") }
        let ext = ImageEngine.writableExtension(for: url)
        let count = CGImageSourceGetCount(source)

        if count > 1, ext == "gif" {
            let out = Output.file(for: url, suffix: suffix, ext: "gif")
            guard let destination = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil) else {
                throw ConvertError("Can't write GIF files")
            }
            let fileProps = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
            if let gif = fileProps[kCGImagePropertyGIFDictionary] {
                CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: gif] as CFDictionary)
            }
            for index in 0..<count {
                // Only the frame timing travels along; everything else is dropped.
                let frame = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
                let timing = frame[kCGImagePropertyGIFDictionary].map { [kCGImagePropertyGIFDictionary: $0] } ?? [:]
                CGImageDestinationAddImageFromSource(destination, source, index, timing as CFDictionary)
            }
            guard CGImageDestinationFinalize(destination) else { throw ConvertError("Couldn't write the GIF") }
            return out
        }

        let (image, props) = try ImageEngine.load(url)
        let out = Output.file(for: url, suffix: suffix, ext: ext)
        try ImageEngine.write(image, to: out, ext: ext, quality: 1, metadata: metadata(props))
        return out
    }
}

extension CGRect {
    /// The rectangle spanned by two corner points, in any order.
    init(from a: CGPoint, to b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
