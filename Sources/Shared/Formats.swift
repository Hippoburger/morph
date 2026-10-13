import Foundation

// The format table both the app and the Finder extension read: which formats exist, what each one
// can become, and whether that needs a tool macOS doesn't ship.

enum Tool: String, CaseIterable {
    case ffmpeg, libreoffice

    var displayName: String { self == .ffmpeg ? "ffmpeg" : "LibreOffice" }
    var installCommand: String { self == .ffmpeg ? "brew install ffmpeg" : "brew install --cask libreoffice" }

    var path: String? {
        let candidates: [String]
        switch self {
        case .ffmpeg: candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        case .libreoffice: candidates = ["/Applications/LibreOffice.app/Contents/MacOS/soffice"]
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

enum Need: Equatable {
    case native
    case tool(Tool)
}

enum Category: String, CaseIterable {
    case images = "Images", video = "Video", audio = "Audio", documents = "Documents"
}

enum Kind {
    case image, video, audio, text, pdf, csv, slides, sheet
}

struct Target: Equatable {
    let ext: String
    let need: Need
}

enum Formats {
    static let byCategory: [(Category, [String])] = [
        (.images, ["jpg", "png", "webp", "heic", "avif", "gif", "tiff", "bmp", "ico", "tga", "ppm", "qoi", "exr", "svg"]),
        (.video, ["mp4", "mov", "webm", "mkv", "avi"]),
        (.audio, ["mp3", "wav", "flac", "aac", "m4a", "ogg", "opus"]),
        (.documents, ["pdf", "docx", "doc", "odt", "rtf", "txt", "html", "pptx", "ppt", "odp", "xlsx", "xls", "ods", "csv"]),
    ]

    private static let aliases = ["jpeg": "jpg", "jpe": "jpg", "tif": "tiff", "htm": "html", "m4v": "mp4", "oga": "ogg", "markdown": "txt", "md": "txt", "text": "txt"]

    static let nativeVideo: Set = ["mp4", "mov"]
    static let nativeAudioOut: Set = ["wav", "flac", "aac", "m4a"]

    static func normalize(_ ext: String) -> String {
        let e = ext.lowercased()
        return aliases[e] ?? e
    }

    static func category(of ext: String) -> Category? {
        byCategory.first { $0.1.contains(ext) }?.0
    }

    static func kind(of ext: String) -> Kind? {
        switch ext {
        case "pdf": return .pdf
        case "csv": return .csv
        case "docx", "doc", "odt", "rtf", "txt", "html": return .text
        case "pptx", "ppt", "odp": return .slides
        case "xlsx", "xls", "ods": return .sheet
        default:
            switch category(of: ext) {
            case .images: return .image
            case .video: return .video
            case .audio: return .audio
            default: return nil
            }
        }
    }

    /// What it takes to turn `s` into `d`, or nil when Morph can't.
    static func need(from s: String, to d: String) -> Need? {
        guard s != d, let sk = kind(of: s), let dk = kind(of: d) else { return nil }
        let videoNative = nativeVideo.contains(s)
        switch (sk, dk) {
        case (.image, .image): return d == "webp" ? .tool(.ffmpeg) : .native
        case (.image, .pdf): return .native
        case (.pdf, .image): return ["png", "jpg", "heic", "tiff"].contains(d) ? .native : nil
        case (.video, .video):
            return videoNative && nativeVideo.contains(d) ? .native : .tool(.ffmpeg)
        case (.video, .audio):
            return videoNative && nativeAudioOut.contains(d) ? .native : .tool(.ffmpeg)
        case (.video, .image):
            guard d == "gif" else { return nil }
            return videoNative ? .native : .tool(.ffmpeg)
        case (.audio, .audio): return nativeAudioOut.contains(d) ? .native : .tool(.ffmpeg)
        case (.text, .text), (.text, .pdf), (.pdf, .text): return .native
        case (.csv, .text): return d == "html" ? .native : nil
        case (.csv, .pdf): return .native
        case (.csv, .sheet): return .tool(.libreoffice)
        case (.sheet, .sheet), (.sheet, .csv), (.sheet, .pdf): return .tool(.libreoffice)
        case (.sheet, .text): return d == "html" ? .tool(.libreoffice) : nil
        case (.slides, .slides), (.slides, .pdf): return .tool(.libreoffice)
        default: return nil
        }
    }

    /// Formats a conversion may pass through when there's no direct route, e.g. PDF → PNG → WEBP or
    /// DOCX → PDF → PNG. Kept to lossless or layout-preserving ones.
    static let intermediates = ["png", "pdf", "wav", "html"]

    /// The cheapest way from `s` to `d` in at most three steps, as the formats it passes through
    /// (ending with `d`) and the first tool it needs. Each step that needs a tool costs as much as ten
    /// native ones, so a longer native route wins over a shorter one that needs an install.
    static func plan(from s: String, to d: String) -> (steps: [String], need: Need)? {
        guard s != d else { return nil }
        // A page of a document is worth having as a picture, not as an icon or a texture.
        if kind(of: s) != .image, kind(of: s) != .video, kind(of: d) == .image, !["png", "jpg", "webp", "heic", "tiff"].contains(d) { return nil }
        var best: (steps: [String], need: Need, cost: Int)?
        func consider(_ steps: [String]) {
            var prev = s, total: Need = .native, cost = 0
            for (i, step) in steps.enumerated() {
                guard let n = need(from: prev, to: step) else { return }
                // A PDF that was made along the way has no text worth pulling back out.
                if i > 0, prev == "pdf", kind(of: step) == .text { return }
                if total == .native { total = n }
                cost += n == .native ? 1 : 10
                prev = step
            }
            if best == nil || cost < best!.cost { best = (steps, total, cost) }
        }
        consider([d])
        let via = intermediates.filter { $0 != s && $0 != d }
        for a in via { consider([a, d]) }
        for a in via { for b in via where b != a { consider([a, b, d]) } }
        return best.map { ($0.steps, $0.need) }
    }

    /// Targets every source in `sources` can become, in display order. A target that needs a tool
    /// for any of the sources is marked as needing it.
    static func commonTargets(for sources: Set<String>) -> [Target] {
        guard !sources.isEmpty else { return [] }
        var result: [Target] = []
        for (_, exts) in byCategory {
            for d in exts {
                var combined: Need? = .native
                for s in sources {
                    guard let n = plan(from: s, to: d)?.need else { combined = nil; break }
                    if case .tool = n { combined = n }
                }
                if let combined { result.append(Target(ext: d, need: combined)) }
            }
        }
        return result
    }
}
