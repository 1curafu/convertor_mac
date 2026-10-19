import AppKit
import CoreImage
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum ImageEngine {
    /// Formats ImageIO can write; everything else goes through ffmpeg.
    static let nativeOutputs: Set<String> = ["jpg", "png", "heic", "tiff", "bmp", "gif"]

    static var quality: Double { Prefs.defaults.double(forKey: Prefs.imageQuality) }
    static var compressQuality: Double { Prefs.defaults.double(forKey: Prefs.compressQuality) }

    // MARK: Convert

    static func convert(_ url: URL, to ext: String) async throws -> URL {
        let out = Output.file(for: url, ext: ext)
        switch ext {
        case "pdf":
            try imagesToPDF([url], output: out)
        case _ where nativeOutputs.contains(ext):
            let (image, props) = try load(url)
            try write(image, to: out, ext: ext, quality: quality, metadata: props)
        default:
            try await FFmpeg.run(input: url, output: out, args: FFmpeg.arguments(for: ext))
        }
        return out
    }

    // MARK: Tools

    static func apply(_ tool: Tool, to url: URL) throws -> URL {
        let (image, props) = try load(url)
        let ext = writableExtension(for: url)

        switch tool {
        case .compressImage:
            let target = hasAlpha(image) ? "heic" : "jpg"
            let out = Output.file(for: url, suffix: " compressed", ext: target)
            try write(image, to: out, ext: target, quality: compressQuality, metadata: props)
            return out
        case .resizeHalf:
            let out = Output.file(for: url, suffix: " 50%", ext: ext)
            try write(try resized(image, scale: 0.5), to: out, ext: ext, quality: quality, metadata: props)
            return out
        case .rotateImage:
            let out = Output.file(for: url, suffix: " rotated", ext: ext)
            try write(try filtered(image) { $0.oriented(.right) }, to: out, ext: ext, quality: quality, metadata: props)
            return out
        case .flipImage:
            let out = Output.file(for: url, suffix: " flipped", ext: ext)
            try write(try filtered(image) { $0.oriented(.upMirrored) }, to: out, ext: ext, quality: quality, metadata: props)
            return out
        case .monoImage:
            let out = Output.file(for: url, suffix: " mono", ext: ext)
            try write(try filtered(image) { $0.applyingFilter("CIPhotoEffectMono") }, to: out, ext: ext, quality: quality, metadata: props)
            return out
        case .stripMetadata:
            let out = Output.file(for: url, suffix: " clean", ext: ext)
            try write(image, to: out, ext: ext, quality: quality, metadata: nil)
            return out
        default:
            throw ConvertError("Not an image tool")
        }
    }

    static func imagesToPDF(_ urls: [URL], output: URL) throws {
        let document = PDFDocument()
        for url in urls {
            let (image, _) = try load(url)
            let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            guard let page = PDFPage(image: nsImage) else { throw ConvertError("Couldn't add \(url.lastPathComponent) to the PDF") }
            document.insert(page, at: document.pageCount)
        }
        guard document.write(to: output) else { throw ConvertError("Couldn't write the PDF") }
    }

    // MARK: Helpers

    /// Loads the first frame upright (EXIF orientation applied) plus its metadata.
    static func load(_ url: URL) throws -> (CGImage, [CFString: Any]) {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 {
            var props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
            var options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            if max(width, height) > 0 { options[kCGImageSourceThumbnailMaxPixelSize] = max(width, height) }
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                // Pixels are already rotated, so the copied metadata must say "upright".
                props[kCGImagePropertyOrientation] = 1
                if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                    tiff[kCGImagePropertyTIFFOrientation] = 1
                    props[kCGImagePropertyTIFFDictionary] = tiff
                }
                return (image, props)
            }
        }
        // SVG and other formats only NSImage understands.
        if let nsImage = NSImage(contentsOf: url), let image = rasterize(nsImage, scale: 2) {
            return (image, [:])
        }
        throw ConvertError("Can't read \(url.lastPathComponent) as an image")
    }

    static func write(_ image: CGImage, to url: URL, ext: String, quality: Double, metadata: [CFString: Any]?) throws {
        guard let type = UTType(filenameExtension: ext),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { throw ConvertError("Can't write \(ext.uppercased()) files") }

        var options = metadata ?? [:]
        options[kCGImageDestinationLossyCompressionQuality] = quality
        let output = (ext == "jpg" || ext == "bmp") && hasAlpha(image) ? flattened(image) : image
        CGImageDestinationAddImage(destination, output, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            throw ConvertError("Couldn't encode \(ext.uppercased())")
        }
    }

    /// Keeps the source format for tools, unless ImageIO can't write it.
    private static func writableExtension(for url: URL) -> String {
        let ext = Catalog.normalize(url)
        return nativeOutputs.contains(ext) ? ext : "png"
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private static func flattened(_ image: CGImage) -> CGImage {
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    private static func resized(_ image: CGImage, scale: CGFloat) throws -> CGImage {
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ConvertError("Couldn't resize the image") }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = ctx.makeImage() else { throw ConvertError("Couldn't resize the image") }
        return result
    }

    private static func filtered(_ image: CGImage, _ transform: (CIImage) -> CIImage) throws -> CGImage {
        let output = transform(CIImage(cgImage: image))
        guard let result = CIContext().createCGImage(output, from: output.extent) else {
            throw ConvertError("Couldn't process the image")
        }
        return result
    }

    private static func rasterize(_ image: NSImage, scale: CGFloat) -> CGImage? {
        let width = Int(image.size.width * scale), height = Int(image.size.height * scale)
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}
