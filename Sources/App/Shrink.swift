import AVFoundation
import PDFKit
import Quartz

// Make Smaller: the same format, smaller file, next to the original as "name (smaller).ext". Photos
// are re-encoded at quality 0.7 and capped at 2560 pixels, videos become HEVC at up to 1080p, and PDFs
// go through ColorSync's Reduce File Size filter. A result that isn't at least 5% smaller is thrown away.

@MainActor
enum Shrink {
    static func run(_ input: URL) async throws -> URL {
        let ext = Formats.normalize(input.pathExtension)
        guard Formats.shrinkable.contains(ext) else { throw ConversionError("Morph can't make \(ext.uppercased()) files smaller.") }
        let out = OutputPath.unique(in: input.deletingLastPathComponent(),
                                    base: input.deletingPathExtension().lastPathComponent + " (smaller)", ext: input.pathExtension)
        do {
            switch ext {
            case "pdf":
                guard let doc = PDFDocument(url: input) else { throw ConversionError("Couldn't open the PDF.") }
                let filter = QuartzFilter(url: URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter"))
                guard doc.write(to: out, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter as Any]) else {
                    throw ConversionError("Couldn't write the smaller PDF.")
                }
            case "mp4", "mov":
                try await MediaEngine.export(AVURLAsset(url: input), to: out, type: ext == "mov" ? .mov : .mp4,
                                             presets: [AVAssetExportPresetHEVC1920x1080])
            default:
                try await Task.detached { try ImageEngine.convert(input, from: ext, to: ext, out: out, maxPixels: 2560, quality: 0.7) }.value
            }
            let before = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let after = try out.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max
            guard after <= before * 95 / 100 else { throw ConversionError("\(input.lastPathComponent) is already as small as Morph can make it.") }
            return out
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
    }
}
