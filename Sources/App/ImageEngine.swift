import AppKit
import ImageIO
import UniformTypeIdentifiers

// Images through ImageIO, which reads all of them but QOI and SVG and writes all of them but WEBP,
// QOI, PPM and SVG. QOI and PPM are written here, SVG wraps a PNG, and WEBP goes
// through cwebp, or ffmpeg when it was built with libwebp (Homebrew's isn't).

enum ImageEngine {
    /// `maxPixels` shrinks the image to fit that many pixels on its longest side; smaller ones stay as they are.
    static func convert(_ input: URL, from src: String, to dst: String, out: URL, maxPixels: Int? = nil, quality: Double = 0.9) throws {
        var (image, props) = try load(input, ext: src)
        if let maxPixels, max(image.width, image.height) > maxPixels { image = try scaled(image, toFit: maxPixels) }
        try write(image, to: out, ext: dst, properties: metadata(props), quality: quality)
    }

    // MARK: Reading

    /// The upright image and the file's metadata.
    static func load(_ url: URL, ext: String) throws -> (CGImage, [CFString: Any]) {
        switch ext {
        case "qoi":
            let q = try QOI.decode(Data(contentsOf: url))
            return (try makeImage(width: q.width, height: q.height, straightRGBA: q.rgba), [:])
        case "svg":
            guard let svg = NSImage(contentsOf: url), svg.size.width > 0, svg.size.height > 0 else {
                throw ConversionError("Couldn't read the SVG.")
            }
            // SVGs are drawn at their own size, but a small icon is scaled up so it stays sharp.
            let scale = max(1, 1024 / max(svg.size.width, svg.size.height))
            return (try render(width: Int(svg.size.width * scale), height: Int(svg.size.height * scale), opaque: false) { ctx, rect in
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                svg.draw(in: rect)
                NSGraphicsContext.restoreGraphicsState()
            }, [:])
        default:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ConversionError("Couldn't open the image.") }
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            // A full-size thumbnail is the one ImageIO call that applies the EXIF orientation.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) ?? CGImageSourceCreateImageAtIndex(source, 0, nil) {
                return (image, props)
            }
            throw ConversionError("Couldn't decode the image.")
        }
    }

    /// What of the source's metadata goes into the copy: date taken, camera, location (unless Remove
    /// Location is on) and keywords. The orientation is reset because `load` already turned the
    /// pixels upright, and the pixel sizes are left for ImageIO to fill in for the new image.
    private static func metadata(_ props: [CFString: Any]) -> [CFString: Any] {
        var out: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary, kCGImagePropertyTIFFDictionary,
                    kCGImagePropertyIPTCDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            out[key] = props[key]
        }
        if UserDefaults.standard.bool(forKey: "stripLocation") { out[kCGImagePropertyGPSDictionary] = nil }
        out[kCGImagePropertyOrientation] = 1
        if var tiff = out[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            out[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = out[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = nil
            exif[kCGImagePropertyExifPixelYDimension] = nil
            out[kCGImagePropertyExifDictionary] = exif
        }
        return out
    }

    // MARK: Writing

    static func write(_ image: CGImage, to url: URL, ext: String, properties: [CFString: Any] = [:], quality: Double = 0.9) throws {
        switch ext {
        case "qoi":
            try QOI.encode(width: image.width, height: image.height, rgba: straightRGBA(image)).write(to: url)
        case "ppm":
            try writePPM(image, to: url)
        case "svg":
            try writeSVG(image, to: url)
        case "webp":
            let png = OutputPath.temporary(ext: "png")
            defer { try? FileManager.default.removeItem(at: png) }
            if let cwebp = Tool.webp.path {
                try write(image, to: png, ext: "png")
                try Shell.run(cwebp, ["-quiet", "-q", "90", "-alpha_q", "100", "-metadata", "icc", png.path, "-o", url.path])
            } else if let ffmpeg = Tool.ffmpeg.path, FFmpeg.has("libwebp") {
                try write(image, to: png, ext: "png")
                try Shell.run(ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", png.path,
                                       "-frames:v", "1", "-c:v", "libwebp", "-quality", "90", url.path])
            } else {
                throw MissingToolError(tool: .webp)
            }
        case "pdf":
            var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw ConversionError("Couldn't create the PDF.") }
            ctx.beginPDFPage(nil)
            ctx.draw(image, in: box)
            ctx.endPDFPage()
            ctx.closePDF()
        default:
            guard let type = UTType(filenameExtension: ext),
                  let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
                throw ConversionError("macOS can't write \(ext.uppercased()) images.")
            }
            var image = image
            // These have no alpha; transparent pixels would come out black.
            if ["jpg", "bmp"].contains(ext) { image = try flattened(image) }
            // ICO tops out at 256 pixels a side.
            if ext == "ico", max(image.width, image.height) > 256 { image = try scaled(image, toFit: 256) }
            var props = properties
            props[kCGImageDestinationLossyCompressionQuality] = quality
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw ConversionError("Couldn't write the \(ext.uppercased()) file.") }
        }
    }

    private static func writePPM(_ image: CGImage, to url: URL) throws {
        let rgba = try straightRGBA(flattened(image))
        var data = Data("P6\n\(image.width) \(image.height)\n255\n".utf8)
        data.reserveCapacity(data.count + image.width * image.height * 3)
        for o in stride(from: 0, to: rgba.count, by: 4) { data.append(contentsOf: rgba[o..<o + 3]) }
        try data.write(to: url)
    }

    private static func writeSVG(_ image: CGImage, to url: URL) throws {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw ConversionError("Couldn't encode the image.") }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        let w = image.width, h = image.height
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(w)" height="\(h)" viewBox="0 0 \(w) \(h)">
          <image width="\(w)" height="\(h)" href="data:image/png;base64,\((data as Data).base64EncodedString())"/>
        </svg>

        """
        try svg.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Pixels

    static func render(width: Int, height: Int, opaque: Bool, draw: (CGContext, CGRect) -> Void) throws -> CGImage {
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ConversionError("Couldn't allocate a \(width)×\(height) image.") }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if opaque {
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(rect)
        }
        draw(ctx, rect)
        guard let image = ctx.makeImage() else { throw ConversionError("Couldn't render the image.") }
        return image
    }

    private static func flattened(_ image: CGImage) throws -> CGImage {
        try render(width: image.width, height: image.height, opaque: true) { ctx, rect in ctx.draw(image, in: rect) }
    }

    private static func scaled(_ image: CGImage, toFit side: Int) throws -> CGImage {
        let s = Double(side) / Double(max(image.width, image.height))
        return try render(width: max(1, Int(Double(image.width) * s)), height: max(1, Int(Double(image.height) * s)), opaque: false) { ctx, rect in
            ctx.interpolationQuality = .high
            ctx.draw(image, in: rect)
        }
    }

    /// Straight-alpha RGBA8 bytes, top row first.
    private static func straightRGBA(_ image: CGImage) throws -> [UInt8] {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw ConversionError("Couldn't read the image's pixels.") }
        for o in stride(from: 0, to: bytes.count, by: 4) {
            let a = Int(bytes[o + 3])
            guard a != 0, a != 255 else { continue }
            for c in 0..<3 { bytes[o + c] = UInt8(min(255, (Int(bytes[o + c]) * 255 + a / 2) / a)) }
        }
        return bytes
    }

    private static func makeImage(width: Int, height: Int, straightRGBA: [UInt8]) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(straightRGBA) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw ConversionError("Couldn't build the image.") }
        return image
    }
}
